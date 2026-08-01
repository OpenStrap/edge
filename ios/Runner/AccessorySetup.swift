import Foundation
import Flutter
import CoreBluetooth
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

/// AccessorySetupKit (ASK) bridge — iOS 18+ only.
///
/// WHY: per Apple TN3115, starting in iOS 26 the OS only relaunches a *terminated* app
/// into the background for a Bluetooth accessory that was provisioned via ASK. Our
/// CoreBluetooth state-restoration central (BleRestoreManager) still does the actual
/// relaunch/pending-connect work, but iOS 26 will only honour it if the peripheral was
/// set up through the ASK picker. So pairing on iOS 18+ goes through this picker.
///
/// COEXISTENCE: ASK is a provisioning/authorization gate, NOT a connection owner. It hands
/// back `ASAccessory.bluetoothIdentifier` — the CoreBluetooth peripheral UUID, which is the
/// exact value flutter_blue_plus uses as `BluetoothDevice.remoteId` on iOS. So after the
/// user picks the band we just return that UUID to Dart; flutter_blue_plus connects to it
/// exactly as before. No second GATT owner, no conflict.
///
/// Dart MethodChannel `openstrap/accessory_setup`:
///   - `isSupported`        -> Bool   (true only on iOS 18+)
///   - `provisionedId`      -> String?(uppercased UUID of an already-provisioned WHOOP, or nil)
///   - `showPicker`         -> String (the provisioned band's UUID; throws on cancel/error)
///   - `removeAll`          -> nil    (deprovision all — used on unpair)
enum AccessorySetup {
  private static let channelName = "openstrap/accessory_setup"
  // WHOOP GATT service UUIDs, one per generation (match GattProfile in Dart).
  // `fileprivate` so the iOS-18 Impl below can read them. BOTH must also be
  // listed in Info.plist under NSAccessorySetupBluetoothServices.
  //   • gen4 ("Harvard", WHOOP 4)  — 6108…
  //   • gen5 ("fd4b", WHOOP 5)     — fd4b…  (EXPERIMENTAL)
  fileprivate static let whoopServiceUUIDGen4 = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
  fileprivate static let whoopServiceUUIDGen5 = "fd4b0001-cce1-4033-93ce-002d5875f58a"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        if #available(iOS 18.0, *) { result(true) } else { result(false) }

      case "provisionedId":
        if #available(iOS 18.0, *) {
          Impl.shared.provisionedId { result($0) }
        } else {
          result(nil)
        }

      case "showPicker":
        if #available(iOS 18.0, *) {
          Impl.shared.showPicker { res in
            switch res {
            case .success(let id): result(id)
            case .failure(let err):
              result(FlutterError(code: "ask_picker", message: err.message, details: nil))
            }
          }
        } else {
          result(FlutterError(code: "unavailable",
                              message: "AccessorySetupKit requires iOS 18", details: nil))
        }

      case "removeAll":
        if #available(iOS 18.0, *) {
          Impl.shared.removeAll { result(nil) }
        } else {
          result(nil)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

#if canImport(AccessorySetupKit)
@available(iOS 18.0, *)
private final class Impl {
  static let shared = Impl()

  private let session = ASAccessorySession()
  private var activated = false
  private let queue = DispatchQueue.main
  // Set while a showPicker is in flight; resolved by the completion handler.
  private var pickerResult: ((Result<String, PickerError>) -> Void)?

  struct PickerError: Error { let message: String }

  private func ensureActivated() {
    guard !activated else { return }
    activated = true
    session.activate(on: queue) { [weak self] event in
      self?.onEvent(event)
    }
  }

  private func onEvent(_ event: ASAccessoryEvent) {
    // We mostly drive ASK request/response style; the event stream is here so the
    // session stays live and so a picker-dismiss without a selection can resolve a
    // pending showPicker as "cancelled".
    switch event.eventType {
    case .pickerDidDismiss:
      // If a picker was in flight and nothing got added, treat as cancelled. (If an
      // accessory WAS added, showPicker's completion handler already resolved it.)
      if let cb = pickerResult {
        pickerResult = nil
        cb(.failure(PickerError(message: "Pairing cancelled.")))
      }
    default:
      break
    }
  }

  /// Returns the uppercased UUID of an already-provisioned WHOOP, or nil.
  func provisionedId(_ completion: @escaping (String?) -> Void) {
    ensureActivated()
    // `accessories` is reliable only after activation has reported .activated; give the
    // session a brief beat to populate on a cold start, then read it.
    queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self = self else { completion(nil); return }
      let id = self.session.accessories
        .compactMap { $0.bluetoothIdentifier }
        .first?
        .uuidString
        .uppercased()
      completion(id)
    }
  }

  func showPicker(_ completion: @escaping (Result<String, PickerError>) -> Void) {
    ensureActivated()
    // Already provisioned? Don't re-show the picker — just return the known id.
    if let existing = session.accessories
      .compactMap({ $0.bluetoothIdentifier })
      .first?.uuidString.uppercased() {
      completion(.success(existing))
      return
    }

    // Match on the WHOOP custom service UUID alone. The foreground scan finds the
    // band via startScan(withServices:[…]) and succeeds, which proves the band
    // advertises this service — so it's a reliable, sufficient filter. Every
    // descriptor criterion must be declared in Info.plist; the UUIDs are listed
    // under NSAccessorySetupBluetoothServices. (No bluetoothNameSubstring: a
    // single descriptor AND-combines its criteria, and a name filter would also
    // require an NSAccessorySetupBluetoothNames entry and risk excluding the band
    // on a name mismatch.)
    //
    // ASK matches ANY item in the picker list, so we offer one item per WHOOP
    // generation: gen4 (WHOOP 4) and gen5 (WHOOP 5, experimental). A band that
    // advertises either service can be provisioned; the provisioned identifier is
    // the same CoreBluetooth UUID regardless of generation.
    let productImage = UIImage(named: "StrapProduct")
      ?? UIImage(systemName: "sensor.tag.radiowave.forward")
      ?? UIImage()
    func item(_ serviceUUID: String, _ name: String) -> ASPickerDisplayItem {
      let descriptor = ASDiscoveryDescriptor()
      descriptor.bluetoothServiceUUID = CBUUID(string: serviceUUID)
      return ASPickerDisplayItem(
        name: name, productImage: productImage, descriptor: descriptor)
    }
    let items = [
      item(AccessorySetup.whoopServiceUUIDGen4, "WHOOP band"),
      item(AccessorySetup.whoopServiceUUIDGen5, "WHOOP 5 band"),
    ]

    pickerResult = completion
    session.showPicker(for: items) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        if let cb = self.pickerResult {
          self.pickerResult = nil
          cb(.failure(PickerError(message: error.localizedDescription)))
        }
        return
      }
      // Picker succeeded — read the newly provisioned accessory's identifier.
      let id = self.session.accessories
        .compactMap { $0.bluetoothIdentifier }
        .first?.uuidString.uppercased()
      if let cb = self.pickerResult {
        self.pickerResult = nil
        if let id = id {
          cb(.success(id))
        } else {
          cb(.failure(PickerError(message: "No accessory was provisioned.")))
        }
      }
    }
  }

  func removeAll(_ completion: @escaping () -> Void) {
    ensureActivated()
    let accessories = session.accessories
    guard !accessories.isEmpty else { completion(); return }
    let group = DispatchGroup()
    for acc in accessories {
      group.enter()
      session.removeAccessory(acc) { _ in group.leave() }
    }
    group.notify(queue: queue) { completion() }
  }
}
#endif
