# Contributing

Thanks for looking. This is a small project and PRs genuinely get read.

## Which repo does my change go in?

This is the one thing worth getting right before you start, because it decides
where the code lives. OpenStrap is three packages and the split is strict:

| Your change | Repo |
|---|---|
| A new record type, opcode, event, or anything about the bytes on the wire | [**protocol**](https://github.com/OpenStrap/protocol) |
| A new metric, or a change to how an existing number is computed | [**analytics**](https://github.com/OpenStrap/analytics) |
| Bluetooth reliability, storage, background sync, UI, anything app-shaped | [**edge**](https://github.com/OpenStrap/edge) (here) |

If you're not sure, open an issue first and ask — it's cheaper than moving code
between repos afterwards.

## Ground rules

**Never fabricate a number.** If an input isn't there, the metric returns
`null`, not a plausible-looking guess. Every metric carries a confidence and a
tier (`AUTH` / `HIGH` / `ESTIMATE` / `RELATIVE`), and those need to stay honest.
A metric that quietly invents a value when the data is missing is worse than no
metric.

**Cite the method.** Anything in analytics implements a published, peer-reviewed
algorithm, and the citation goes in a comment next to the code. If nothing in
the literature fits what you want to do, that's fine — mark it `ESTIMATE`, give
it low confidence, and say so. Don't invent constants and present them as
science.

**Some ceilings are real, not bugs.** HRV here is PRV derived from 1 Hz beat
timing. Deep sleep is a low-confidence HR-flatness overlay. SpO2 and skin
temperature are relative ADC values, never absolute. These are properties of
what the band actually hands over. Please don't "fix" them by making the output
look more confident than the input justifies.

**Bump `kAlgoVersion`** (in `lib/compute/derivation_engine.dart`) whenever a
change alters any analytics output. Stored day results are versioned and
immutable; without a bump, devices keep serving stale values. If your bump's
changelog entry cites an analytics change, check that the pinned analytics SHA
in `pubspec.yaml` actually contains it — that mismatch has shipped a bug before.

**Put logic in the pure policy classes.** Bluetooth decisions belong in
`lib/ble/ble_state.dart` or `lib/sync/sync_policy.dart` as small, testable
classes; the engine wires them together and the policies decide. That's what
makes any of this testable without a band on your wrist.

## Repo layout

```
lib/ai/        BYOK AI assistant: briefings, journal AI, nightly sweep
lib/ble/       Bluetooth link + history-sync state machine
lib/cloud/     optional companion/backend + cloud import clients
lib/coach/     read-only SQL coach over allow-listed views
lib/compute/   runs the analytics pipeline, writes results
lib/data/      local storage + the repository seam the UI reads from
lib/debug/     debug-mode flags
lib/ecg/       ECG readings
lib/gestures/  device action / gesture dispatch
lib/gps/       GPS route tracking for outdoor activities
lib/health/    HealthKit / Health Connect import + export
lib/import/    backup + third-party data import
lib/l10n/      translations (.arb)
lib/live/      Live Activity / breathing session
lib/models/    shared data models (Metric, payloads, app status)
lib/notify/    the single notification emitter + alert policies
lib/platform/  platform-channel glue (app icon, Tasker, device actions)
lib/scan/      barcode scanning (swapped for a FOSS reader in the F-Droid build)
lib/state/     AppState, the one source of truth, plus its sync/workout/live controllers
lib/stress/    guided-breathing session logic
lib/sync/      background/headless sync policies
lib/telemetry/ opt-in error + usage telemetry
lib/theme/     design tokens, theming, transitions
lib/ui2/       every screen
lib/widget/    App-Group snapshot for the home-screen/watch widget
```

See `AGENTS.md` §2 for the full architecture map, invariants, and the biggest
files by ownership. Build steps and how the pieces fit together are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Running it

```bash
git clone https://github.com/OpenStrap/edge.git
cd edge
cp .env.example .env
flutter pub get
flutter run --dart-define-from-file=.env
```

Quit the official WHOOP app before pairing — Bluetooth only lets one app own the
band at a time.

For local work across all three packages at once, create a `pubspec_overrides.yaml`
(it's gitignored) pointing at your sibling checkouts:

```yaml
dependency_overrides:
  openstrap_protocol:
    path: ../protocol
  openstrap_analytics:
    path: ../analytics
```

## Tests

```bash
flutter analyze
flutter test --concurrency=1
```

`--concurrency=1` matters: the suite runs against real database files and
parallel workers race on them.

A few tests replay `whoop_hist.jsonl`, a real band capture kept *beside* the
repo rather than committed to it. If you don't have it those tests skip
automatically — that's expected, and CI runs the same way. Everything else runs
everywhere.

CI runs `flutter analyze` and the full suite on every PR. Please make sure both
are green locally first.

## Pull requests

- Branch off `main`. One logical change per PR.
- Explain *why*, not just what. If it fixes an issue, link it.
- If it changes anything a user sees, say what it looked like before and after.
- Protocol changes: say how you verified it. "Decoded N real records off my own
  band and the values were plausible" is a perfectly good answer, and honestly
  more useful than a unit test alone.
- No `Co-Authored-By` trailers.

## Translations

The app's strings live in `lib/l10n/app_en.arb` (the source of truth — only a
handful of strings are wired up so far, more get pulled in over time). To add
a language: copy `app_en.arb` to `app_<code>.arb` (e.g. `app_es.arb`) in the
same folder, translate the values, and keep every key identical to the
English file. Run `flutter gen-l10n` to regenerate, then add your language's
display name to `_kLanguageNames` in `lib/ui2/profile/profile.dart` so it
shows up in the picker. Open a PR.

## Reporting protocol findings

If you've worked out a field, an opcode, or an event we don't decode yet, that's
one of the most valuable things you can contribute. Open an issue in
[protocol](https://github.com/OpenStrap/protocol/issues) with the raw bytes, what
you think the field is, and how you convinced yourself. A lot of the current
event table is empirical guesswork by one person — more eyes genuinely helps.

## A note on scope

This project talks to hardware people already own, using their own data, on
their own device. Please keep contributions within that: no scraping WHOOP's
services, no redistributing their code, firmware, or assets, and no vendored
third-party material whose licences don't permit it.
Facts about a protocol are fine. Someone else's source code is not.

## License

OpenStrap is licensed under AGPL-3.0 (see [LICENSE](LICENSE)). By contributing, you
agree that your contributions are licensed under the same AGPL-3.0 terms. You keep the
copyright in your work.

The OpenStrap name and logo are covered separately by [TRADEMARKS.md](TRADEMARKS.md).
