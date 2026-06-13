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
/// Pacing: a no-timeout pending connect to an in-range band fires immediately, so left
/// alone it would reconnect-drain in a loop. After each sync we enter a cooldown
/// (~50 min) before re-arming, which lands the cadence near "once an hour" while the
/// band is around, and still syncs promptly when the band returns after being away.
/// Arming only happens while backgrounded; in the foreground flutter_blue_plus owns the
/// band.
class BleRestoreManager: NSObject {
  static let shared = BleRestoreManager()

  private static let restoreId = "openstrap.ble.restore"
  private static let bandUUIDKey = "openstrap.ble.band_uuid"
  private let cooldownSeconds: TimeInterval = 50 * 60

  private var central: CBCentralManager?
  private var bandUUID: UUID?
  private var pending: CBPeripheral?        // retained so ARC doesn't drop it mid-connect
  private var channel: FlutterMethodChannel?
  private var flutterReady = false
  private var wakeQueuedBeforeReady = false
  private var handedOff = false             // true between wake → Dart's syncDone
  private var coolingDown = false
  private var cooldownWork: DispatchWorkItem?
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

  // MARK: - Lifecycle

  /// Instantiate the restoring central early in didFinishLaunching so iOS can call
  /// willRestoreState when relaunching us for a Bluetooth event.
  func start(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    bandUUID = loadBandUUID()
    if central == nil {
      central = CBCentralManager(
        delegate: self,
        queue: nil,
        options: [CBCentralManagerOptionRestoreIdentifierKey: BleRestoreManager.restoreId]
      )
    }
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(appDidEnterBackground),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(appWillEnterForeground),
                   name: UIApplication.willEnterForegroundNotification, object: nil)
    NSLog("[ble-restore] started, band=\(bandUUID?.uuidString ?? "none")")
  }

  /// Wire the Dart channel. Safe on the implicit engine too (background launch).
  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "openstrap/ble_restore", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "arm":
        if let s = call.arguments as? String, let uuid = UUID(uuidString: s) {
          self.saveBandUUID(uuid)
          self.bandUUID = uuid
          self.handedOff = false
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
        // Dart finished the headless drain — pace the next one via cooldown.
        self.handedOff = false
        self.endBackground()
        self.beginCooldown()
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
    guard !handedOff, !coolingDown,
          let central = central, central.state == .poweredOn,
          let uuid = bandUUID else { return }
    // In the foreground, flutter_blue_plus owns the band — don't compete.
    if UIApplication.shared.applicationState == .active { return }
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

  private func beginCooldown() {
    coolingDown = true
    cancelPending()
    cooldownWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.coolingDown = false
      self.armIfAppropriate()
    }
    cooldownWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + cooldownSeconds, execute: work)
    NSLog("[ble-restore] cooldown \(Int(cooldownSeconds))s before next arm")
  }

  private func disarm() {
    cooldownWork?.cancel()
    coolingDown = false
    handedOff = false
    cancelPending()
    clearBandUUID()
    bandUUID = nil
    NSLog("[ble-restore] disarmed")
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
    // Safety net: if Dart never calls syncDone (crash/timeout), cooldown anyway so we
    // neither loop nor get stuck.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self = self, self.handedOff else { return }
      NSLog("[ble-restore] syncDone timeout — cooling down")
      self.handedOff = false
      self.endBackground()
      self.beginCooldown()
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
    if !handedOff && !coolingDown { armIfAppropriate() }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    NSLog("[ble-restore] didFailToConnect: \(error?.localizedDescription ?? "—")")
    if !handedOff && !coolingDown { armIfAppropriate() }
  }
}
