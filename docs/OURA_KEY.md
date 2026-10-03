# Pairing an Oura ring with the key it already has

OpenStrap can pair a ring **without a factory reset**, by proving the key the ring already
holds instead of installing one of its own. The Oura app keeps working — nothing is written
to the ring on this path, only an authentication round trip.

The catch is that you have to supply that key, and it lives in the Oura app's own database
on your own phone. This is how to get it out.

> **Credit.** The database location and the `ringconfiguration` schema come from
> [ringverse](https://github.com/ringverse)'s `oura/storage.md`, and this recipe follows the
> one documented in [NOOP](https://github.com/ryanbr/noop). Nothing here touches, decompiles
> or redistributes any Oura app code — it reads a value out of your own device backup, using
> Apple's own backup mechanism, with a publicly documented schema.

---

## Before you start

**You need a Mac and your own iPhone.** The recipe reads an unencrypted local backup. There
is no jailbreak and no decryption bypass involved.

**If you want SpO2, exercise HR or real steps, enable them in the Oura app first, while a
paid membership is active on the account.** Those streams are gated by the account-side
configuration the ring inherits, not by the app you connect with, so OpenStrap cannot turn
them on. A one-month membership is enough to flip them: subscribe, enable the features,
then the ring carries that entitlement.

What happens after a membership lapses is **untested** — we do not know whether the ring
keeps the unlocked state, re-checks with a server periodically, or reverts. Treat the unlock
as good for the period you actually tested, not as permanent.

**And a caveat specific to OpenStrap, so you are not disappointed:** a paired ring today
*captures and banks* data, and OpenStrap derives **no metrics at all** from it —
`OuraAdapter.signals` is empty and the ring is not in `kDerivableSources`. So the
entitlement above decides what the ring will emit; it does not yet decide what any screen
shows. Pairing is the groundwork, not a finished feature.

---

## Getting the key

1. **Pair the ring with the genuine Oura app** and enable whatever features you want (see
   above). These are account settings.

2. **Start a local, unencrypted backup** of the iPhone on your Mac: Finder → the device →
   *Back Up Now*, with *Encrypt local backup* **off**.

3. **Open the backup with a backup explorer** (for example
   [iBackup Viewer](https://www.imactools.com/iphonebackupviewer/)) and find the Oura app's
   container: search for `AppDomain-com.ouraring.oura`, then under it
   `<UUID>/assa.sqlite` — the UUID is uppercase.

4. **Extract `assa.sqlite`** and open it in any SQLite browser.

5. **Read the keys:**

   ```sql
   SELECT id, auth_key FROM ringconfiguration;
   ```

   `auth_key` comes back Base64-encoded.

6. **Paste it straight into OpenStrap — do not decode it.** The pairing screen accepts the
   Base64 form as it comes out of that query (24 characters, usually ending `==`), as well
   as 32 hex digits. NOOP's version of this recipe has you decode to raw bytes first; here
   that step is unnecessary.

   In the app: *Profile → the ring's pairing screen → **"Already set up elsewhere?"*** —
   paste into that field and pair.

### Several rings on the account

If that query returns more than one row, **you do not have to work out which key belongs to
which ring.** Paste them all, one per line, up to five. OpenStrap tries each in turn against
the ring, on its own connection, and keeps the first one the ring accepts; the rest are
discarded and never stored. Commas and semicolons work as separators too.

Each candidate costs a connect and a handshake, so a five-key field takes a little while —
that is the trial running, not a hang.

---

## What OpenStrap does with the key

- **Stored locally only**, in the platform keychain/keystore via `flutter_secure_storage`,
  the same way a key OpenStrap generated itself is stored. There is no vendor server
  anywhere in this handshake and no account is needed.
- **Never transmitted**, and never written into a log. The pairing logs print key *lengths*
  and result codes only — never the key, the nonce, or the AES answer.
- **Dropped if pairing fails.** A key with no device row behind it is deleted rather than
  left as an orphaned secret.
- **Nothing is written to the ring.** The key-install command is never sent on this path, so
  a wrong key costs a refusal and nothing more.

**Treat this key like a password.** It authenticates as the real Oura app against your
account's ring.

---

## If it does not work

**"Timed out after 20s" / the connect never answers.**
The ring is almost certainly not advertising, which happens when it has no Bluetooth bond
with the phone. CoreBluetooth's connect has *no timeout* — it waits for the device to
appear, indefinitely — so this presents as a timeout that names nothing. Check
*Settings → Bluetooth*: if the ring is not listed, re-pair it in the Oura app first, then
try again.

This is also what happens if the ring's bond was removed. On iOS, deprovisioning an
AccessorySetupKit accessory removes it from the system **for every app**, bond included, and
only re-pairing with the vendor app puts it back.

**"The ring refused that key."**
The ring answered and said no: that key is not this ring's. If the query returned several,
paste the others too — see above.

**"The ring stopped answering part-way through pairing."**
On a current build this means what it says. On a build older than the notification-ordering
fix it was usually *our* bug, not the ring: the pairing command was sent before the
notification subscription was live, so the ring's reply was dropped and the app blamed the
ring. Update first.

**The key looks right but is always refused.**
Check for `-` or `_` in it. That is Base64**url**, not standard Base64, and OpenStrap's
parser strips `-` as a grouping separator — convert `-`→`+` and `_`→`/` before pasting, or
use the hex form instead.
