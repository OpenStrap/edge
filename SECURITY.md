# Security Policy

## Reporting a vulnerability

Please **don't** open a public issue for a security problem.

Use GitHub's private reporting instead:
[**Report a vulnerability →**](https://github.com/OpenStrap/edge/security/advisories/new)

That goes straight to the maintainer and stays private until there's a fix.

Rough expectations, set honestly — this is a one-maintainer project, not a
company with an on-call rota:

- Acknowledgement within about a week.
- An assessment, and a fix or a clear "won't fix and here's why", within 30 days
  for anything that puts user data at risk.
- Credit in the release notes if you want it.

## What's in scope

- Anything that discloses a user's health data off their device.
- Anything that lets a third party read, write to, or hijack the Bluetooth
  session with someone's band.
- Local data-at-rest problems: the database, exports, the App Group container,
  widget snapshots.
- The optional companion worker in
  [backend](https://github.com/OpenStrap/backend): auth, the import endpoints,
  the opt-in telemetry and health-upload paths.
- Anything that causes the app to send data anywhere the user did not agree to.

## What's out of scope

- The band's own firmware. We don't ship it, can't patch it, and won't publish
  attacks against it.
- WHOOP's own apps and services. Please report those to WHOOP.
- The fact that sideloaded builds are unsigned, or that a rooted/jailbroken
  device can read app storage. Both are known properties of the distribution
  model, documented in the README.
- Metric accuracy. Wrong numbers are bugs — open a normal issue.

## Where your data actually is

Worth knowing before you go looking: OpenStrap computes and stores your health
data on-device, and there's no account or server holding it. Two qualifications,
so the boundary is exact:

- **Anonymous diagnostics** (Firebase crash/performance, never health data) are
  **off by default in every build** — nothing is collected until you turn it on
  in-app, and switching it back off stops collection immediately.
- **Health-data contribution** uploads the local database, but is opt-in, off by
  default, and compiled out of store builds entirely.

Everything else the companion worker does — legacy import, an update pointer —
is optional and carries no health data. See [PRIVACY.md](PRIVACY.md).

That means the realistic attack surface is the phone, the Bluetooth link, and
the local database — not a cloud backend. Reports focused there are the most
useful.
