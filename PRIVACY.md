# Privacy Policy — Edge / OpenStrap

_Last updated: July 20, 2026_

Edge ("the App") is an independent, open-source project. It is not affiliated
with, sponsored by, or endorsed by WHOOP, Inc.

**We do not collect your health data**
This section describes the builds we ourselves distribute. In the official
public releases distributed through the App Store and Play Store, we do not
collect your health data. Your health information is processed and stored
entirely on your device in those releases. We do not upload it, we do not
operate a backend that receives it, and we never see it — *unless you
explicitly choose to install a GitHub release that has health data
contribution enabled, or separately enable AI Coach or Health app
integration, described below, which send specific data to services you
configure.*

Edge is open source. The underlying code contains a compile-time flag
(`kHealthDataContributionEnabled`, see `lib/telemetry/health_uploader.dart`)
that an independent developer could enable in their *own*, separately-built
and separately-distributed copy of the app, pointed at a backend of their
own choosing. We do not enable that feature in the official public builds we
publish. If you explicitly download and install a GitHub release, you may
choose to enable this feature for the purpose of improving algorithm and
calibration insights. That choice is entirely under your control, and the
feature is off by default. A self-built copy compiled with that flag on is
that builder's own software and their own responsibility; it is not covered
by this policy.

**Anonymous diagnostics**
In the official public releases distributed through the App Store and Play
Store, the App does not send your health data off your device. The only
thing the App sends off your device *automatically* — aside from the
optional, user-initiated integrations described next — is basic crash/error
and performance monitoring, via Firebase (Google) — Crashlytics, Performance
Monitoring, and Analytics. This is on by default in GitHub releases; you can
turn it off at any time in your profile, which stops any further collection
immediately. In App Store and Play Store releases, this data collection does
not occur. It never includes your health data — only crash reports, basic
device info (OS/model/app version), and coarse performance timing. This data
is handled under Firebase's own privacy and security practices, not a system
we built or operate ourselves — see Google's Firebase privacy & security
documentation: https://firebase.google.com/support/privacy.

**Optional, user-initiated integrations**
If you choose to enable them, the App can also send data to services *you*
configure:
- **AI Coach** — if you enable this feature and supply your own API key,
  summaries of your data are sent to the AI provider you configure (by
  default, OpenAI) to generate coaching responses. Off by default and
  requires your own API key.
- **Health app integration** — if you enable it, the App can write derived
  daily metrics to Apple Health or Google Health Connect, which are controlled
  by your device's own OS-level health app, not by us.

**What we don't do**
We do not sell your data. We do not send your health data to WHOOP, Inc. or
any advertising network. We do not require a WHOOP account or credentials to
use the App. We do not operate a backend that stores your health data.

**Your controls**
Turn off anonymous diagnostics at any time in your profile — this stops any
further collection immediately. You can also disable AI Coach or Health app
integration at any time in Settings if you'd previously turned them on. If
you explicitly installed a GitHub release and enabled health data
contribution, you can disable that feature at any time from the app's
settings.

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
