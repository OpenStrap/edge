# iOS Installation

This guide covers the iOS setup needed to build and run Edge from a public
checkout. The project uses widgets, Live Activities, and an App Group, so every
developer needs Apple identifiers that belong to their own Apple Developer
account.

## Prerequisites

- Flutter installed and available on `PATH`.
- Xcode installed with iOS support.
- CocoaPods installed.
- An Apple Developer account or team that can create App IDs and App Groups.
- A physical iPhone for BLE testing. The simulator is useful for UI work, but it
  cannot test the WHOOP Bluetooth integration.

Check the local toolchain:

```bash
flutter doctor -v
flutter devices
```

## Project Setup

From the repository root:

```bash
cp .env.example .env
flutter pub get
```

Edit `.env` and set your backend URL:

```text
BACKEND_URL=https://your-backend.example
```

The app can ask for a backend URL during onboarding if no value is provided, but
using `.env` keeps local builds repeatable.

## Local iOS Signing Config

The committed iOS project uses placeholder identifiers so the public repo does
not depend on one developer's Apple account. Personal signing values belong in
`ios/Config/Signing.xcconfig`, which is ignored by git.

Create your local signing override:

```bash
cp ios/Config/Signing.xcconfig.example ios/Config/Signing.xcconfig
```

Edit `ios/Config/Signing.xcconfig`:

```text
APP_BUNDLE_IDENTIFIER = com.yourname.openstrapEdge
APP_WIDGET_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER).OpenStrapWidget
APP_GROUP_IDENTIFIER = group.com.yourname.openstrap
APPLE_DEVELOPMENT_TEAM = YOURTEAMID
```

Default committed values live in `ios/Config/Signing.defaults.xcconfig`:

```text
APP_BUNDLE_IDENTIFIER = com.example.openstrapEdge
APP_WIDGET_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER).OpenStrapWidget
APP_GROUP_IDENTIFIER = group.com.example.openstrap
APPLE_DEVELOPMENT_TEAM =
```

Do not commit `ios/Config/Signing.xcconfig`.

## Apple Developer Setup

Create matching identifiers in Apple Developer:

1. App ID for `APP_BUNDLE_IDENTIFIER`.
2. App ID for `APP_WIDGET_BUNDLE_IDENTIFIER`.
3. App Group for `APP_GROUP_IDENTIFIER`.
4. Enable App Groups on both App IDs.
5. Attach the same `APP_GROUP_IDENTIFIER` to both App IDs.

The entitlement files use `$(APP_GROUP_IDENTIFIER)`, and the native widget reads
the same value from its generated Info.plist. Dart reads the App Group value from
iOS at runtime through `openstrap/ios_config`, so Xcode builds do not need a
separate `--dart-define` to keep the widget bridge aligned.

## Xcode Setup

Open the workspace, not the project:

```bash
open ios/Runner.xcworkspace
```

In Xcode:

1. Select the `Runner` project.
2. Verify signing for the `Runner` target.
3. Verify signing for the `OpenStrapWidget` target.
4. Confirm both targets show the same App Group capability.
5. Select your physical iPhone as the run destination.

If Xcode changes `ios/Runner.xcodeproj/project.pbxproj` while you are adjusting
personal signing settings, do not commit those personal changes. Put the values
in `ios/Config/Signing.xcconfig` instead and revert the project file.

## Build and Run

For a normal development run attached to Flutter tooling:

```bash
flutter run -d <device-id> --dart-define-from-file=.env
```

For a no-codesign build check:

```bash
flutter build ios --release --no-codesign
```

For a signed release-style device install:

```bash
flutter run --release -d <device-id> --dart-define-from-file=.env
```

## Debug Builds and Home-Screen Relaunch

Flutter debug builds on iOS must be launched by Flutter tooling or Xcode. If you
install a Debug build, close it, and later tap the app icon from the iPhone home
screen, Flutter can terminate during engine startup with:

```text
Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode.
```

Use Debug when you are attached to Xcode or `flutter run`. Use Profile or Release
when you want to test normal home-screen launch, close, and relaunch behavior:

```bash
flutter run --profile -d <device-id> --dart-define-from-file=.env
flutter run --release -d <device-id> --dart-define-from-file=.env
```

In Xcode, keep the shared scheme's Run action on Debug for development. If you
need home-screen relaunch testing from an Xcode-installed build, temporarily set
Product > Scheme > Edit Scheme > Run > Build Configuration to Profile or Release
locally.

## Common Issues

- Open `ios/Runner.xcworkspace`, not `ios/Runner.xcodeproj`.
- If App Group signing fails, verify both App IDs have the same App Group
  enabled in Apple Developer.
- If widgets cannot read app data, verify `APP_GROUP_IDENTIFIER` is identical in
  Apple Developer and `ios/Config/Signing.xcconfig`.
- If a physical iPhone is on a newer iOS version than your installed Xcode
  supports, update Xcode or install the matching iOS support/runtime.
- Quit the official WHOOP app before connecting the band. Bluetooth only lets
  one app own the band at a time.
