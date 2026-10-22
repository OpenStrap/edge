# Privacy Policy — Edge / OpenStrap

_Last updated: October 11, 2026_

Edge ("the App") is an independent, open-source project. It is not affiliated
with, sponsored by, or endorsed by WHOOP, Inc.

**How the App is distributed**
There is currently one distribution channel: GitHub Releases. There is no App
Store or Play Store build of the App today, and nothing in this policy depends
on which channel you installed from. If that changes, this policy changes with
it.

**We do not collect your health data**
Your health information is processed and stored entirely on your device. We do
not upload it, we do not operate a backend that receives it, and we never see
it — *unless you explicitly switch on health data contribution, or separately
enable AI Coach or Health app integration, described below, which send specific
data to services you configure, or attach your database to an issue report.*

Health data contribution is **off by default**, and it is off unless you turn
it on yourself in Settings › Privacy › "Contribute my health data". When it is
on, and only then, the App uploads a compressed copy of its **entire local
database** — every derived day and every raw sensor row from the band — at most
once a day, and only while you are on Wi-Fi and charging. It is used to improve
the App's algorithms. Our server keeps only the most recent copy per device.

You can switch it off at any time from the same row, and nothing further is
uploaded from that moment. The App will then tell you the date of the last
upload that did happen, because switching a thing off does not un-send what was
already sent.

Edge is open source, and this feature sits behind a compile-time flag
(`kHealthDataContributionEnabled`, see `lib/telemetry/health_uploader.dart`).
An independent developer can enable it in their *own*, separately-built copy
pointed at a backend of their own choosing. That is their software and their
responsibility; it is not covered by this policy.

**Anonymous diagnostics**
Aside from the optional, user-initiated things described here, the App sends
basic crash/error and performance monitoring off your device, via Firebase
(Google) — Crashlytics, Performance Monitoring, and Analytics. This is **off by
default**: nothing is collected until you turn it on in Settings › Privacy ›
"Crash reports", and turning it back off stops any further collection
immediately. It never includes your health data — only crash reports, basic
device info (OS/model/app version), your phone's and band's battery level,
whether the band is connected, and coarse performance timing. It does not
include the band's serial number or any other hardware identifier. This data is
handled under Firebase's own privacy and security practices, not a system we
built or operate ourselves — see Google's Firebase privacy & security
documentation: https://firebase.google.com/support/privacy.

**Issue reports**
Settings › Privacy › "Report an issue" lets you send us a problem report. Nothing
is sent until you tap Create ticket, and the screen lists every file in the report
before you do. A report holds your title and description, the app and phone
details (app version, phone model, system version, language, time zone and a
random install ID), your paired band and sensors with their battery and last
sync, the app's recent sync log and error records, and a screenshot if you add
one. It contains no health data unless you switch on "Include the last 2 weeks
of health data" or the screenshot you add shows some. That option is off every time and attaches a copy of your database
cut down to the last 14 days of health data (your sleep, heart rate and other
health data), plus your daily scores and settings. If that would make the
report too big to upload (the limit is 95 MB), the second-by-second data
covers fewer days (7, 3 or 1) and everything else keeps 14. A separate switch, "Full
health database (share locally only)", also off every time, puts your whole
database in the report instead; it turns Create ticket off, so the full
database is never uploaded and only goes where you send it with "Share
locally".

The report is encrypted on your phone before it leaves, with a key only the
maintainers hold, so the service that stores it cannot read it. It is stored
on Cloudflare. A report is deleted after 30 days, or after 14 days if it
includes health data. The report's ID, your install ID, category, title, description, app version,
platform, system version, phone model, and whether a database or screenshot is
attached (and how many days of second-by-second data the database covers) are kept unencrypted so we can track it, and that record is deleted
after 90 days. You can delete a report sooner at any time from "My reports" on the same
screen. "Share locally" hands the report to your phone's share sheet and uploads nothing; that ZIP is not encrypted.

**Update checks**
Because the App is distributed outside an app store, it can check our release
server for a newer version and for any urgent notice we need to show you. That
check is a plain request for a small file: it carries no health data, no
account and no identifier, but like any network request it discloses your IP
address (and therefore your approximate location) and the time you opened the
App. It runs when the App starts and when you bring it back to the foreground.

You can turn it off in Settings › Privacy › "Check for updates", and then the
App makes no network request of its own accord at all. It is on by default
because a sideloaded app has no store to tell you a security fix exists.

**Barcode lookup for food logging**
The food log can read a barcode with the camera and fill in the nutrition
figures for you. Doing that means asking a database, so it is **on by
default**: what leaves is a number the manufacturer printed on the packet, and
nothing about you goes with it. Turn it off and the scan stops asking anybody
anything.

- **What is sent is the barcode.** It goes to openfoodfacts.org, the free and
  open food database. Nothing about you, your meals, your health or your device
  goes with it. Like any network request it discloses your IP address to them.
- **Only when you scan.** There is no background lookup, no batch and no
  pre-fetch. One barcode, one request, and only because you pointed the camera
  at a packet.
- **A barcode you have scanned before is answered from your own phone.** The
  App keeps a local copy of what it has fetched, so re-scanning the same packet
  asks nobody anything.
- **The camera reads digits and nothing else.** No photo is taken, stored or
  sent. Declining camera access leaves the rest of the food log working.
- **Everything still works with it off.** Typing the numbers off the pack was
  always the way in and still is.

You can turn it off at any time in Settings › Privacy › "Look barcodes up
online", and the App then makes no food-related network request at all.

Their data is contributed by the public, is licensed under the Open Database
License, and their own terms say it must not be used for medical purposes. So a
scanned figure is treated as something you typed rather than something the App
measured: anything that fails a basic plausibility check is left blank instead
of filled in, and every filled box is yours to edit before you save.

**Location and workout routes**
If you record a run, ride or walk, the App uses your device's location to draw
that workout's route. This is the most sensitive permission the App asks for,
so to be specific about it:

- **Only during a workout.** Location is read only while a run, ride or walk is
  actively recording. It stops the moment you finish. The App never reads your
  location in the background at any other time.
- **We never ask for "always" access.** The App requests *while-in-use*
  location only. Recording does continue while your screen is locked or you
  switch apps — otherwise a workout would stop being recorded the moment you
  put your phone in your pocket — but that is scoped to the active workout, not
  a standing permission to follow you.
- **It is visible while it happens.** On iOS the system's blue location
  indicator is shown for the whole time the App is reading location in the
  background. On Android the workout runs as a foreground service with a
  visible, persistent notification.
- **The App never sends your routes anywhere.** A route is written to a local
  database table on your phone and nowhere else. We do not upload it, it is not
  included in anonymous diagnostics, and it is not sent to your AI Coach
  provider — the coach is technically prevented from reading route data, not
  merely asked not to.
- **No map tiles are fetched.** A route is drawn on your phone from your own
  points, against no basemap. The App does not contact a tile provider, so
  opening a route tells nobody which part of the world you are looking at.
- **The one exception is you.** If you tap Share on a workout, the image you
  are shown includes a picture of your route, and whatever you send it to
  receives it. That is your choice, you see the image before it is sent, and it
  goes wherever you send it — not to us.
- **You can delete it.** Deleting a workout deletes its route with it, and
  uninstalling the App removes all of it immediately.

You can decline or revoke location access at any time in your device settings.
The App still records the workout — heart rate, duration, strain and the rest —
it simply has no map for it.

**Optional, user-initiated integrations**
If you choose to enable them, the App can also send data to services *you*
configure:
- **AI Coach** — if you enable this feature and supply your own API key,
  summaries of your data are sent to the AI provider you configure (by
  default, OpenAI) to generate coaching responses. Off by default and
  requires your own API key, or signing in with ChatGPT, in which case the
  same data goes to OpenAI under your ChatGPT account. The sign-in tokens are
  kept in the device keychain/keystore and sent only to OpenAI.
- **Health app integration** — if you enable it, the App can write derived
  daily metrics to Apple Health or Google Health Connect, which are controlled
  by your device's own OS-level health app, not by us. The App can also *read*
  from that same health app when you tap an import — your height, weight, date
  of birth and sex, your resting heart rate, blood pressure, blood glucose and
  body temperature readings, and your workouts and their routes. Every import
  is something you start by hand, never a background sync, and what it reads
  stays on your device: reading from your health app sends nothing anywhere.

**What we don't do**
We do not sell your data. We do not send your health data to WHOOP, Inc. or
any advertising network. We do not require a WHOOP account or credentials to
use the App. We do not operate a backend that stores your health data, except an issue
report you choose to send with your database attached (see Issue reports).

**Your controls**
Every one of these is a row in Settings › Privacy, and each takes effect the
moment you tap it:
- **Crash reports** — off by default; turning it off stops any further
  collection immediately.
- **Contribute my health data** — off by default; turning it off stops any
  further upload immediately, and the App tells you when the last one was.
- **Check for updates** — turning it off stops the App making any network
  request of its own accord.
- **Look barcodes up online** — on by default; turning it off stops any
  further lookup immediately, and the food log keeps working by hand.

You can also disable AI Coach or Health app integration at any time in Settings
if you'd previously turned them on.

**Getting your data out, and deleting it**
Settings › Your data exports everything the App holds: your derived days,
workouts, sleep, journal, lab results, meals, medication, habits, breathing
sessions and logged sets as spreadsheets, and the complete database as a single
file. The same screen can take a scheduled local copy, and restore one.

Settings › "Reset all data" deletes everything on the device: every table in
the database, every preference, any AI key you stored, the home-screen widget's
copy of your numbers, and every scheduled reminder. The dialog lists what it
covers. It is not reversible and the band cannot re-send history it has already
handed over, so export first if you want a copy.

Uninstalling the App deletes all of your locally stored data immediately.
That's the whole picture *unless* you had separately enabled one of the
optional integrations above — in that case, uninstalling stops the App from
sending anything further, but does not reach back and delete data already
sent:
- Anonymous diagnostics already sent to Firebase are retained and governed by
  Firebase's own practices (linked above), not by us.
- Data already sent to your configured AI Coach provider (e.g. OpenAI) is
  retained and governed by that provider's own policies, not by us.
- Metrics already written to Apple Health or Google Health Connect are
  retained and governed by that platform's own data controls, not by us —
  manage or delete them from that app directly.

**Children**
This App is not directed to children under 13 (or the relevant age of digital
consent in your jurisdiction) and we do not knowingly collect data from them.

**Changes**
We may update this policy; material changes will be reflected here with an
updated date.

**Contact**
Questions about this policy: abdulsaheel81@gmail.com.
