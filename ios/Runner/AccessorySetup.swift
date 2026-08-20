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
  // WHOOP GATT service UUIDs (match GattProfile / kWhoopMemberUuid16 in Dart).
  // `fileprivate` so the iOS-18 Impl below can read them. Every criterion used
  // in an ASDiscoveryDescriptor must also be listed in Info.plist or iOS
  // silently ignores it.
  //   • gen4 ("Harvard", WHOOP 4)           — 6108… 128-bit vendor service
  //   • gen5 ("fd4b", WHOOP 5.0 / MG)       — fd4b0001-cce1-… 128-bit vendor
  //   • 16-bit SIG member UUID 0xFD4B       — what still fits a 31-byte AD
  // The 16-bit form is NOT 0000FD4B-0000-1000-8000-00805F9B34FB; no band
  // advertises that Bluetooth-base expansion.
  fileprivate static let whoopServiceUUIDGen4 = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
  fileprivate static let whoopServiceUUIDGen5 = "fd4b0001-cce1-4033-93ce-002d5875f58a"
  fileprivate static let whoopMemberUUID16 = "FD4B"
  fileprivate static let nameSubstring = "WHOOP"

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

    // ONE ITEM PER MATCH STRATEGY. A single ASDiscoveryDescriptor AND-combines
    // its criteria, so folding gen5's 128-bit UUID, 16-bit 0xFD4B, and a name
    // substring onto one descriptor would match nothing. showPicker(for:) takes
    // an array so each strategy is its own accessory; the sheet de-duplicates
    // by peripheral.
    //
    // Why three gen5-relevant items: we do not yet know (no nRF Connect capture)
    // whether fd4b0001-… is in the primary advertisement or only the scan
    // response. The 16-bit member UUID is what still fits a 31-byte AD; the
    // name (`WHOOP MGB…` / `WHOOP 5A…`) survives even if iOS hashes the 128-bit
    // UUID in the overflow area.
    let productImage = UIImage(named: "StrapProduct")
      ?? UIImage(systemName: "sensor.tag.radiowave.forward")
      ?? UIImage()
    func makeItem(_ label: String,
                  _ configure: (ASDiscoveryDescriptor) -> Void) -> ASPickerDisplayItem {
      let descriptor = ASDiscoveryDescriptor()
      configure(descriptor)
      return ASPickerDisplayItem(name: label, productImage: productImage,
                                 descriptor: descriptor)
    }
    let items: [ASPickerDisplayItem] = [
      makeItem("WHOOP band") {
        $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.whoopServiceUUIDGen4)
      },
      makeItem("WHOOP 5.0 / MG") {
        $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.whoopServiceUUIDGen5)
      },
      makeItem("WHOOP 5.0 / MG") {
        $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.whoopMemberUUID16)
      },
      makeItem("WHOOP band") {
        $0.bluetoothNameSubstring = AccessorySetup.nameSubstring
      },
    ]

    pickerResult = completion
    present(items, allowGen4Retry: true)
  }

  /// Presents the picker and resolves `pickerResult`.
  ///
  /// If iOS rejects the widened descriptor list (a name-only item is the
  /// experimental one), retry once with the WHOOP 4.0 item that already ships,
  /// so the experiment can never take down 4.0 pairing.
  private func present(_ items: [ASPickerDisplayItem], allowGen4Retry: Bool) {
    session.showPicker(for: items) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        guard let cb = self.pickerResult else { return }
        let message = error.localizedDescription
        let looksCancelled = message.lowercased().contains("cancel")
        if allowGen4Retry, !looksCancelled, items.count > 1 {
          NSLog("[ASK] picker rejected the %d-item descriptor list (%@) — "
                + "retrying with the WHOOP 4.0 item only.", items.count, message)
          self.present([items[0]], allowGen4Retry: false)
          return
        }
        self.pickerResult = nil
        cb(.failure(PickerError(message: message)))
        return
      }
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
