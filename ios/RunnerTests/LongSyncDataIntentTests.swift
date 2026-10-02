#if compiler(>=6.4)
import AppIntents
import Foundation
import Flutter
import XCTest
@testable import Runner

@MainActor
final class LongSyncDataIntentTests: XCTestCase {
  func testProgressUsesRealBatchesWithoutAnInventedPercentage() throws {
    guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
    let progress = Progress(totalUnitCount: 0)
    LongSyncProgress.start(progress)
    XCTAssertLessThan(progress.totalUnitCount, 0)
    LongSyncProgress.update(progress, with: ["phase": "syncing", "batches": 8])
    XCTAssertEqual(progress.completedUnitCount, 8)
    XCTAssertLessThan(progress.totalUnitCount, 0)
    LongSyncProgress.update(progress, with: ["phase": "syncing", "batches": 3])
    XCTAssertEqual(progress.completedUnitCount, 8)
    LongSyncProgress.update(progress, with: ["phase": "processing", "batches": 8])
    XCTAssertLessThan(progress.totalUnitCount, 0)
    LongSyncProgress.finish(progress)
    XCTAssertEqual(progress.fractionCompleted, 1)
  }

  func testCancelledProgressCannotBecomeCompleted() throws {
    guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
    let progress = Progress(totalUnitCount: 0)
    LongSyncProgress.start(progress)
    progress.cancel()
    LongSyncProgress.update(progress, with: ["phase": "syncing", "batches": 9])
    LongSyncProgress.finish(progress)
    XCTAssertEqual(progress.completedUnitCount, 0)
    XCTAssertLessThan(progress.totalUnitCount, 0)
  }

  func testLongRunningResultsAndSuppressionRemainTruthful() async throws {
    guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
    for status in ["complete", "partial", "alreadyRunning", "bluetoothUnavailable",
                   "bandUnreachable", "permissionDenied", "notPaired", "failed"] {
      for ignore in [false, true] {
        let bridge = ShortcutSyncBridge { method, args, reply in
          XCTAssertEqual(method, "run")
          let budget = (args as! [String: Any])["budgetMs"] as! Int
          XCTAssertGreaterThan(budget, 590_000)
          XCTAssertLessThan(budget, 600_000)
          reply(["status": status, "records": 3])
        }
        bridge.receive(FlutterMethodCall(methodName: "ready", arguments: nil)) { _ in }
        var intent = LongSyncDataIntent()
        intent.ignoreConnectivityErrors = ignore
        let progress = Progress(totalUnitCount: 0)
        LongSyncProgress.start(progress)
        let success = ["complete", "partial", "alreadyRunning"].contains(status)
        let suppressed = ignore && ["bluetoothUnavailable", "bandUnreachable"].contains(status)
        do {
          let message = try await intent.syncMessage(using: bridge, id: "long", progress: progress)
          XCTAssertTrue(success || suppressed, "Unexpected success for \(status)")
          XCTAssertEqual(message.hasPrefix("Skipped:"), suppressed)
          if status == "complete" {
            XCTAssertEqual(progress.fractionCompleted, 1)
          } else {
            XCTAssertLessThan(progress.totalUnitCount, 0)
          }
        } catch let error as ShortcutSyncFailure {
          XCTAssertFalse(success || suppressed)
          XCTAssertEqual(error.code, status)
        }
      }
    }
  }

  func testSystemCancellationBeforeRegistrationNeverStartsDartSync() async throws {
    guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
    var dispatched = false
    let bridge = ShortcutSyncBridge { _, _, _ in dispatched = true }
    bridge.receive(FlutterMethodCall(methodName: "ready", arguments: nil)) { _ in }
    let progress = Progress(totalUnitCount: 0)
    progress.cancel()
    do {
      _ = try await LongSyncDataIntent().syncMessage(using: bridge, id: "cancelled", progress: progress)
      XCTFail("Cancellation before registration must not be lost")
    } catch let error as ShortcutSyncFailure {
      XCTAssertEqual(error.code, "cancelled")
    }
    XCTAssertFalse(dispatched)
  }
}
#endif
