# Edge

This is the app you actually hold. It connects to a WHOOP 4.0 band over Bluetooth, pulls
the data off it, and computes everything **on the phone itself**. Flutter, runs on iOS
and Android. There's no cloud, no backend that sees your health data, no server this app
depends on to work day to day.

> Not affiliated with WHOOP. This is for a band you own.

## First, the honest version

If your WHOOP subscription has lapsed and the band's just sitting there, this gives it
something to do again. You get your heart rate, your sleep, a strain number, a recovery
number, trends over time. It's real and it's useful.

Is it WHOOP? No. I'm not going to oversell this. WHOOP has years of research and a team;
this is one person, published equations, and a protocol I decoded myself. The numbers
here are honest approximations of what your band can actually support, not a clone of
their scores. Think of it as rescuing the hardware, not replacing the service. If you're
happily paying WHOOP, stay there. If your band would otherwise be e-waste, this is better
than a drawer.

And there are bugs. I know about some, probably not all. If something looks wrong, it
might be wrong, open an issue and I'll chase it down. This gets better the more people use
it and report what breaks.

**One important thing:** once you start using this, don't reconnect the band to the
official WHOOP app. It might push a firmware update, and that could change or break the
events and records this depends on. I've only tested on WHOOP 4.0 as it ships today. Pick
one app and stick with it.

## Screens

Today (readiness + the day's plan), Sleep, Heart, Stress, an HRV spot-check, Activity
(strain + auto-detected workouts + live workout with GPS routes), Cycle tracking, a
Journal (with on-device personal correlation insights — "what actually moves your
numbers", never a cloud model), Journey/Timeline/Records for longitudinal trends, a
deterministic Coach, a BYOK text-based AI assistant, a shareable weekly Recap, Onboarding,
Pairing, and Profile. Every metric drills through the same shared trend screen
(Today/Week/Month/3M with inline drill-down), so it looks and behaves the same everywhere.

| | | |
|:--:|:--:|:--:|
| <img src="screenshots/today.png" width="230"><br>**Today** | <img src="screenshots/sleep.png" width="230"><br>**Sleep** | <img src="screenshots/heart.png" width="230"><br>**Heart** |
| <img src="screenshots/stress.png" width="230"><br>**Stress** | <img src="screenshots/breathing.png" width="230"><br>**Breathing** | <img src="screenshots/body.png" width="230"><br>**Body** |
| <img src="screenshots/steps.png" width="230"><br>**Steps** | <img src="screenshots/workouts.png" width="230"><br>**Workouts** | <img src="screenshots/records.png" width="230"><br>**Records** |
| <img src="screenshots/recap.png" width="230"><br>**Recap** | <img src="screenshots/profile.png" width="230"><br>**Profile** | |

iOS also gets a home-screen widget, a lock-screen/Dynamic Island Live Activity (workouts
and, more recently, live coherence during a guided breathing session), and a couple of
Siri intents (check your recovery/strain/sleep, start a breathing session) via App
Intents.

| | | |
|:--:|:--:|:--:|
| <img src="screenshots/widget.jpg" width="300"><br>**Widget** | <img src="screenshots/battery-widget.jpg" width="200"><br>**Battery widget** | <img src="screenshots/live-activity.jpg" width="300"><br>**Live Activity** |

> Numbers shown are real output from a WHOOP 4.0. Every figure carries a confidence and
> estimates are labelled as such — see the two analytics repos this depends on for the
> actual honesty contract.

## How it's put together

The flow, top to bottom:

```
   the screens (lib/ui)  ──read──►  AppState (lib/state)
                                        the one source of truth
        │                                    │
        ▼                                    ▼
   BleEngine (lib/ble)             LocalRepository (lib/data)
   talks to the band                reads/writes LocalDb (sqflite)
        │                                    │
        └─ frames ─► openstrap_protocol ─► decoded_onehz / decoded_rr
             (separate package: framing,        (the durable ledger)
              CRC, record/command decode)             │
                                                        ▼
                                          DerivationEngine (lib/compute)
                                          runs openstrap_analytics over the
                                          substrate, writes versioned
                                          day_result rows (kAlgoVersion)
```

`AppState` is a `ChangeNotifier` and it's the only thing the UI ever reads. It owns the
BLE engine and the local repository seam; screens don't talk to Bluetooth or SQL
directly. The actual decode logic (bytes → records) and the actual analytics (records →
metrics) both live in **separate, independent packages** —
[openstrap-protocol-dart](https://github.com/OpenStrap/protocol) and
[openstrap-analytics-onehz](https://github.com/OpenStrap/analytics) — pulled in as git
dependencies. This app is the glue: BLE reliability, local storage, and the UI.

## The Bluetooth part, which is the hard part

`BleEngine` in `lib/ble/ble_engine.dart` (~3k lines) is where the real work is. The band
speaks a custom GATT service (`61080001-...`): one characteristic you write commands to, a
few you subscribe to for responses, events, and data.

A sync goes like this. Connect, bond (Android needs an explicit bond), bump the MTU to
247, subscribe to the notify characteristics. Then set the clock, because the band ships
with its real-time clock unset and if you skip this every record gets a garbage
timestamp. Then fire the five-packet intro that ends with "send me your history," and the
band starts draining records from its flash.

Here's the bit that trips everyone up. The band sends records in batches, and after each
batch it sends a marker carrying an 8-byte token. You have to read that token out and
send it straight back, with a write-that-waits-for-acknowledgement, not a fire-and-forget
write. Echo it exactly and the read cursor moves forward. Echo it wrong, or use the wrong
write type, and the band re-sends the same batch over and over — forever, since it never
trims flash for data it doesn't think you've confirmed. The commit to local storage
happens **before** that acknowledgement is sent (in the same transaction), never after —
so a crash mid-sync can't lose data or double-trim the band.

This app deliberately runs ONE continuous listening mode — no separate "sync" vs. "live"
connection state to flip between, since that flip used to cause its own re-flood bug.
Live high-rate streams (0x2B/0x33) are never written to disk; only the decoded 1 Hz
substrate and RR beats are durable.

Two more things the engine is careful about. Live commands and sync acknowledgements use
separate sequence-number ranges so they never collide. And the genuinely dangerous
commands — the ones that erase flash, reboot the strap, or push firmware — are behind an
explicit guard and never auto-sent; optical/PPG is wrist-gated only. You don't want to
brick a band.

## Why the database looks the way it does

`lib/data/db.dart` (sqflite, WAL). There is no `raw_records` table anymore — it was
dropped in favor of a decoded-first ledger:

- **`decoded_onehz`** + **`decoded_rr`** — the durable 1 Hz substrate (HR, accel, RR
  beats), keyed so a band counter-reset recovers cleanly (newest-wins by timestamp, not a
  naive insert-or-ignore).
- **`raw_archive`** — records the decoder couldn't parse (unknown/unsupported firmware
  version) land here, **never pruned**, so a future firmware update to the decoder can
  re-derive them from bytes that were never thrown away.
- **`day_result`** — versioned by `(day_id, kAlgoVersion)`; an algorithm change writes a
  new row rather than mutating history, and a day is only pruned from the raw ledger
  after it's actually been derived (not just attempted — a day whose derivation failed
  keeps its raw substrate around for a real retry).

Decoded rows get pruned once the covering day is safely derived; the raw archive and
finalized derived results are kept.

## Syncing in the background

You shouldn't have to open the app for it to work, but the two platforms get there very
differently, and it's worth being honest about which one is more reliable.

**Android**: a foreground service (`EdgeTrackingService`) keeps the process and the BLE
connection alive, backed by `CompanionDeviceManager` device-presence observation and a
periodic watchdog worker. This is the reliable path.

**iOS**: there's no foreground-service equivalent, so this leans on a few overlapping
mechanisms — a live BLE connection kept alive via `UIBackgroundModes: bluetooth-central`
while the app is backgrounded, a separate CoreBluetooth-restoration central that
relaunches the app when the band reappears if the live connection ever drops, and a
`BGProcessingTask` + a lighter `BGAppRefreshTask` for opportunistic catch-up sync. iOS
decides if/when those background tasks actually run; a force-quit app gets none of them.
This is the honest ceiling of what's possible without a foreground-service equivalent —
covered, not guaranteed, and every wake is a "skip, don't queue" event (a missed wake just
gets caught up by the next one, never queued up to thrash).

## Getting around the code

| Where | What's there |
|-------|--------------|
| `lib/ble/` | the BLE engine: connect, sync/drain, live streams, reconnect policy |
| `lib/data/` | the local SQLite store (`db.dart`) and the repository seam (`local_repository_impl.dart`) the UI actually reads |
| `lib/compute/` | `DerivationEngine` — runs `openstrap_analytics` over the substrate, writes `day_result` |
| `lib/sync/` | background-sync policy classes, the headless-entry gate, iOS BGTask wiring |
| `lib/cloud/` | the narrow, non-primary network surface: a one-time legacy-account import, OTA/announcement pointer, and the BYOK LLM proxy — **not an ongoing backend for your health data** |
| `lib/state/` | `AppState`, the one source of truth |
| `lib/ui/` | every screen — today, sleep, heart, stress, spotcheck, activity, workouts, cycle, journal, journey, recap, insights, timeline, records, coach, import, pairing, onboarding, profile |
| `lib/gps/` | GPS workout-route tracking (on-device only) |
| `lib/ai/`, `lib/coach/` | the BYOK AI briefings/journal assistant and the deterministic coaching engine |
| `lib/widget/`, `lib/live/` | the home-screen widget and the iOS Live Activity bridges |
| `ios/OpenStrapWidget/` | the actual widget and Dynamic Island Live Activity (needs an App Group you configure for your Apple team) |

Note: the actual protocol decode (`openstrap_protocol`) and analytics
(`openstrap_analytics`) code do **not** live in this repo at all — they're separate git
dependencies. If you're looking for record byte layouts or metric formulas, they're in
those repos, not here.

## Running it

```bash
cp .env.example .env
flutter pub get
flutter run --dart-define-from-file=.env
```

`.env.example` documents two optional build-time defines: `BACKEND_URL` (only used for
the one-time legacy-account import at onboarding — leave it blank if you don't have an
old account to import) and `COMPANION_URL` (only used for the OTA/announcement pointer
and the BYOK LLM proxy — also optional). The app works fully without either.

Quit the official WHOOP app before you connect — Bluetooth only lets one app own the band
at a time.

On iOS, the widget and Live Activity need signing configured for your Apple team and a
matching App Group. See `guides/IOS_INSTALLATION.md`; the repo ships with placeholder
bundle IDs and App Group values plus a gitignored local signing override, so it is not
tied to one developer account. Use Profile or Release builds for normal iPhone
home-screen relaunch testing; Flutter Debug builds must be launched through Flutter
tooling or Xcode.

## Your data

Everything is computed and stored on your phone. There's no cloud sync for the running
app — the only network calls it ever makes are the three narrow, opt-in things listed
under `lib/cloud/` above, none of which are required for the app to work. If you're a
returning user with an old cloud account, `BACKEND_URL` lets you pull that history down
once at onboarding; it's not an ongoing dependency after that.

## The stack, briefly

`openstrap_protocol` and `openstrap_analytics` (the two sibling packages this app is glue
around) plus `openstrap_icons`, `flutter_blue_plus` for Bluetooth, `sqflite` for the
local store, `provider` and `shared_preferences` for the plumbing, `http` for the narrow
network surface above, `fl_chart` / `google_fonts` / `hugeicons` / `share_plus` for the
look of it.

# Please raise Fixes, Lets make it better together
