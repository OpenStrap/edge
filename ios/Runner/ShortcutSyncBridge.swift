import Flutter
import Foundation

struct ShortcutSyncFailure: LocalizedError {
  let code: String

  var canIgnore: Bool { code == "bluetoothUnavailable" || code == "bandUnreachable" }

  var errorDescription: String? {
    switch code {
    case "bluetoothUnavailable": return "Bluetooth is unavailable."
    case "bandUnreachable": return "The paired band could not be reached."
    case "permissionDenied": return "Allow Edge to use Bluetooth in Settings."
    case "notPaired": return "Open Edge and pair your band first."
    case "setupRequired": return "Finish accessory setup in Edge before syncing."
    case "timedOut": return "Edge did not finish the sync before its execution deadline."
    case "cancelled": return "Sync was cancelled."
    default: return "Edge could not complete the sync. Open Edge to check the connection and storage."
    }
  }
}

struct ShortcutSyncReply {
  let status: String
  let records: Int

  init(_ value: Any?) throws {
    guard let map = value as? [String: Any],
          let status = map["status"] as? String,
          let records = map["records"] as? Int, records >= 0 else {
      throw ShortcutSyncFailure(code: "invalidResponse")
    }
    guard ["complete", "partial", "alreadyRunning"].contains(status) else {
      throw ShortcutSyncFailure(code: status)
    }
    self.status = status
    self.records = records
  }

  var message: String {
    switch status {
    case "complete": return "Band data synchronized."
    case "partial": return "Sync is incomplete. Saved data is retained; run Sync Data again or open Edge to catch up."
    default: return "A sync request is already active; no second sync was started."
    }
  }
}

@MainActor
final class ShortcutSyncBridge {
  static let shared = ShortcutSyncBridge()
  typealias Sender = (String, Any?, @escaping FlutterResult) -> Void

  private var channel: FlutterMethodChannel?
  private var send: Sender?
  private var ready = false
  private var pending: Pending?

  private final class Pending {
    let id: String
    let deadline: TimeInterval
    let continuation: CheckedContinuation<ShortcutSyncReply, Error>
    let progress: (([String: Any]) -> Void)?
    var watchdog: Task<Void, Never>?
    var sent = false

    init(id: String, timeout: TimeInterval,
         continuation: CheckedContinuation<ShortcutSyncReply, Error>,
         progress: (([String: Any]) -> Void)?) {
      self.id = id
      self.deadline = ProcessInfo.processInfo.systemUptime + timeout
      self.continuation = continuation
      self.progress = progress
    }
  }

  init(send: Sender? = nil) { self.send = send }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "openstrap/shortcut_sync", binaryMessenger: messenger)
    self.channel = channel
    send = { method, arguments, reply in
      channel.invokeMethod(method, arguments: arguments, result: reply)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      MainActor.assumeIsolated {
        self?.receive(call, result: result)
      }
    }
  }

  func receive(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "ready":
      ready = true
      result(nil)
      dispatchPending()
    case "progress":
      if let update = call.arguments as? [String: Any],
         let id = update["id"] as? String, id == pending?.id {
        pending?.progress?(update)
      }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func sync(id: String = UUID().uuidString, timeout: TimeInterval = 25,
            progress: (([String: Any]) -> Void)? = nil) async throws -> ShortcutSyncReply {
    try Task.checkCancellation()
    guard pending == nil else {
      return try ShortcutSyncReply(["status": "alreadyRunning", "records": 0])
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let request = Pending(id: id, timeout: timeout, continuation: continuation, progress: progress)
        pending = request
        request.watchdog = Task { [weak self] in
          do {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
          } catch { return }
          self?.cancel(id: id, code: "timedOut")
        }
        dispatchPending()
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id: id) }
    }
  }

  func cancel(id: String, code: String = "cancelled") {
    guard let request = pending, request.id == id else { return }
    if request.sent { send?("cancel", ["id": id], { _ in }) }
    finish(id: id, result: .failure(ShortcutSyncFailure(code: code)))
  }

  private func dispatchPending() {
    guard ready, let request = pending, !request.sent, let send else { return }
    let remaining = request.deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else {
      cancel(id: request.id, code: "timedOut")
      return
    }
    request.sent = true
    // Leave time for Dart to return a partial/unreachable result before the native watchdog.
    let budget = max(1, Int((remaining - min(2, remaining / 10)) * 1000))
    send("run", ["id": request.id, "budgetMs": budget]) { [weak self] reply in
      MainActor.assumeIsolated {
        self?.finish(id: request.id, result: Result { try ShortcutSyncReply(reply) })
      }
    }
  }

  private func finish(id: String, result: Result<ShortcutSyncReply, Error>) {
    guard let request = pending, request.id == id else { return }
    pending = nil
    request.watchdog?.cancel()
    request.continuation.resume(with: result)
  }
}
