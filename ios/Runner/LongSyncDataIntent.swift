#if compiler(>=6.4)
import AppIntents
import Foundation

@available(iOS 27.0, *)
struct LongSyncDataIntent: LongRunningIntent, CancellableIntent {
  static var title: LocalizedStringResource = "Sync Data (Long Running)"
  static var description = IntentDescription(
    "Sync a larger band backlog with system-managed progress and cancellation. iOS may interrupt the task; saved data is retained.")
  static var supportedModes: IntentModes = .background
  static var allowedExecutionTargets: IntentExecutionTargets = .main
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Parameter(title: "Ignore Connectivity Errors", description:
    "Skip when Bluetooth is unavailable or the band cannot be reached. Other errors and system progress UI are not suppressed.", default: false)
  var ignoreConnectivityErrors: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Sync a larger band backlog") { \.$ignoreConnectivityErrors }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let id = UUID().uuidString
    let bridge = ShortcutSyncBridge.shared
    let taskProgress = progress
    LongSyncProgress.start(taskProgress)
    let message = try await performBackgroundTask {
      try await syncMessage(using: bridge, id: id, progress: taskProgress)
    } onCancel: { reason in
      if !taskProgress.isCancelled { taskProgress.cancel() }
      Task { @MainActor in
        bridge.cancel(id: id, code: reason == .timeout ? "timedOut" : "cancelled")
      }
    }
    return .result(value: message)
  }

  @MainActor
  func syncMessage(using bridge: ShortcutSyncBridge, id: String,
                   progress: Progress) async throws -> String {
    guard !progress.isCancelled else { throw ShortcutSyncFailure(code: "cancelled") }
    do {
      let reply = try await bridge.sync(id: id, timeout: 600, progress: { update in
        LongSyncProgress.update(progress, with: update)
      })
      if reply.status == "complete" {
        LongSyncProgress.finish(progress)
      }
      progress.localizedAdditionalDescription = reply.message
      return reply.message
    } catch let error as ShortcutSyncFailure where ignoreConnectivityErrors && error.canIgnore {
      let message = "Skipped: \(error.localizedDescription)"
      progress.localizedAdditionalDescription = message
      return message
    }
  }
}

@available(iOS 27.0, *)
@MainActor
enum LongSyncProgress {
  static func start(_ progress: Progress) {
    // The band does not provide a reliable total batch count in advance.
    progress.totalUnitCount = -1
    progress.completedUnitCount = 0
    progress.localizedDescription = "Syncing band data"
    progress.localizedAdditionalDescription = "Starting Edge"
  }

  static func update(_ progress: Progress, with update: [String: Any]) {
    guard !progress.isCancelled, let phase = update["phase"] as? String else { return }
    let batches = max(0, update["batches"] as? Int ?? 0)
    progress.completedUnitCount = max(progress.completedUnitCount, Int64(batches))
    switch phase {
    case "starting": progress.localizedAdditionalDescription = "Starting Edge"
    case "waiting": progress.localizedAdditionalDescription = "Waiting for Edge"
    case "connecting": progress.localizedAdditionalDescription = "Connecting to band"
    case "initializing": progress.localizedAdditionalDescription = "Preparing band connection"
    case "syncing": progress.localizedAdditionalDescription = "Saving band data (\(batches) batches)"
    case "processing": progress.localizedAdditionalDescription = "Refreshing recent metrics"
    default: break
    }
  }

  static func finish(_ progress: Progress) {
    guard !progress.isCancelled else { return }
    progress.totalUnitCount = max(1, progress.completedUnitCount)
    progress.completedUnitCount = progress.totalUnitCount
  }
}
#endif
