import Foundation
import CoreBluetooth
import UIKit
import Flutter

/// Keeps the app eligible for background relaunch when the paired WHOOP band becomes
/// reachable — the mechanism WHOOP/Garmin use on iOS (CoreBluetooth State Preservation
/// & Restoration). No persistent notification, no foreground service.
///
/// It does NOT drain data. flutter_blue_plus owns the real GATT session, and two
/// CBCentralManagers can't share a peripheral connection. This is a trigger only: it
/// holds a no-timeout pending connect to the band (under a restore identifier) so iOS
/// relaunches us when the band shows up, then it cancels its own connection and tells
/// Flutter to run the normal headless sync.
///
/// This is RECOVERY-ONLY: normal sync is the kept-alive live connection + the AppState
/// flusher. The restore central arms a no-timeout pending connect ONLY when Dart tells
/// it the connection dropped (`setOwnsBand(false)` / `arm`). No timers, no cooldown.
///
/// Loop prevention is event-driven, not time-based: after a wake hands off to Dart and
/// Dart reports the drain done (`syncDone`), we go IDLE and do NOT re-arm. We re-arm only
/// on the next explicit request from Dart (a fresh disconnect). Arming only happens while
/// backgrounded; in the foreground flutter_blue_plus owns the band.
class BleRestoreManager: NSObject {
  static let shared = BleRestoreManager()

  private static let restoreId = "openstrap.ble.restore"
  private static let bandUUIDKey = "openstrap.ble.band_uuid"

  private var central: CBCentralManager?
  private var bandUUID: UUID?
  private var pending: CBPeripheral?        // retained so ARC doesn't drop it mid-connect
  private var channel: FlutterMethodChannel?
  private var flutterReady = false
  private var wakeQueuedBeforeReady = false
  private var handedOff = false             // true between wake → Dart's syncDone
  /// Set after a wake's sync completes; suppresses re-arming until Dart explicitly
  /// re-arms on the next disconnect. Replaces the old time-based cooldown — no loop,
  /// no timer.
  private var idleAfterSync = false
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  /// True while the app holds the live flutter_blue_plus connection (foreground OR
  /// backgrounded-but-connected). The restore central must not arm a competing connect
  /// to the same peripheral while this is true.
  private var appOwnsBand = false

  // MARK: - Lifecycle

  /// Wire lifecycle observers, but DO NOT create the CBCentralManager yet unless a band
  /// is already saved (i.e. an accessory was provisioned on a prior launch).
  ///
  /// CRITICAL ORDERING (AccessorySetupKit): `ASAccessorySession.showPicker` fails with
  /// "CBManager is active with global permissions" if ANY CBCentralManager already exists
  /// in the process when the picker is shown. On a FIRST-time pairing there is no
  /// provisioned accessory yet, so creating the restore central here at launch is exactly
  /// what blocked the picker. The fix: only instantiate the restore central when we
  /// already have a provisioned band (saved bandUUID). On a fresh install the central is
  /// created LATER — see `bandProvisioned(_:)`, called right after the ASK picker succeeds.
  ///
  /// On launches where the band is already provisioned, creating the central here is fine
  /// (scoped Bluetooth authorization is already granted, and we never show the picker), so
  /// iOS can still call willRestoreState to relaunch us for a Bluetooth event.
  func start(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    bandUUID = loadBandUUID()
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(appDidEnterBackground),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(appWillEnterForeground),
                   name: UIApplication.willEnterForegroundNotification, object: nil)
    if bandUUID != nil {
      // Already provisioned on a prior launch → safe to create the restore central now so
      // iOS can relaunch us via willRestoreState. (No picker is ever shown in this case.)
      ensureCentral()
      NSLog("[ble-restore] started (band=\(bandUUID!.uuidString)) — restore central up")
    } else {
      // Fresh install / no provisioned accessory → DEFER central creation so the ASK
      // picker can be shown with no CBCentralManager alive.
      NSLog("[ble-restore] started (no band) — restore central deferred until provisioned")
    }
  }

  /// Lazily create the restoring CBCentralManager (idempotent). Must only be called once a
  /// band has been provisioned via ASK — never before the first ASK picker, or it
  /// re-introduces the "CBManager is active with global permissions" failure.
  private func ensureCentral() {
    guard central == nil else { return }
    central = CBCentralManager(
      delegate: self,
      queue: nil,
      options: [CBCentralManagerOptionRestoreIdentifierKey: BleRestoreManager.restoreId]
    )
  }

  /// Called from Dart immediately AFTER the ASK picker provisions an accessory (first-time
  /// pairing). Now that an accessory exists, it is safe to create the restore central; from
  /// here on the app behaves exactly as a normal already-provisioned launch.
  func bandProvisioned(_ uuid: UUID) {
    saveBandUUID(uuid)
    bandUUID = uuid
    ensureCentral()
    NSLog("[ble-restore] band provisioned — restore central created")
  }

  /// Wire the Dart channel. Safe on the implicit engine too (background launch).
  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "openstrap/ble_restore", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "provisioned":
        // First-time ASK pairing just succeeded — NOW it's safe to create the restore
        // central (an accessory exists, so showPicker is no longer pending and the
        // "CBManager is active with global permissions" constraint no longer applies).
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          self.bandProvisioned(uuid)
        }
        result(nil)
      case "arm":
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          self.saveBandUUID(uuid)
          self.bandUUID = uuid
          // The band is provisioned by the time Dart arms; ensure the restore central
          // exists (it may have been deferred at launch on a fresh install).
          self.ensureCentral()
          self.handedOff = false
          self.idleAfterSync = false   // explicit (re-)arm request from Dart
          self.armIfAppropriate()
        }
        result(nil)
      case "setOwnsBand":
        let owns = (call.arguments as? Bool) ?? false
        self.appOwnsBand = owns
        if owns {
          // App reclaimed the band — drop our pending connect so the two centrals don't fight.
          self.cancelPending()
          NSLog("[ble-restore] app owns band — pending connect cancelled")
        } else {
          // App released the band (connection dropped in background) — arm recovery.
          self.idleAfterSync = false   // explicit re-arm request from Dart
          NSLog("[ble-restore] app released band — arming recovery")
          self.armIfAppropriate()
        }
        result(nil)
      case "disarm":
        self.disarm()
        result(nil)
      case "ready":
        self.flutterReady = true
        if self.wakeQueuedBeforeReady {
          self.wakeQueuedBeforeReady = false
          self.channel?.invokeMethod("wake", arguments: nil)
        }
        result(nil)
      case "syncDone":
        // Dart finished the headless drain. Go idle (no re-arm) until the next explicit
        // arm from Dart — prevents a reconnect-drain loop with no timer/cooldown.
        self.handedOff = false
        self.idleAfterSync = true
        self.cancelPending()
        self.endBackground()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  @objc private func appDidEnterBackground() { armIfAppropriate() }
  @objc private func appWillEnterForeground() {
    // Foreground: let flutter_blue_plus own the band; drop our pending connect.
    cancelPending()
  }

  // MARK: - Pending connect

  private func armIfAppropriate() {
    // The app holds the live connection — don't arm a competing connect.
    if appOwnsBand { NSLog("[ble-restore] skip arm — app owns band"); return }
    // Log every guard-fail reason: an unexplained no-arm is why background relaunch
    // silently never happened (the band reappeared but nothing was pending to wake us).
    guard !handedOff else { NSLog("[ble-restore] skip arm — handedOff"); return }
    guard !idleAfterSync else { NSLog("[ble-restore] skip arm — idle after sync (awaiting re-arm)"); return }
    guard let central = central else { NSLog("[ble-restore] skip arm — no central"); return }
    guard central.state == .poweredOn else {
      NSLog("[ble-restore] skip arm — central not poweredOn (state=\(central.state.rawValue))"); return
    }
    guard let uuid = bandUUID else { NSLog("[ble-restore] skip arm — no bandUUID"); return }
    // In the foreground, flutter_blue_plus owns the band — don't compete.
    if UIApplication.shared.applicationState == .active {
      NSLog("[ble-restore] skip arm — app active"); return
    }
    guard let p = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
      NSLog("[ble-restore] band not retrievable yet")
      return
    }
    pending = p
    central.connect(p, options: nil)  // no timeout → persists, relaunches us when reachable
    NSLog("[ble-restore] armed pending connect")
  }

  private func cancelPending() {
    if let p = pending { central?.cancelPeripheralConnection(p) }
    pending = nil
  }

  private func disarm() {
    idleAfterSync = false
    handedOff = false
    cancelPending()
    clearBandUUID()
    bandUUID = nil
    // Release the restore central so the process has NO CBCentralManager again. This
    // matters when the user unpairs and then re-pairs in the same app session: ASK's
    // showPicker fails with "CBManager is active with global permissions" if a central is
    // still alive. Dropping our strong reference lets CoreBluetooth tear it down; a fresh
    // one is re-created on the next provision/arm. (flutter_blue_plus's central is also
    // disconnected by AppState.unpair → engine.disconnect before re-pairing.)
    if central != nil {
      central?.delegate = nil
      central = nil
      NSLog("[ble-restore] disarmed — restore central released")
    } else {
      NSLog("[ble-restore] disarmed")
    }
  }

  // MARK: - Wake → Flutter

  private func signalWake() {
    beginBackground()
    if flutterReady {
      channel?.invokeMethod("wake", arguments: nil)
      NSLog("[ble-restore] wake → Flutter")
    } else {
      wakeQueuedBeforeReady = true
      NSLog("[ble-restore] wake queued (Flutter not ready)")
    }
    // Watchdog: if Dart never calls syncDone (crash), clear the handoff so we don't get
    // stuck, and go idle (await an explicit re-arm) so we don't loop. Not a sync cadence —
    // just a failsafe to release the in-flight state.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self = self, self.handedOff else { return }
      NSLog("[ble-restore] syncDone watchdog fired — releasing handoff, going idle")
      self.handedOff = false
      self.idleAfterSync = true
      self.cancelPending()
      self.endBackground()
    }
  }

  private func beginBackground() {
    endBackground()
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "openstrap.bleSync") { [weak self] in
      self?.endBackground()
    }
  }
  private func endBackground() {
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }

  // MARK: - Persistence

  private func saveBandUUID(_ u: UUID) {
    UserDefaults.standard.set(u.uuidString, forKey: BleRestoreManager.bandUUIDKey)
  }
  private func loadBandUUID() -> UUID? {
    UserDefaults.standard.string(forKey: BleRestoreManager.bandUUIDKey).flatMap(UUID.init(uuidString:))
  }
  private func clearBandUUID() {
    UserDefaults.standard.removeObject(forKey: BleRestoreManager.bandUUIDKey)
  }
}

extension BleRestoreManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    NSLog("[ble-restore] central state=\(central.state.rawValue)")
    if central.state == .poweredOn { armIfAppropriate() }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
       let p = restored.first {
      pending = p
      NSLog("[ble-restore] willRestoreState restored \(restored.count) peripheral(s)")
      // The pending/active connect was preserved; didConnect fires if it lands.
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    NSLog("[ble-restore] didConnect — handing off to flutter_blue_plus")
    handedOff = true
    cancelPending()      // free the band so flutter_blue_plus can own a fresh connection
    signalWake()
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    NSLog("[ble-restore] didDisconnect (handedOff=\(handedOff))")
    // Re-arm only if our own pending connect dropped while still in recovery mode (band
    // went away again). armIfAppropriate's idleAfterSync/appOwnsBand guards prevent loops.
    if !handedOff { armIfAppropriate() }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    NSLog("[ble-restore] didFailToConnect: \(error?.localizedDescription ?? "—")")
    if !handedOff { armIfAppropriate() }
  }
}
