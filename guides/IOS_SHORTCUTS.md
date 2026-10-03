# Syncing with iOS Shortcuts

## Sync Data

On iOS 16 and later, add **Edge → Sync Data** to a shortcut. Pair your band in Edge and allow Bluetooth first. The action syncs the band without opening the app.

**Ignore Connectivity Errors** (off by default): when Bluetooth is off or the band is out of range, the action returns a `Skipped:` result instead of an error. Pairing, permission and other errors are still reported.

For a personal automation, pick a Time of Day trigger and **Run Immediately**. Several triggers a day give several chances to sync; none of them guarantee the band is in range.

The action has about 25 seconds, including app startup. A large backlog can need more than one run, or open Edge to catch up.

### Results

- **Band data synchronized:** the transfer finished and light processing was started.
- **Sync is incomplete:** it ran out of time or the transfer stopped early. Saved data is kept; run it again.
- **A sync request is already active:** another sync owns the band, so nothing new was started.
- **Skipped:** Bluetooth was unavailable or the band was unreachable, with the option on.

## Open Edge and Sync

Brings the app forward and runs the same sync. Use it interactively, not from locked-phone automations.

## Native tests

```sh
flutter build ios --simulator --debug
cd ios
xcodebuild -workspace Runner.xcworkspace -scheme Runner \
  -destination "id=$SIMULATOR_ID" -only-testing:RunnerTests \
  BUILD_DIR="$PWD/../build/ios" CODE_SIGNING_ALLOWED=NO \
  APP_BUNDLE_IDENTIFIER=com.example.openstrapEdge.shortcuttests \
  APP_GROUP_IDENTIFIER=group.com.example.openstrap.shortcuttests test
```

The `ShortcutIntents` scheme runs the system-invocation tests. It needs Xcode 27, an iOS 27 simulator, and a development-signed build.
