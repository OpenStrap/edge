# Edge

The phone app — it talks to the WHOOP 4.0 band over Bluetooth, drains its data, and
shows you what your strap is actually measuring.

> Not affiliated with or endorsed by WHOOP. For a band you own.

## What it does
Edge connects to the band, runs the historical drain (non-destructively — it never
erases the device), keeps a live HR/PPG/IMU stream when you want it, and uploads the
**raw** records to your backend. It stores everything locally first (raw-first), so a
flaky connection or a dead network never loses data — it just syncs when it can.

Everything analytical happens server-side; the app renders. The screens are an
"Ember on Paper" design — recovery, sleep, strain, stress, trends, a coach, day-level
drill-downs, a home/lock-screen widget, and a live-workout Live Activity.

It's honest by design: every metric shows its confidence, estimates are labelled, and
where the hardware can't support something (HRV, clinical temperature) the app says so
instead of inventing a number.

## Backend URL
The app doesn't ship a hardcoded server. `BACKEND_URL` is injected at build time:
```
cp .env.example .env        # set BACKEND_URL=...
flutter run --dart-define-from-file=.env
```
If it's empty, onboarding asks you for your own self-hosted backend. CI builds inject
it from a repo secret (see `.github/workflows/build.yml`).

## Run
```
flutter pub get
flutter run --dart-define-from-file=.env
```
Needs the band free (force-quit the official WHOOP app first — Bluetooth is one
central at a time).

## Layout
- `lib/ble`, `lib/protocol` — connect, frame, decode.
- `lib/sync` — local store + upload.
- `lib/state` — the app's single source of truth.
- `lib/ui` — the screens.
- `ios/OpenStrapWidget` — the home/lock-screen widget + Live Activity.
