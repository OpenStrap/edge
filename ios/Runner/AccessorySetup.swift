import Foundation
import Flutter
import CoreBluetooth
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

/// AccessorySetupKit (ASK) bridge — iOS 18+ only.
///
/// WHY: TN3115's relaunch table has two rows that are "No" without ASK and "Yes" with it —
/// "App Force Quit by the user" and "Control Center Bluetooth button toggled". Note 5:
/// "Starting in iOS 26 and iPadOS 26, only apps that use AccessorySetupKit to setup
/// Bluetooth accessories will be relaunched." Apple DTS has since clarified on the forums
/// that note 5 scopes to *those two rows only* — it is a capability apps GAIN, not one they
/// lose, and the ordinary relaunch cases (app removed from memory, crashed, device
/// restarted) never depended on ASK. The condition is also stated per-APP, not
/// per-accessory; the relaunch itself still fires "if and only if" a pending Core Bluetooth
/// request completes, which is what BleRestoreManager holds.
///
/// So the load-bearing reason to route pairing through the picker is simpler than
/// "otherwise no background sync": on iOS 18+ this picker IS how a user grants us the
/// accessory, plus those two extra relaunch cases.
///
/// COEXISTENCE: ASK is a provisioning/authorization gate, NOT a connection owner. It hands
/// back `ASAccessory.bluetoothIdentifier` — the CoreBluetooth peripheral UUID, which is the
/// exact value flutter_blue_plus uses as `BluetoothDevice.remoteId` on iOS. So after the
/// user picks the band we just return that UUID to Dart; flutter_blue_plus connects to it
/// exactly as before. No second GATT owner, no conflict.
///
/// Dart MethodChannel `openstrap/accessory_setup`:
///   - `isSupported`        -> Bool   (true only on iOS 18+)
///   - `provisionedId`      -> String?(uppercased UUID of an already-provisioned band, or nil)
///   - `showPicker`         -> String (the band provisioned by THIS call; throws on cancel/error)
///                             optional Bool argument: true = add another accessory
///   - `removeAll`          -> nil    (deprovision all — used on unpair)
///
/// The service UUIDs the picker matches on are NOT duplicated here: they come from
/// Info.plist's NSAccessorySetupBluetoothServices, which Apple requires to list every
/// descriptor criterion anyway, and which is generated from `kBandRegistry` by
/// `tool/gen_ios_ask_plist.dart`.
enum AccessorySetup {
  private static let channelName = "openstrap/accessory_setup"

  // Extra gen5-only fallback match criterion, layered on top of the
  // registry-driven items below. We do not yet know (no nRF Connect capture)
  // whether fd4b0001-… is in the primary advertisement or only the scan
  // response, so this gives gen5 a second chance to match: the 16-bit SIG
  // member UUID 0xFD4B (what still fits a 31-byte AD). `fileprivate` so Impl
  // can read it. Every criterion used in an ASDiscoveryDescriptor must also
  // be listed in Info.plist or iOS silently ignores it — this is NOT a
  // service, so it deliberately does not go through the
  // kBandRegistry-generated list.
  //
  // A name-substring-only fallback (no service UUID) used to sit alongside
  // this one but was REMOVED: ASDiscoveryDescriptor requires
  // bluetoothServiceUUID whenever bluetoothNameSubstring is set, and a
  // name-only descriptor fails ASK validation with a FATAL trap in
  // -[ASAccessorySession _validateDiscoveryDescriptor:] — not a catchable
  // completion-handler error — which crashed every picker invocation.
  fileprivate static let whoopMemberUUID16 = "FD4B"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        if #available(iOS 18.0, *) { result(true) } else { result(false) }

      case "provisionedId":
        if #available(iOS 18.0, *) {
          // ponytail: the channel still hands Dart ONE id because the Dart side is
          // still two SharedPreferences scalars (change-list E3). Swift holds the
          // whole array; widen this to a list when the device table lands.
          Impl.shared.provisionedIds { result($0.first) }
        } else {
          result(nil)
        }

      case "showPicker":
        if #available(iOS 18.0, *) {
          // No argument (today's only caller) = today's behaviour exactly.
          let addAnother = (call.arguments as? Bool) ?? false
          Impl.shared.showPicker(addAnother: addAnother) { res in
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
  // True from the moment the Gen 4 retry's showPicker is issued until its
  // completion handler runs. `.pickerDidDismiss` fires for the FIRST (rejected)
  // sheet during this window — without this guard it resolves `pickerResult`
  // as cancelled before the retry gets a chance to report its own outcome,
  // so a successfully provisioned accessory gets reported to Dart as cancelled.
  private var retryInFlight = false

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
      // Ignore the first sheet's dismissal while the Gen 4 retry is in flight —
      // see `retryInFlight`'s doc comment.
      guard !retryInFlight else { return }
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

  /// Every provisioned accessory's uppercased CoreBluetooth UUID, in session order.
  /// `session.accessories` is an ARRAY — one entry per accessory the user has granted.
  private var provisionedIdList: [String] {
    session.accessories.compactMap { $0.bluetoothIdentifier?.uuidString.uppercased() }
  }

  /// Returns the uppercased UUIDs of the already-provisioned accessories (possibly empty).
  func provisionedIds(_ completion: @escaping ([String]) -> Void) {
    ensureActivated()
    // `accessories` is reliable only after activation has reported .activated; give the
    // session a brief beat to populate on a cold start, then read it.
    queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self = self else { completion([]); return }
      completion(self.provisionedIdList)
    }
  }

  /// - Parameter addAnother: show the picker even though an accessory is already
  ///   provisioned, i.e. provision a SECOND band. See the ordering warning below.
  func showPicker(addAnother: Bool = false,
                  _ completion: @escaping (Result<String, PickerError>) -> Void) {
    ensureActivated()
    let known = provisionedIdList
    // Already provisioned and not explicitly adding another? Don't re-show the picker —
    // just return the known id.
    //
    // ORDERING (do not "fix" this into an unconditional showPicker): ASK's picker fails
    // with "CBManager is active with global permissions" once ANY CBCentralManager exists
    // in the process, and BleRestoreManager creates one at launch on every already-paired
    // launch. So this early return is also what keeps a repeat "pair" tap from turning
    // into a guaranteed picker failure.
    //
    // ponytail: `addAnother` is therefore plumbing, not a working second-band flow — a
    // second accessory can only be provisioned while no central is alive (fresh install,
    // or after unpair, which releases the restore central via BleRestoreManager.disarm).
    // A real "add a band" flow has to tear both centrals down first; that belongs with
    // the device table (change-list E3/E4), not here.
    if !addAnother, let existing = known.first {
      completion(.success(existing))
      return
    }

    // ONE ITEM PER MATCH STRATEGY. A single ASDiscoveryDescriptor AND-combines
    // its criteria, so folding gen5's 128-bit UUID, 16-bit 0xFD4B, and a name
    // substring onto one descriptor would match nothing. showPicker(for:) takes
    // an array so each strategy is its own accessory; the sheet de-duplicates
    // by peripheral.
    //
    // ASK matches ANY item in the picker list, so we offer one item per band in the
    // registry. A band advertising any listed service can be provisioned; the
    // provisioned identifier is the same CoreBluetooth UUID whichever it is.
    //
    // The list comes straight from Info.plist rather than a Swift copy: Apple requires
    // every descriptor criterion to be declared there, so that array is by definition
    // the complete set — a second copy here could only ever be the stale one. It is
    // generated from kBandRegistry (tool/gen_ios_ask_plist.dart, pinned by
    // test/ios_ask_plist_test.dart), so adding a band stays a one-file edit in Dart.
    // Two extra gen5-only fallback items (16-bit member UUID, name substring) are
    // appended below — see the constants' doc comment for why.
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
    let info = Bundle.main.infoDictionary ?? [:]
    let services = info["NSAccessorySetupBluetoothServices"] as? [String] ?? []
    let labels = info["OSBandLabels"] as? [String: String] ?? [:]
    var items = services.map { svc in
      makeItem(labels[svc.uppercased()] ?? "Band") {
        $0.bluetoothServiceUUID = CBUUID(string: svc)
      }
    }
    guard !items.isEmpty else {
      completion(.failure(PickerError(
        message: "No accessory services are declared in Info.plist.")))
      return
    }
    // Extra gen5-only fallback item — see the constants' doc comment above.
    items.append(makeItem("WHOOP 5.0 / MG") {
      $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.whoopMemberUUID16)
    })
    // ponytail: dropped the name-substring-only fallback item. ASDiscoveryDescriptor
    // requires bluetoothServiceUUID whenever bluetoothNameSubstring is set — a
    // name-only descriptor fails ASK's validation with a FATAL (uncatchable) trap in
    // -[ASAccessorySession _validateDiscoveryDescriptor:], not a completion-handler
    // error, so the existing gen4-retry-on-rejection logic below never even ran.
    // This crashed every "search for devices" tap (TestFlight crashlog
    // A3457926-FD0D-48A7-9C6B-DCC6958276BF, iOS 26.6, v0.9.29). Re-add only paired
    // with a service UUID.

    pickerResult = completion
    present(items, known: known, allowGen4Retry: true)
  }

  /// Presents the picker and resolves `pickerResult`.
  ///
  /// If iOS rejects the widened descriptor list (a name-only item is the
  /// experimental one), retry once with the WHOOP 4.0 item that already ships,
  /// so the experiment can never take down 4.0 pairing.
  ///
  /// - Parameter known: accessory ids provisioned before this picker run started,
  ///   so the success handler can tell which id it just added (see below).
  private func present(_ items: [ASPickerDisplayItem], known: [String], allowGen4Retry: Bool) {
    session.showPicker(for: items) { [weak self] error in
      guard let self = self else { return }
      // The retry (if any) that led to THIS completion running is no longer
      // in flight — whatever we resolve below is the actual outcome.
      self.retryInFlight = false
      if let error = error {
        guard let cb = self.pickerResult else { return }
        let message = error.localizedDescription
        // Prefer the typed error code over sniffing the localized message —
        // a message that doesn't happen to contain "cancel" would otherwise
        // incorrectly trigger a second picker on a real user cancellation.
        let cancelled: Bool
        if let askError = error as? ASError {
          cancelled = askError.code == .userCancelled
        } else {
          cancelled = message.lowercased().contains("cancel")
        }
        if allowGen4Retry, !cancelled, items.count > 1 {
          NSLog("[ASK] picker rejected the %d-item descriptor list (%@) — "
                + "retrying with the WHOOP 4.0 item only.", items.count, message)
          self.retryInFlight = true
          self.present([items[0]], known: known, allowGen4Retry: false)
          return
        }
        self.pickerResult = nil
        cb(.failure(PickerError(message: message)))
        return
      }
      // Picker succeeded — return the accessory THIS run added, not `accessories.first`:
      // once a second band is provisioned the first entry is the OLD one, so `.first`
      // would hand Dart the wrong device to connect to. (With none previously known —
      // every pairing today — the added one IS the first, so this is unchanged.)
      let current = self.provisionedIdList
      let knownSet = Set(known)
      let id = current.first { !knownSet.contains($0) } ?? current.first
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
