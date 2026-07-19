# Tasker integration — buzz your strap

OpenStrap Edge can vibrate your WHOOP strap in response to a Broadcast intent
from Tasker (or any automation app). Use it to buzz the strap for phone calls,
timers, geofences — anything Tasker can react to.

Android only. The app must be paired with your strap, and the strap must be in
BLE range for the buzz to fire (if the app was killed, the buzz is queued and
delivered once it reconnects).

## What you need from the app

Open **Settings → Automation** in OpenStrap Edge. You'll find:

- The broadcast action: `wtf.openstrap.openstrap_edge.BUZZ_STRAP`
  (long-press the row to copy it)
- Your **automation token** — a per-install secret (long-press to copy).
  Broadcasts without a matching token are silently ignored, so nothing else
  on your phone can buzz your strap.

## Setting up the Tasker action

Create a Task and add an action: **System → Send Intent**. Fill it in like
this:

| Field | Value |
|---|---|
| Action | `wtf.openstrap.openstrap_edge.BUZZ_STRAP` |
| Package | `wtf.openstrap.openstrap_edge` |
| Extra | `token:YOUR_AUTOMATION_TOKEN` |
| Target | **Broadcast Receiver** |

Common mistakes, since Tasker's form makes them easy:

1. **Action goes in the Action field** at the top — not in Package, and not
   in an Extra.
2. **Package is just the app package** (`wtf.openstrap.openstrap_edge`), not
   the full action string. It must be set: the app rejects broadcasts that
   aren't explicitly targeted at it.
3. **Extras use `key:value` format.** The token extra must literally read
   `token:YOUR_AUTOMATION_TOKEN` (with your token pasted after the colon).
   If the `token:` key is missing, the app never sees a token and refuses
   to buzz.
4. **Target must be Broadcast Receiver** — scroll down past Package to find
   it. Activity or Service won't reach the app.

Wire the Task to whatever Profile you like (event, time, state) and it
should buzz.

## Choosing a vibration pattern

Optionally add a second Extra to pick a different haptic pattern:

```text
pattern:1
```

It's an int; the default is `2` (a quick double buzz) when the extra is
omitted. `pattern:1` buzzes until acked by tapping the strap, which makes it
ideal for phone-call notifications. See [BUZZ_MEANINGS.md](BUZZ_MEANINGS.md)
for the full list.

## Troubleshooting

- Rapid repeat broadcasts are rate-limited (about 1.5 s between accepted
  buzzes) — a tight Tasker loop won't buzz on every iteration.
- If nothing happens, check `TaskerReceiver` lines in logcat: it logs why a
  broadcast was rejected (wrong target, missing/incorrect token, or
  rate-limited).
