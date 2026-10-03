#if canImport(AppIntentsTesting)
import AppIntentsTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class ShortcutUITests: XCTestCase {
  private let app = XCUIApplication()

  private var definitions: IntentDefinitions {
    get throws {
      let identifier = try XCTUnwrap(Bundle(for: Self.self).object(
        forInfoDictionaryKey: "TestedAppBundleIdentifier") as? String)
      return IntentDefinitions(bundleIdentifier: identifier)
    }
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    app.launch()
  }

  func testSyncFromBackgroundUsesRealAppIntentInfrastructure() async throws {
    backgroundApp()
    try await expectPairingError("SyncDataIntent")
    XCTAssertNotEqual(app.state, .runningForeground)
  }

  func testForegroundFallbackUsesTheSameSyncEntryPoint() async throws {
    backgroundApp()
    do {
      _ = try await definitions.intents["OpenEdgeAndSyncIntent"].makeIntent().run()
      XCTFail("The interactive action must not invent a successful sync")
    } catch {
      XCTAssertTrue(String(describing: error).contains("Open Edge and pair your band first."), "\(error)")
    }
    XCTAssertEqual(app.state, .runningForeground)
  }

  func testSyncRelaunchesTerminatedAppWithoutOpeningAWindow() async throws {
    let intent = try definitions.intents["SyncDataIntent"]
      .makeIntent(ignoreConnectivityErrors: true)
    app.terminate()
    do {
      _ = try await intent.run()
      XCTFail("A clean simulator cannot successfully sync an unpaired band")
    } catch {
      XCTAssertTrue(String(describing: error).contains("Open Edge and pair your band first."), "\(error)")
    }
    XCTAssertNotEqual(app.state, .runningForeground)
    app.activate()
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 15),
                  "The foreground scene must render after a headless engine launch")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Edge after background Shortcut launch"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func backgroundApp() {
    XCUIDevice.shared.press(.home)
    let background = XCTNSPredicateExpectation(
      predicate: NSPredicate { [app] _, _ in
        app.state == .runningBackground || app.state == .runningBackgroundSuspended
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed,
                   "The Home transition must finish before invoking the intent")
  }

  private func expectPairingError(_ identifier: String) async throws {
    do {
      _ = try await definitions.intents[identifier]
        .makeIntent(ignoreConnectivityErrors: true).run()
      XCTFail("Missing pairing is not an ignorable connectivity failure")
    } catch {
      XCTAssertTrue(String(describing: error).contains("Open Edge and pair your band first."), "\(error)")
    }
  }
}
#endif
