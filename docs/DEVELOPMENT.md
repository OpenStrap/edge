# Development

How to build and run OpenStrap Edge from source, and how the pieces fit together.
For which repo a change belongs in, tests, and the CLA, see
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Build and run

Needs Flutter **3.41.6** (the version CI builds with; newer 3.x releases aren't
supported yet). The `protocol` and `analytics` packages are pulled from git, pinned
to exact commits in `pubspec.yaml`, so `pub get` fetches them for you.

```bash
git clone https://github.com/OpenStrap/edge.git
cd edge
cp .env.example .env
flutter pub get
flutter run --dart-define-from-file=.env
```

Close the device maker's own app before you pair. Bluetooth only lets one app own a
device at a time.

iOS signing and the App Group setup for the widget and Live Activity take a few more
steps; see [guides/IOS_INSTALLATION.md](../guides/IOS_INSTALLATION.md). To sideload the
unsigned IPA instead of using TestFlight, see
[guides/IOS_SIDELOAD.md](../guides/IOS_SIDELOAD.md).

## Install channels

- **iOS:** public TestFlight beta. TestFlight gets new builds first.
- **Android:** APK on [GitHub Releases](https://github.com/OpenStrap/edge/releases/latest).
  Cut less often, so it can trail TestFlight by a version or two.
- **F-Droid:** not listed yet. A build recipe that swaps out the Google-backed pieces
  (Firebase, ML Kit barcode scanning, Play Services location) is drafted in
  [docs/fdroid/](fdroid/).

## How it works

```
wearable -> Bluetooth -> protocol decoder -> local storage -> analytics -> UI
```

- [`openstrap_protocol`](https://github.com/OpenStrap/protocol) turns bytes from the
  device into records.
- [`openstrap_analytics`](https://github.com/OpenStrap/analytics) turns those records
  into metrics, each with its own confidence score. Nothing gets filled in when the
  data isn't there.
- This repo is the glue: Bluetooth reliability, local storage (versioned, so an
  algorithm update never silently overwrites old results), background sync, and the UI.
- Everything that matters stays on the phone.

A few rules the sync path depends on: the device clock is set on connect, history
arrives in batches that each need an acknowledgement, and every batch is saved locally
before it is acknowledged, so a crash mid-sync can't lose data. The protocol repo's
README has the details.

## Background sync

The device drains without you opening the app.

- **Android:** a foreground service with a 15-minute watchdog worker, re-attached via
  CompanionDeviceManager.
- **iOS:** a background processing task plus a light refresh task, and a separate
  restore Bluetooth central that relaunches the app when the device reconnects. Apple
  decides when those tasks run, so iOS background sync is best-effort.

## Repo layout

See [CONTRIBUTING.md](../CONTRIBUTING.md#repo-layout) and `AGENTS.md` §2.
