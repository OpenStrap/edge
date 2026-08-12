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
  // The WHOOP "Harvard" Gen4 GATT service (matches GattUuids.service in Dart).
  // `fileprivate` so the iOS-18 Impl below can read it.
  fileprivate static let gen4ServiceUUID = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"

  // EXPERIMENTAL — WHOOP 5.0 / MG. The 16-bit member service 0xFD4B expanded against
  // the Bluetooth Base UUID. NOT validated against hardware: no maintainer owns a gen5
  // strap, so this is a community-reported candidate. If a capture proves it wrong,
  // this is the one line to change (plus its twin in Info.plist and ble_engine.dart).
  fileprivate static let gen5ServiceUUID = "0000FD4B-0000-1000-8000-00805F9B34FB"

  // EXPERIMENTAL — the net that catches a gen5 band whose service UUID we have wrong.
  // Matches the advertised local name: "WHOOP MGB…", "WHOOP 5…", "WHOOP 4…".
  // Must stay in sync with NSAccessorySetupBluetoothNames in Info.plist.
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

    // Show the actual strap render in the ASK pairing sheet (asset catalog →
    // StrapProduct.imageset). Fall back to an SF Symbol if the asset is missing.
    let productImage = UIImage(named: "StrapProduct")
      ?? UIImage(systemName: "sensor.tag.radiowave.forward")
      ?? UIImage()

    // ONE ITEM PER MATCH STRATEGY. A single ASDiscoveryDescriptor AND-combines its
    // criteria, so a descriptor carrying the 4.0 service AND the gen5 service AND a
    // name substring would match nothing at all. showPicker(for:) takes an array
    // precisely so alternative accessories can each bring their own descriptor; the
    // sheet de-duplicates by peripheral, so a 4.0 band matching two items shows once.
    //
    // Every criterion used below is declared in Info.plist (NSAccessorySetupBluetooth-
    // Services / …Names) — an undeclared criterion is silently ignored by the system,
    // which is exactly how gen5 bands ended up invisible here (no gen5 UUID declared,
    // no name fallback ⇒ "No Accessory Found" no matter what the band was doing).
    func makeItem(_ label: String,
                  _ configure: (ASDiscoveryDescriptor) -> Void) -> ASPickerDisplayItem {
      let descriptor = ASDiscoveryDescriptor()
      configure(descriptor)
      return ASPickerDisplayItem(name: label, productImage: productImage,
                                 descriptor: descriptor)
    }

    let items: [ASPickerDisplayItem] = [
      // WHOOP 4.0 — the proven path, byte-identical to what shipped before.
      makeItem("WHOOP band") {
        $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.gen4ServiceUUID)
      },
      // EXPERIMENTAL — WHOOP 5.0 / MG by its (community-reported) service UUID.
      makeItem("WHOOP 5.0 / MG") {
        $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.gen5ServiceUUID)
      },
      // EXPERIMENTAL — WHOOP 5.0 / MG by advertised name, for when the UUID above is
      // wrong or iOS won't surface it. Drop this item once a real capture confirms
      // the gen5 service UUID.
      makeItem("WHOOP band") {
        $0.bluetoothNameSubstring = AccessorySetup.nameSubstring
      },
    ]

    pickerResult = completion
    present(items, allowGen4Retry: true)
  }

  /// Presents the picker and resolves `pickerResult`.
  ///
  /// SAFETY NET for the experimental gen5 items: if the system rejects the descriptor
  /// list outright (e.g. it won't accept a name-only descriptor), we must not take
  /// WHOOP 4.0 pairing down with it — so one retry falls back to the 4.0-only item
  /// that shipped before gen5 support existed. Fail closed on the experiment, never
  /// on the path that works.
  private func present(_ items: [ASPickerDisplayItem], allowGen4Retry: Bool) {
    session.showPicker(for: items) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        // `pickerResult == nil` means .pickerDidDismiss already resolved this as a
        // user cancel, so there is nothing to retry or report.
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
      // Picker succeeded — read the newly provisioned accessory's identifier.
      // Log every provisioned accessory first: gen5 triage happens entirely from
      // user-submitted logs, and "what name did the sheet actually show?" is the
      // question that keeps coming back.
      for acc in self.session.accessories {
        NSLog("[ASK] provisioned name=%@ id=%@", acc.displayName,
              acc.bluetoothIdentifier?.uuidString ?? "nil")
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
