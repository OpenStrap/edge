// PairedDevice — the LOCAL record of the band the user paired.
//
// LOCAL ONLY — there is no server. This survived the cloud excision (it used to
// live alongside BackendConfig/Session in sync/config.dart, both deleted).
//
// IT IS A TABLE NOW, not two SharedPreferences scalars. Prefs could hold
// exactly one band, carried no state beside the id, and could not be joined to
// anything — while `decoded_onehz` / `decoded_rr` / `samples` have been keyed
// by `device_id` since schema 47 with nothing on the other end of that key.
// The `device` table (schema 49) is that other end, and it can hold N rows.
//
// THE PREFS PAIR IS KEPT AS A MIRROR OF THE PRIMARY BAND, deliberately:
//  * The table lives in a database that can be quarantined and rebuilt
//    (`_openOrRebuild`) and that "Delete everything" empties. Losing a band's
//    identity to either of those means the user has to re-pair for no reason
//    they can see.
//  * `load()` is the FIRST line of app start-up, so the fallback is also the
//    thing that heals it: a table with no primary row and a mirror that has one
//    puts the row back.
// The table WINS whenever it has the row, so there is no ambiguity about which
// is authoritative — the mirror only ever answers when the table is silent.
//
// ponytail: the mirror carries the PRIMARY only. A second device lives in the
// table alone and does not survive a rebuild; give it its own mirror the day
// one can actually be paired, or stop rebuilding databases.

import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';

/// The `SourceTier` a wrist band sits on (the enum name in
/// `ui2/profile/devices.dart` — measurement quality, which is the only thing
/// that decides precedence between two sources).
const String kBandSourceTier = 'wristOptical';

/// The band the user paired. Persisted so we auto-reconnect on every launch.
class PairedDevice {
  static const String _kRemoteId = 'paired_remote_id';
  static const String _kSerial = 'paired_serial';
  static const String _kGeneration = 'paired_generation';

  /// `[remoteId, wearing, wearing_set_ts]` of a forgotten band's explicit
  /// wearing choice, or a restored one (remoteId `''`, any band). NOT cleared
  /// by [clear]: forget-and-re-pair the same band (the usual BLE fix) must not
  /// silently reset it to the wrist DEFAULT.
  static const String _kWornOn = LocalDb.kPendingWornOnPref;

  final String remoteId; // BLE remote id (iOS: per-install UUID; Android: MAC)
  final String? serial;

  /// 'gen4' / 'gen5', pinned by service discovery on a previous connection, or
  /// null before any link has identified itself. A known-device reconnect
  /// skips scanning, so this is the only way the connect path can know the
  /// generation BEFORE discovery — which the gen5 bootstrap needs, because its
  /// PHY preference and bond position differ from gen4's proven flow.
  final String? generation;

  PairedDevice(this.remoteId, this.serial, {this.generation});

  /// The only two values [generation] may hold. `adapter_id` is the whole
  /// registry's id space — a notify-only `ble_hrs` / `oura` row names no
  /// framed generation — and this value ROUTES the connect order, so anything
  /// else reads as unknown rather than steering the bootstrap.
  static String? _cleanGeneration(String? g) =>
      (g == 'gen4' || g == 'gen5') ? g : null;

  /// Bumped by [clear]. FORGET WINS OVER AN IN-FLIGHT SAVE.
  ///
  /// The heal call sites are `unawaited(PairedDevice.save(...))` — engine-state
  /// pins the serial and the discovered generation fire-and-forget — so one can
  /// still be between its awaits when the user's forget lands. Without this,
  /// that save recreates both copies after `clear()` deleted them and the band
  /// the user just forgot is paired again on the next launch.
  ///
  /// A counter, not a lock: [save] samples it on entry and refuses to write if
  /// it moved, which is decidable because a Dart isolate interleaves only at
  /// awaits. It does NOT span isolates — the headless sync isolate has its own
  /// copy — and it does not need to: nothing there can unpair.
  ///
  /// It is now the INNER of two guards: [_serialized] means a save and a clear
  /// never overlap at all, so this only ever fires for a save that was already
  /// queued when the forget arrived.
  static int _forgetEpoch = 0;

  /// ONE AT A TIME. Every one of these three touches the same two copies across
  /// several awaits, and guarding the WINDOWS between those awaits does not
  /// work: every guard that refuses a stale write is also a guard that can
  /// delete a NEWER pairing's keys, because "the epoch moved" says a forget
  /// happened, not that the mirror is still this save's to clean up. Running
  /// them in call order removes the interleaving instead of trying to detect
  /// it — old save → clear → new save, each complete before the next starts.
  ///
  /// [load] IS ONE OF THE THREE. It reads like an accessor and is not: with no
  /// table row it heals one back FROM the mirror, which is a write. Left
  /// outside, a load that had already read the mirror could let a `clear()`
  /// take its one database delete and then upsert the forgotten band back
  /// afterwards — into the copy that WINS on the next launch. The heal is the
  /// whole point of the mirror, so it cannot be dropped; it just has to happen
  /// where a forget cannot land inside it.
  ///
  /// ponytail: an in-isolate queue, so it orders THIS isolate only — the same
  /// scope [_forgetEpoch] already had, and the headless sync isolate cannot
  /// unpair. A cross-isolate lock would need the database, and nothing has ever
  /// needed one.
  static Future<void> _queue = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() op) {
    final next = _queue.then((_) => op());
    // Keep the chain alive when an op throws: the queue must order the ones
    // behind it either way, and every caller still sees its own error.
    _queue = next.then((_) {}).catchError((_) {});
    return next;
  }

  static Future<PairedDevice?> load() => _serialized(_load);

  static Future<PairedDevice?> _load() async {
    final row = await LocalDb.deviceRow();
    final id = row?['remote_id'] as String?;
    if (id != null && id.isNotEmpty) {
      // Sanitize on read: drop any garbled value (e.g. "?*" junk persisted by
      // an older build's HELLO content-scan) so it can never reach the UI.
      return PairedDevice(
        id,
        cleanDeviceLabel(row?['label'] as String?),
        generation: _cleanGeneration(row?['adapter_id'] as String?),
      );
    }
    // No row: either this install predates the table, or the database was
    // rebuilt/wiped under a band that is still paired. Same repair either way —
    // the prefs mirror is the only other copy, and putting it back IS the
    // migration. A user mid-upgrade never re-pairs.
    final prefs = await SharedPreferences.getInstance();
    final mirrored = prefs.getString(_kRemoteId);
    if (mirrored == null || mirrored.isEmpty) return null;
    final serial = cleanDeviceLabel(prefs.getString(_kSerial));
    final generation = _cleanGeneration(prefs.getString(_kGeneration));
    await LocalDb.upsertDevice(
      adapterId: generation,
      remoteId: mirrored,
      label: serial,
      tier: kBandSourceTier,
    );
    return PairedDevice(mirrored, serial, generation: generation);
  }

  /// Persist the primary band. [generation] is the registry's `BandEntry.id`
  /// for a framed band (`gen4` / `gen5`) — the same value the `device` table
  /// stores as `adapter_id`, which is why it is passed straight through.
  /// Omitted, it leaves whatever the row already knows rather than blanking it
  /// (`upsertDevice` COALESCEs), and a row that has never been told keeps
  /// NULL, which every per-family metric reads as a refusal instead of
  /// assuming gen4.
  static Future<void> save(
    String remoteId,
    String? serial, {
    String? generation,
  }) =>
      _serialized(() => _save(remoteId, serial, generation: generation));

  static Future<void> _save(
    String remoteId,
    String? serial, {
    String? generation,
  }) async {
    final epoch = _forgetEpoch;
    final clean = cleanDeviceLabel(serial);
    final gen = _cleanGeneration(generation);
    final prefs = await SharedPreferences.getInstance();
    // A stored generation belongs to a DEVICE. Keep it only when this save is
    // for the same remoteId and merely doesn't know the generation (most save
    // sites only carry the serial); pairing a DIFFERENT band must never
    // inherit the old band's generation — that would route its first connect
    // by the wrong device's identity.
    //
    // Asked of the TABLE first, because that is the copy `load()` answers
    // from. Both copies are then written the same way, so the mirror cannot
    // heal a stale generation back over a corrected one.
    final row = await LocalDb.deviceRow();
    final knownRemoteId =
        (row?['remote_id'] as String?) ?? prefs.getString(_kRemoteId);
    final sameDevice = knownRemoteId == remoteId;
    // A forget that landed while the reads above were in flight wins: this
    // save is describing a band the user has just told us to drop.
    if (epoch != _forgetEpoch) return;
    await LocalDb.upsertDevice(
      adapterId: gen,
      remoteId: remoteId,
      label: clean,
      tier: kBandSourceTier,
      // `adapter_id` COALESCEs like every other column, and the primary row is
      // reused for whatever band is primary — so a new band needs it said out
      // loud that the old family no longer applies.
      clearAdapterId: !sameDevice,
    );
    // Re-checked between the two copies as well: `clear()` empties the table
    // and the mirror in that order, so a forget landing inside this window
    // would otherwise leave the mirror pointing at a band the table no longer
    // has — and `load()` heals FROM the mirror.
    if (epoch != _forgetEpoch) return;
    final worn = prefs.getStringList(_kWornOn);
    if (worn != null &&
        worn.length == 3 &&
        (worn[0] == remoteId || worn[0].isEmpty)) {
      final w = int.tryParse(worn[1]);
      final ts = int.tryParse(worn[2]);
      if (w != null && ts != null) await LocalDb.adoptDeviceWearing(w, ts);
      await prefs.remove(_kWornOn);
    }
    await prefs.setString(_kRemoteId, remoteId);
    if (clean != null) {
      await prefs.setString(_kSerial, clean);
    } else {
      await prefs.remove(_kSerial); // never persist junk
    }
    if (gen != null) {
      await prefs.setString(_kGeneration, gen);
    } else if (!sameDevice) {
      await prefs.remove(_kGeneration);
    }
  }

  /// Forget the primary band. BOTH copies, or the mirror puts it straight back
  /// on the next launch — and the measurements it wrote are untouched, which is
  /// what the forget dialog promises.
  static Future<void> clear() => _serialized(_clear);

  static Future<void> _clear() async {
    // Bumped inside the queued op, so a save queued BEHIND this clear does not
    // see the bump and writes normally — which is what "the user re-paired"
    // means. Only a save already running ahead of it is refused.
    _forgetEpoch++;
    final row = await LocalDb.deviceRow();
    await LocalDb.deleteDevice();
    final prefs = await SharedPreferences.getInstance();
    final rid = row?['remote_id'] as String?;
    final w = row?['wearing'];
    final ts = row?['wearing_set_ts'];
    if (rid != null && w is num && ts is num) {
      await prefs.setStringList(
        _kWornOn,
        [rid, '${w.toInt()}', '${ts.toInt()}'],
      );
    }
    await prefs.remove(_kRemoteId);
    await prefs.remove(_kSerial);
    await prefs.remove(_kGeneration);
  }
}

// Compiled once — cleanDeviceLabel is called from the ~1 Hz engine-state
// pipeline, and RegExp construction per call was pure per-tick waste.
final RegExp _labelSafeCharset = RegExp(r"^[A-Za-z0-9 '._-]+$");
final RegExp _labelHasAlnum = RegExp(r'[A-Za-z0-9]');

/// A WHOOP serial ("4C2248092") or a user-set strap name ("Abdul's WHOOP") is
/// made of letters, digits, spaces and a little ordinary punctuation. Anything
/// containing other characters (the "?*"-style junk a bad HELLO parse produced)
/// is rejected → null. Gates what we persist and display as the device label.
String? cleanDeviceLabel(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  if (!_labelSafeCharset.hasMatch(t)) return null; // safe charset
  if (!_labelHasAlnum.hasMatch(t)) return null; // needs ≥1 alnum
  return t;
}
