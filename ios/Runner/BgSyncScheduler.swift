import Foundation
import BackgroundTasks
import Flutter

/// BGTaskScheduler bridge for OpenStrap Edge.
///
/// Registers a BGProcessingTask (identifier: "wtf.openstrap.edge.bgsync") that
/// iOS runs opportunistically when the device is idle. On task launch it calls
/// the Dart `openstrap/bg_task` channel → `run`, which runs runHeadlessSync() +
/// a heavy DerivationEngine pass, then signals completion.
///
/// Task identifier scoped to wtf.openstrap.edge.
///
/// Design notes:
///   - "location" is NOT added to UIBackgroundModes: OpenStrap has no GPS /
///     workout-route feature; adding it without purpose risks App Store review
///     rejection. We use "processing" + "fetch" only.
///   - Uses BGProcessingTaskRequest (not BGAppRefreshTaskRequest): allows a
///     longer wall-clock budget and does not require user-granted Background App
///     Refresh — more reliable for compute-heavy sync+derive.
///
/// Call order from AppDelegate:
///   1. BGTaskScheduler.shared.register(forTaskIdentifier:...) in didFinishLaunching
///      (BEFORE super returns) — the OS needs this call before launch completes.
///   2. handleTask(_:) wired as the task handler in that same register block.
///   3. wireChannel(messenger:) called from didInitializeImplicitFlutterEngine so
///      the Flutter binary messenger is available for Dart callout.
///   4. schedule() called after wireChannel so the first request is queued once
///      Dart is ready, and again on every applicationDidEnterBackground.
enum BackgroundTaskManager {
    static let taskIdentifier = "wtf.openstrap.edge.bgsync"
    private static let channelName = "openstrap/bg_task"
    private static let retryInterval: TimeInterval = 15 * 60   // 15-min earliest

    // Retained so the channel survives between task invocations.
    private static var channel: FlutterMethodChannel?

    // MARK: - AppDelegate hooks

    /// Wire the Dart method channel. Called from didInitializeImplicitFlutterEngine
    /// once the binary messenger is live. Also called from schedule() guard so we
    /// never schedule without a channel.
    static func wireChannel(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        NSLog("[bg-task] channel wired")
    }

    /// Handle an OS-delivered BGProcessingTask. Pass this as the handler block in
    /// BGTaskScheduler.shared.register(...) inside AppDelegate.didFinishLaunching.
    static func handleTask(_ task: BGProcessingTask) {
        NSLog("[bg-task] task launched")

        // Re-schedule immediately so there is always a next request queued.
        schedule()

        // Expiration handler: partial run is fine — the non-destructive cursor
        // means the next wake catches up from where this one left off.
        task.expirationHandler = {
            NSLog("[bg-task] expiration handler fired")
            task.setTaskCompleted(success: false)
        }

        guard let ch = channel else {
            NSLog("[bg-task] channel not yet wired — marking complete")
            task.setTaskCompleted(success: true)
            return
        }

        // Invoke Dart. ios_bg_task.dart runs runHeadlessSync() + heavy
        // DerivationEngine.run and returns true/false.
        ch.invokeMethod("run", arguments: nil) { reply in
            let success = (reply as? Bool) ?? true
            NSLog("[bg-task] Dart returned success=\(success)")
            task.setTaskCompleted(success: success)
        }
    }

    /// Submit (or renew) the next BGProcessingTaskRequest. Safe to call multiple
    /// times — if a request is already pending, the OS silently replaces it.
    static func schedule() {
        let req = BGProcessingTaskRequest(identifier: taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: retryInterval)
        req.requiresNetworkConnectivity = false
        req.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(req)
            NSLog("[bg-task] scheduled (earliest +\(Int(retryInterval))s)")
        } catch {
            // .notPermitted fires in the Simulator (expected).
            // .tooManyPendingTaskRequests is harmless — prior request still queued.
            NSLog("[bg-task] schedule failed (ignored): \(error)")
        }
    }
}
