import Foundation
import CoreBluetooth
import UIKit
import Flutter

/// Keeps the app eligible for background relaunch when the paired WHOOP band becomes
/// reachable — the mechanism WHOOP/Garmin use on iOS (CoreBluetooth State Preservation
/// & Restoration). No persistent notification, no foreground service.
///
/// Running this as a SEPARATE CBCentralManager (distinct restoration identifier) from
/// the "live" central flutter_blue_plus drives is an Apple-documented, supported pattern,
/// not an inferred workaround: "Because apps can have multiple instances of
/// CBCentralManager... be sure each restoration identifier is unique, so that the system
/// can properly distinguish one central... from another" (Core Bluetooth Background
/// Processing for iOS Apps). Confirmed directly against that doc — this is not a deviation
/// from a single-manager model Apple only describes for the simple case.
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
///
/// Verified against Apple's official docs ("Core Bluetooth Background Processing for iOS
/// Apps"): a state-restoration relaunch is a BOUNDED wake, not indefinite runtime — "an app
/// has around 10 seconds to complete a task... apps that spend too much time executing in
/// the background can be throttled back by the system or killed," and even a fully
/// backgrounded app "can't run forever... the system may need to terminate your app to free
/// up memory." This is exactly why the headless sync this triggers (background_sync.dart's
/// runHeadlessSync) is designed to make partial progress safely on every wake — commit
/// whatever it drained before the window closes, resume from the durable cursor next time —
/// rather than assuming it gets to run to completion in one continuous background session.

/// Per-peripheral restore state. Replaces the three process-wide flags
/// (`handedOff` / `idleAfterSync` / `appOwnsBand`), which were only ever correct
/// while exactly one band could be provisioned: with two, band A's foreground
/// connect set `appOwnsBand = true` and suppressed band B's background re-arm,
/// presenting days later as "the app stopped syncing overnight" with no error.
private struct ArmState {
  /// The peripheral we hold a pending connect for. Retained here so ARC cannot
  /// drop it mid-connect — a peripheral we no longer hold is one `cancelPending`
  /// can no longer cancel, and the two centrals then fight over the band.
  var peripheral: CBPeripheral?
  /// True between a wake's `didConnect` and Dart's `syncDone` for THIS band.
  var handedOff = false
  /// Set after this band's wake-sync completes; suppresses re-arming until Dart
  /// explicitly re-arms it on the next disconnect. Not a timer, not a cooldown.
  var idleAfterSync = false
  /// True while the app holds the live flutter_blue_plus connection to THIS band.
  var appOwnsBand = false
}

class BleRestoreManager: NSObject {
  static let shared = BleRestoreManager()

  private static let restoreId = "openstrap.ble.restore"
  private static let bandUUIDKey = "openstrap.ble.band_uuid"

  private var central: CBCentralManager?
  private var bandUUID: UUID?
  /// Provisioned bands and their arm state, keyed by CoreBluetooth peripheral UUID.
  /// With one provisioned band there is exactly one entry and every loop below runs
  /// once — byte-identical behaviour to the scalar version it replaces.
  private var arms: [UUID: ArmState] = [:]
  private var channel: FlutterMethodChannel?
  private var flutterReady = false
  private var wakeQueuedBeforeReady = false
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

  /// Insert-or-get, so a caller never has to branch on "first time for this UUID".
  private func state(_ uuid: UUID) -> ArmState {
    arms[uuid] ?? ArmState()
  }

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
    if arms[uuid] == nil { arms[uuid] = ArmState() }
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
        // Scalar String (today's shape) or a List<String> — either way, arm each uuid.
        var uuids: [UUID] = []
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          uuids = [uuid]
        } else if let list = call.arguments as? [String] {
          uuids = list.compactMap(UUID.init(uuidString:))
        }
        for uuid in uuids {
          self.saveBandUUID(uuid)
          self.bandUUID = uuid
          var s = self.state(uuid)
          s.handedOff = false
          s.idleAfterSync = false   // explicit (re-)arm request from Dart
          self.arms[uuid] = s
        }
        if !uuids.isEmpty {
          // The band is provisioned by the time Dart arms; ensure the restore central
          // exists (it may have been deferred at launch on a fresh install).
          self.ensureCentral()
          self.armIfAppropriate()
        }
        result(nil)
      case "setOwnsBand":
        if let dict = call.arguments as? [String: Any],
           let s = dict["uuid"] as? String, let uuid = UUID(uuidString: s) {
          let owns = (dict["owns"] as? Bool) ?? false
          var st = self.state(uuid)
          st.appOwnsBand = owns
          self.arms[uuid] = st
          if owns {
            self.cancelPending(uuid)
            NSLog("[ble-restore] app owns band \(uuid.uuidString) — pending connect cancelled")
          } else {
            st.idleAfterSync = false
            self.arms[uuid] = st
            NSLog("[ble-restore] app released band \(uuid.uuidString) — arming recovery")
            self.armIfAppropriate()
          }
        } else {
          let owns = (call.arguments as? Bool) ?? false
          for uuid in Array(self.arms.keys) {
            var st = self.state(uuid)
            st.appOwnsBand = owns
            if owns {
              self.arms[uuid] = st
              self.cancelPending(uuid)
            } else {
              st.idleAfterSync = false
              self.arms[uuid] = st
            }
          }
          if owns {
            NSLog("[ble-restore] app owns band — pending connect cancelled")
          } else {
            NSLog("[ble-restore] app released band — arming recovery")
            self.armIfAppropriate()
          }
        }
        result(nil)
      case "armRecoveryNow":
        // Atomic combination of setOwnsBand(false) + arm(uuid) in ONE round trip —
        // used on the hot disconnect-recovery path (AppState._armRecovery). Two
        // separate awaited channel calls left a window where a process suspension
        // between them could drop appOwnsBand to false with nothing armed to
        // replace it (worst of both: app no longer owns the band, AND no pending
        // connect is watching for it). Doing both under one delegate callback,
        // wrapped in a short background-task extension, removes that window.
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          self.beginBackground()
          self.saveBandUUID(uuid)
          self.bandUUID = uuid
          var st = self.state(uuid)
          st.appOwnsBand = false
          st.handedOff = false
          st.idleAfterSync = false
          self.arms[uuid] = st
          self.ensureCentral()
          self.armIfAppropriate()
          NSLog("[ble-restore] armRecoveryNow — recovery armed atomically")
          // The actual recovery (the no-timeout pending connect) is now held by
          // bluetoothd itself and survives full app suspension; the background-task
          // extension only needed to cover this method's own synchronous work, so
          // release it shortly rather than holding it for the full ~30s budget.
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.endBackground()
          }
        }
        result(nil)
      case "disarm":
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          self.disarm(uuid)
        } else {
          self.disarm()
        }
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
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          var st = self.state(uuid)
          st.handedOff = false
          st.idleAfterSync = true
          self.arms[uuid] = st
          self.cancelPending(uuid)
        } else {
          for uuid in Array(self.arms.keys) where self.arms[uuid]?.handedOff == true {
            var st = self.state(uuid)
            st.handedOff = false
            st.idleAfterSync = true
            self.arms[uuid] = st
            self.cancelPending(uuid)
          }
        }
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
    // Process-level guards, evaluated once (unchanged from today, same log text).
    guard let central = central else { NSLog("[ble-restore] skip arm — no central"); return }
    guard central.state == .poweredOn else {
      NSLog("[ble-restore] skip arm — central not poweredOn (state=\(central.state.rawValue))"); return
    }
    if UIApplication.shared.applicationState == .active {
      NSLog("[ble-restore] skip arm — app active"); return
    }
    guard !arms.isEmpty else { NSLog("[ble-restore] skip arm — no bandUUID"); return }

    // Write `Array(arms.keys)`, not `arms.keys` directly — the loop body mutates `arms`,
    // and iterating the live Keys view while doing so is a mutation-during-iteration hazard.
    for uuid in Array(arms.keys) {
      var s = state(uuid)
      let tag = uuid.uuidString
      if s.appOwnsBand { NSLog("[ble-restore] skip arm \(tag) — app owns band"); continue }
      if s.handedOff { NSLog("[ble-restore] skip arm \(tag) — handedOff"); continue }
      if s.idleAfterSync {
        NSLog("[ble-restore] skip arm \(tag) — idle after sync (awaiting re-arm)"); continue
      }
      // Already holding a pending connect for this one — arming again is a no-op that
      // would drop and re-take the retain.
      if s.peripheral != nil { continue }
      guard let p = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
        NSLog("[ble-restore] band \(tag) not retrievable yet"); continue
      }
      s.peripheral = p
      arms[uuid] = s
      central.connect(p, options: nil)  // no timeout → persists, relaunches us when reachable
      NSLog("[ble-restore] armed pending connect \(tag)")
    }
  }

  private func cancelPending(_ uuid: UUID? = nil) {
    guard let uuid = uuid else {
      for (_, s) in arms {
        if let p = s.peripheral { central?.cancelPeripheralConnection(p) }
      }
      for key in arms.keys { arms[key]?.peripheral = nil }
      return
    }
    if let p = arms[uuid]?.peripheral { central?.cancelPeripheralConnection(p) }
    arms[uuid]?.peripheral = nil
  }

  private func disarm(_ uuid: UUID? = nil) {
    guard let uuid = uuid else {
      cancelPending()
      arms = [:]
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
      return
    }
    cancelPending(uuid)
    arms.removeValue(forKey: uuid)
    if bandUUID == uuid { bandUUID = nil }
    if arms.isEmpty, central != nil {
      central?.delegate = nil
      central = nil
      NSLog("[ble-restore] disarmed \(uuid.uuidString) — restore central released (no bands left)")
    } else {
      NSLog("[ble-restore] disarmed \(uuid.uuidString)")
    }
  }

  // MARK: - Wake → Flutter

  private func signalWake(_ uuid: UUID) {
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
      guard let self = self, self.state(uuid).handedOff else { return }
      NSLog("[ble-restore] syncDone watchdog fired — releasing handoff, going idle")
      var s = self.state(uuid)
      s.handedOff = false
      s.idleAfterSync = true
      self.arms[uuid] = s
      self.cancelPending(uuid)
      // endBackground() only when no entry is still handedOff.
      if !self.arms.values.contains(where: { $0.handedOff }) {
        self.endBackground()
      }
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
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    guard !restored.isEmpty else { return }
    // Take ALL of them, not just the first — the count was already being logged, so the
    // code always knew there could be more. Each carries a pending/active connect
    // bluetoothd preserved for us; didConnect fires per peripheral if one lands.
    // Keep retaining a restored peripheral whose UUID is not in `arms` (band we have
    // since forgotten): bluetoothd preserved a connect for it and dropping the retain
    // loses the ability to cancel it. Insert a default entry so the retain has a home;
    // didConnect below still refuses to wake Dart for it.
    for p in restored {
      arms[p.identifier, default: ArmState()].peripheral = p
    }
    NSLog("[ble-restore] willRestoreState restored \(restored.count) peripheral(s)")
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    let uuid = peripheral.identifier
    guard arms[uuid] != nil else {
      NSLog("[ble-restore] didConnect for unknown band \(uuid.uuidString) — cancelling")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    NSLog("[ble-restore] didConnect \(uuid.uuidString) — handing off to flutter_blue_plus")
    arms[uuid]?.handedOff = true
    signalWake(uuid)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    let uuid = peripheral.identifier
    arms[uuid]?.peripheral = nil
    let handedOff = state(uuid).handedOff
    NSLog("[ble-restore] didDisconnect \(uuid.uuidString) (handedOff=\(handedOff))")
    // Re-arm only if our own pending connect dropped while still in recovery mode (band
    // went away again). armIfAppropriate's idleAfterSync/appOwnsBand guards prevent loops.
    if !handedOff { armIfAppropriate() }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    let uuid = peripheral.identifier
    arms[uuid]?.peripheral = nil
    NSLog("[ble-restore] didFailToConnect \(uuid.uuidString): \(error?.localizedDescription ?? "—")")
    if !state(uuid).handedOff { armIfAppropriate() }
  }
}
