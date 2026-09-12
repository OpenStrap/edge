# Syncing with iOS Shortcuts

## Sync Data

On iOS 16 and later, add **Edge → Sync Data** to a shortcut. Pair your band in Edge and grant Bluetooth access before using an unattended automation. The action runs without opening Edge's interface. It starts a real band sync, rather than scheduling a discretionary background refresh or simulating a refresh gesture.

Expand the action to enable **Ignore Connectivity Errors**. It is off by default. When enabled, Bluetooth being unavailable or the paired band being unreachable returns a successful text result beginning with `Skipped:` instead of throwing an action error. Missing pairing, denied Bluetooth permission, startup failures, and other failures are not suppressed. The action does not display a dialog or post a notification of its own. This option cannot disable notifications or progress UI that iOS or Shortcuts independently chooses to display.

For a personal automation, choose a Time of Day trigger, select **Run Immediately** where offered, and run the shortcut. Configure the automation's own notification options separately. Several daily triggers can provide several sync opportunities; they do not guarantee that the band is reachable or that iOS will finish every invocation.

### Results

- **Band data synchronized:** the band transfer completed and Edge requested light processing and refreshed its widget snapshot. An existing derivation takes precedence. This is not a claim that every historical day has received full heavy analysis or that HealthKit export completed.
- **Sync is incomplete:** the invocation ran out of time or the transfer ended early. Previously saved data is retained. Run the action again or open Edge for a longer catch-up.
- **A sync request is already active:** another request owns the sync path. No competing transfer was started.
- **Skipped:** one of the two opted-out connectivity failures occurred; no successful sync is claimed.

The ordinary action has a 25-second native deadline, including Flutter startup. The Dart transfer receives a slightly shorter budget so it can report partial progress before that deadline. An iOS interruption can still prevent a result from being returned. Apple's ordinary App Intent execution budget is approximately 30 seconds; see [LongRunningIntent](https://developer.apple.com/documentation/appintents/longrunningintent).

## Sync Data (Long Running)

On iOS 27 and later, builds made with Xcode 27 or later also expose **Sync Data (Long Running)**. It uses Apple's `LongRunningIntent` and `CancellableIntent` in the main app process, with the same sync bridge, persistence path, and **Ignore Connectivity Errors** option. The ordinary action remains available on iOS 16 and later; the app's deployment target is unchanged.

The long-running action requests extended execution through `performBackgroundTask`. Its own deadline is ten minutes, including startup; this is a limit imposed by Edge, not a promise that iOS will grant ten minutes. System cancellation and timeouts cancel the matching sync request and preserve committed data.

The system manages the progress Live Activity and its stop control. Progress counts actual saved batches and stays indeterminate because the band does not provide a reliable total batch count. Only a completed sync marks progress complete; partial, skipped, and already-running results do not. The connectivity-error option does not suppress this system UI. See [Apple's long-running intent walkthrough](https://developer.apple.com/videos/play/wwdc2026/345/).

## Lifecycle and data safety

For an interactive fallback, **Open Edge and Sync** brings the app forward and invokes the same sync bridge. It is not intended for unattended locked-device automations. The action itself remains bounded, but an app-owned session can keep catching up while Edge is open.

The application retains one headless-capable Flutter engine. Foreground scenes attach to that same engine, keeping the UI, background wakes, and Shortcuts in one isolate with the same band-ownership guards. The native bridge waits for an explicit Dart readiness handshake, correlates replies with requests, and ignores late replies after cancellation.

An existing app-owned connection and sync burst are reused. Otherwise the action takes the existing headless gate and band lease and uses the same `BleEngine` and `BandHost` persistence callbacks as normal background sync. Records and the durable cursor are committed before a batch is acknowledged to the band.

Cancellation or a deadline stops an action-owned connection. Its gate and lease remain held until serialized BLE cleanup finishes. Cancelling a Shortcut does not disconnect an independent app-owned live session; that session can continue its normal synchronization. A Shortcut never pretends to finish merely because it started asynchronous work.

## Validation

The Dart task tests cover completion, deadline classification, cancellation, progress suppression after cancellation, and ownership retention during cleanup. The iOS Runner tests cover bridge readiness, concurrent requests, late replies, cancellation, malformed responses, and the exact connectivity-error allowlist. Long-running tests also cover its extended budget, truthful progress, and cancellation before dispatch. A clean-simulator integration test calls through the real Flutter bridge and expects a missing-pairing error rather than success.

The separate **ShortcutIntents** Xcode scheme uses Apple's `AppIntentsTesting` framework on iOS 27 to exercise background invocation, relaunch after termination, and the foreground fallback through the system's intent infrastructure. It does not replace the ordinary **Runner** scheme or raise the application's deployment target. Use a clean simulator and a separate bundle identifier so these tests cannot use a real pairing or change an existing installation:

```sh
flutter pub get
flutter build ios --simulator --debug
cd ios
xcodebuild -workspace Runner.xcworkspace -scheme Runner \
  -destination "id=$SIMULATOR_ID" -only-testing:RunnerTests \
  BUILD_DIR="$PWD/../build/ios" CODE_SIGNING_ALLOWED=NO \
  APP_BUNDLE_IDENTIFIER=com.example.openstrapEdge.shortcuttests \
  APP_GROUP_IDENTIFIER=group.com.example.openstrap.shortcuttests test
```

For the system-invocation tests, use Xcode 27 with an iOS 27 simulator and replace `-scheme Runner -only-testing:RunnerTests` with `-scheme ShortcutIntents`. Unlike the native Runner tests, `AppIntentsTesting` requires the app and UI test runner to be development-signed by the same team. Replace `CODE_SIGNING_ALLOWED=NO` with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" APPLE_DEVELOPMENT_TEAM="$TEAM_ID"`, where `TEAM_ID` is your Apple development team. See [Apple's AppIntentsTesting walkthrough](https://developer.apple.com/videos/play/wwdc2026/295/).

Simulator tests do not establish real Bluetooth transfer reliability. Before relying on an unattended automation, test on an iPhone with a paired band:

| Scenario | Expected behavior |
| --- | --- |
| Edge open, then suspended | The same connection is reused; no duplicate drain. |
| Edge terminated, then action invoked | Flutter starts without requiring a visible scene and the action reaches the sync service. |
| Phone locked | The action can attempt to run, subject to storage availability and iOS policy. |
| Bluetooth off or band out of range | Error with the option off; successful `Skipped:` result with it on. |
| Bluetooth permission denied | Error with either option value. |
| Large backlog or cancellation | No false completion or ACK of unsaved data; a later run can resume. |
| UI refresh overlaps the action | Only one transfer owns the band. |

Test force-quit followed by a scheduled personal automation separately from Bluetooth state restoration. These are different launch mechanisms; neither a foreground test nor a Simulator test proves the force-quit/locked-device scheduling case.
