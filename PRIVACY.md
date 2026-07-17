> **ATTORNEY-REVIEW DRAFT — not final.** This has not been reviewed or approved
> by a licensed attorney and must not be treated as the live policy until it
> has been. `[DATE]`, `[CONTACT EMAIL]`, and the data-deletion mechanism below
> are placeholders a human must fill in before this goes live. Both the App
> Store and Play Store require a **hosted** URL for the privacy policy (not a
> link to this repo file) — this still needs a GitHub Pages page (or a page on
> whatever domain backs `wtf.openstrap.*`) before store submission. See
> `lib/ui/profile/about_screen.dart`'s `kPrivacyPolicyUrl` TODO for the
> in-app link that needs updating once that page exists.

# Privacy Policy — Edge / OpenStrap

_Last updated: [DATE]_

Edge ("the App") is an independent, open-source project. It is not affiliated
with, sponsored by, or endorsed by WHOOP, Inc.

**Data we collect**
- Biometric/health data from your paired WHOOP 4.0 band over Bluetooth: heart
  rate, heart rate variability (RR intervals), motion (accelerometer), raw
  skin-temperature/blood-oxygen sensor channels, and (if you record workouts)
  GPS location during those workouts.
- Basic app usage/crash telemetry, only if you opt in.

**Where your data lives**
By default, all of the above is stored locally on your device only. We do not
upload it anywhere unless you explicitly opt in to one of the following:
- **Cloud backup** — a one-time or periodic encrypted upload of your local
  database to our own backend, only if you turn this on in Settings.
- **AI Coach** — if you enable this feature and supply your own API key,
  summaries of your data are sent to the AI provider you configure (by
  default, OpenAI) to generate coaching responses. This is off by default and
  requires your own API key.
- **Health app integration** — if you enable it, the App can write derived
  daily metrics to Apple Health or Google Health Connect, which are controlled
  by your device's own OS-level health app, not by us.

**What we don't do**
We do not sell your data. We do not send your health data to WHOOP, Inc. or
any advertising network. We do not require a WHOOP account or credentials to
use the App.

**Your controls**
You can disable cloud backup, telemetry, or AI Coach at any time in Settings.
[Describe how a user deletes their local data / requests deletion of any
uploaded backup — INSERT MECHANISM].

**Children**
This App is not directed to children under 13 (or the relevant age of digital
consent in your jurisdiction) and we do not knowingly collect data from them.

**Changes**
We may update this policy; material changes will be reflected here with an
updated date.

**Contact**
Questions about this policy: [CONTACT EMAIL].
