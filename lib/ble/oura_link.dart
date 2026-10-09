// The HOST for the Oura ring: hold the pairing key, hold the drain cursor,
// hold the time anchor, connect, drive [OuraAdapter] over the link, and bank
// what comes back.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6), so not one byte of this path has been exercised against one. The
// registry entry stays EXPERIMENTAL, `OuraAdapter.signals` stays `const {}`,
// and nothing this file writes becomes a number: its rows carry a non-null
// `source`, and every derive/export read filters `source IS NULL`. That is
// correct behaviour for an uncalibrated decoder, not a limitation to route
// around.
//
// THE SHAPE, AND WHY IT IS NOT `HrsLink`'s. A heart-rate strap is a live
// session armed by a workout; the ring is a FETCH-BY-CURSOR store. So this is
// a one-shot [OuraLink.sync] — connect, drain to the end of history, tear down
// — rather than an arm/disarm pair. Everything else is the same host work in
// the same order: read the `device` row, connect by `remote_id`, discover,
// check [GattBandLink.missingCharacteristics], drive `run()`, buffer, commit,
// disconnect.
//
// WHAT THIS FILE OWNS THAT THE ADAPTER DELIBERATELY CANNOT (see `oura.dart`'s
// own header):
//
//  1. THE 16-BYTE PAIRING KEY, in the platform keychain/keystore — never in
//     the database. See [_readKey].
//  2. THE DRAIN CURSOR, a decisecond on the ring's own clock, in `sync_cursor`
//     so a drain resumes instead of re-fetching.
//  3. THE TIME ANCHOR, the `(ring decisecond, Unix second)` pair, persisted
//     beside the cursor and handed back in at the next connect. This is the fix
//     for the cross-session origin hazard — see below.
//
// THE HOST HOLDS THE ORIGIN, THE ADAPTER STAMPS WITH IT. There is exactly one
// implementation of "which second is this decisecond", and it is
// `OuraAdapter._anchorUnixFor`. The host reads the stored `(ds, unix)` pair,
// hands it in at construction, and writes back the better one the adapter
// reports when a `time_sync` event gives it a measured pair — inside the same
// transaction as the rows that pair stamped. Two implementations of an origin
// would be two origins, which is the whole failure this mechanism exists to
// stop: the same physiological second written under two different `ts_ms`,
// which REPLACE cannot collapse because they no longer share a key.
//
// ABSTAINING IS THE CORRECT ANSWER WHEN THERE IS NO ORIGIN. A session with no
// measured `time_sync` and nothing stored writes NO timestamped row. The frames
// are still archived verbatim — the bytes are banked, and a plausible wrong
// `ts_ms` is worse than a missing one.
//
// THE DESTRUCTIVE COMMANDS ARE UNREACHABLE FROM HERE, and their absence is the
// only thing making that true. `GattBandLink`'s dangerous-opcode block reads an
// opcode out of a WHOOP envelope and answers null for an unframed band, so it
// does NOT cover this ring (ASSUMPTIONS I1). The ring has a factory reset, a
// DFU state machine, a flight mode, a manufacturing-mode setter and a
// bulk-sampler erase. This file writes NOTHING it did not get from a builder in
// the protocol package's Oura wire format, that module has no builder for any
// of them, and `oura_link_test.dart` asserts that every byte this host puts on
// the wire came from a builder that exists. The one command here that writes
// ring state is the key install, and it writes a credential rather than
// erasing anything.

import 'dart:async';
import 'dart:convert' show base64;
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/oura.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// Keychain item name for one ring's pairing key. Suffixed with the MINTED
/// device id, never the BLE remote id — that rotates.
String _keyItem(String deviceId) => 'oura_pairing_key:$deviceId';

/// `sync_cursor` names. Both are per-device: two rings are not a thing anyone
/// asked for, but a second one must not silently inherit the first's bookmark.
/// Why an Oura sync session ended the way it did — the minimal internal
/// result representation behind the unchanged `Future<bool> sync()`. Set
/// only from the adapter's OWN notes (never guessed from silence), cleared at
/// every session start, read by the UI to pick the honest sentence.
enum OuraSyncCategory {
  /// No session has run (or none of the below applied).
  none,

  /// The drain reached its honest end (`oura_drain_ok`).
  drained,

  /// The ring EXPLICITLY refused the key (its own refusal frame).
  authRefused,

  /// The link refused a command write (subscription/transport-level).
  writeRefused,

  /// Connected and authenticated, but a batch never ended inside the reply
  /// window — protocol timeout / incomplete answer.
  protocolTimeout,

  /// The durable commit or its confirm did not land — an OBSERVED
  /// persistence failure (the commit threw or was refused).
  storageFailed,

  /// The checkpoint was not confirmed — the commit's own outcome is not
  /// named by the note that sets this; only the confirm is known to have
  /// not completed. Kept apart from [storageFailed]: the remedy sentence
  /// must be honest about the uncertainty instead of claiming the data
  /// was never saved (or that it was).
  checkpointUnconfirmed,
}

String _cursorItem(String deviceId) => 'oura_cursor_ds:$deviceId';
String _anchorItem(String deviceId) => 'oura_anchor:$deviceId';

/// FIRST-UNLOCK, not the plugin's default WHEN-UNLOCKED — the same choice, for
/// the same reason, that `CoachConfig` documents at length. This app is
/// relaunched in the background constantly (BGProcessingTask, the BLE restore
/// central waking on a link drop) and those relaunches routinely happen while
/// the phone is LOCKED, i.e. exactly when a `whenUnlocked` item cannot be read.
/// A background sync that read nothing would conclude the ring is unpaired.
const IOSOptions _kApple = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
);
const MacOsOptions _kMacos = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock,
);

const FlutterSecureStorage _secure = FlutterSecureStorage();

/// THE ORDER IS THE WHOLE MESSAGE. A ring only accepts a new key while it is
/// factory reset, so the reset comes FIRST and pairing second — reversed, the
/// user resets a ring this app has just keyed and loses both.
const String _kResetFirst =
    'The ring would not take a new key. It only accepts one while it is '
    'factory reset, so reset it first and then pair here — that is the order, '
    'and resetting is what frees the ring from whatever set it up before. '
    'The ring has no reset button: open the Oura app and remove/unpair the '
    'ring there, then fully close that app before pairing here. If that app '
    'cannot reach the ring either, the charging dock can factory-reset it '
    'without any app — four flips, each waiting for its LED colour: with the '
    'ring seated, flip the dock upside-down and wait for blue, flip it back '
    'upright and wait for red, upside-down again for purple, and upright a '
    'final time for yellow — yellow means the reset has started, and a '
    'blinking blue LED a few minutes later means it is done.';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int>? _unhex(String s) {
  if (s.length.isOdd || s.isEmpty) return null;
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    final v = int.tryParse(s.substring(i, i + 2), radix: 16);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

/// Wait, briefly, for the Bluetooth adapter to report ON before a connect.
///
/// `flutter_blue_plus` creates its CBCentralManager lazily, on the first call
/// that needs one, and a new central reports `unknown` until CoreBluetooth has
/// started. A connect issued inside that window throws "bluetooth must be
/// turned on (CBManagerStateUnknown)" on a phone whose Bluetooth is on. Traced
/// on iOS 27: the ring's first connect straight after the ASK picker, the first
/// Bluetooth call this app made in the process. Bounded; returns false when the
/// adapter never reported ON, so pairing can say Bluetooth is off instead of a
/// generic connect failure.
Future<bool> _awaitAdapterOn() async {
  final s = await FlutterBluePlus.adapterState
      .firstWhere((s) => s == BluetoothAdapterState.on)
      .timeout(const Duration(seconds: 10),
          onTimeout: () => BluetoothAdapterState.unknown);
  return s == BluetoothAdapterState.on;
}

/// A 16-byte Oura pairing key typed or pasted by the user, or null when [raw]
/// is not one.
///
/// Two spellings, because those are the two a key actually turns up in: 32 hex
/// digits, and the base64 form a key is stored as in the vendor app's own
/// database (24 characters with its `==` padding). Whitespace, colons and
/// dashes are ignored so a key copied out of a hex dump still parses. Anything
/// that does not come out at exactly 16 bytes is refused rather than padded or
/// truncated — a wrong key costs nothing on the ring, but a silently mangled
/// one reads as "the ring refused my key" when the ring was never shown it.
List<int>? parseOuraKey(String raw) {
  final s = raw.replaceAll(RegExp(r'[\s:-]'), '');
  if (s.isEmpty) return null;
  if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(s)) return _unhex(s);
  try {
    final bytes = base64.decode(s);
    return bytes.length == 16 ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// The most candidate keys one pairing run will try.
///
/// A cap rather than "as many as you paste", because every candidate costs its
/// own connect + handshake against the ring (see [pairOuraRingWithKeys] for why
/// they cannot share a link): twenty pasted lines would be a pairing screen
/// that sits there for minutes. Five covers the case this exists for — a user
/// who pulled several keys out of a previous setup and does not know which ring
/// each belongs to.
const int kOuraMaxCandidateKeys = 5;

/// One parse of the pairing screen's key field.
///
/// It reports what it DROPPED as well as what it found, because the field is
/// free text and a silent drop is how a user retries the same typo twice. The
/// counts are surfaced in the exhausted-trial message, not just logged.
class OuraKeyDraft {
  const OuraKeyDraft({
    required this.keys,
    required this.malformed,
    required this.overflow,
  });

  /// The valid 16-byte keys, in the order they were written, de-duplicated.
  final List<List<int>> keys;

  /// Non-empty lines that are not a key at all. Not blocking: the valid lines
  /// are still tried, and this is what lets the screen say so honestly.
  final int malformed;

  /// Valid keys beyond [kOuraMaxCandidateKeys], which are NOT tried.
  final int overflow;

  bool get isEmpty => keys.isEmpty;
}

/// Parse the key field into candidate keys — one per line, or comma-separated.
///
/// THE WHOLE FIELD IS TRIED AS ONE KEY FIRST, and that order is the compatible
/// one, not a shortcut. [parseOuraKey] strips spaces, colons and hyphens from
/// everything it is given, so `a0:a1:a2:a3 a4-a5-a6-a7` — and even that spread
/// over two lines — has always been one valid key. Splitting first would turn
/// every such field into a pile of malformed fragments. So: if the field parses
/// as a single key, it IS a single key; only then is it split.
///
/// SPLIT ON LINES, COMMAS AND SEMICOLONS, never on spaces, for the same reason:
/// a space inside one key is a grouping separator that already works.
OuraKeyDraft parseOuraKeys(String raw) {
  final whole = parseOuraKey(raw);
  if (whole != null) {
    return OuraKeyDraft(keys: [whole], malformed: 0, overflow: 0);
  }
  final keys = <List<int>>[];
  final seen = <String>{};
  var malformed = 0;
  var overflow = 0;
  for (final token in raw.split(RegExp(r'[\n\r,;]'))) {
    if (token.trim().isEmpty) continue;
    final key = parseOuraKey(token);
    if (key == null) {
      malformed++;
      continue;
    }
    // De-duplicated on the BYTES, so the same key written once as hex and once
    // as base64 is still one candidate and does not burn two connections.
    if (!seen.add(_hex(key))) continue;
    if (keys.length >= kOuraMaxCandidateKeys) {
      overflow++;
      continue;
    }
    keys.add(List<int>.unmodifiable(key));
  }
  return OuraKeyDraft(keys: keys, malformed: malformed, overflow: overflow);
}

/// The live link to a paired Oura ring. One instance; a second concurrent ring
/// is not a thing anyone asked for.
class OuraLink {
  OuraLink._();
  static final OuraLink instance = OuraLink._();

  /// The `device` row for the paired ring, or null.
  ///
  /// `id` is MINTED at pairing (`oura-0a1b2c3d`), never the BLE remote id: a
  /// remote id is a per-app CBPeripheral UUID on iOS and a rotating RPA on
  /// Android, and letting one become the storage key fragments one ring into N
  /// identities. `remote_id` is the column that may change under the same row.
  static Future<Map<String, Object?>?> pairedRingRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kOura.id) return r;
    }
    return null;
  }

  /// Delete the stored 16-byte pairing key for [deviceId], best-effort.
  ///
  /// Two callers, one problem: an Oura pairing secret must not outlive the
  /// thing it was for. [pairOuraRing] writes the key BEFORE the ring proves it
  /// (see that function's own header) so a crash mid-pair leaves an orphaned
  /// key with no `device` row pointing at it; forgetting a paired ring later
  /// leaves the same kind of orphan if only the row goes. Swallows a locked
  /// keychain/keystore exactly as [_readKey] does — there is nothing for the
  /// user to redo, and a delete that cannot run now costs nothing left behind
  /// that this app itself can read.
  static Future<void> _dropKey(String deviceId) async {
    try {
      await _secure.delete(
        key: _keyItem(deviceId),
        iOptions: _kApple,
        mOptions: _kMacos,
      );
    } catch (e) {
      debugPrint('[oura] could not drop the stored key: $e');
    }
  }

  /// Forget a paired ring: drop its key, drop its `device` row.
  ///
  /// THE ORDER IS THE OPPOSITE OF PAIRING'S, on purpose. [pairOuraRing] writes
  /// the key before the row because an unpointed-to key is harmless; forgetting
  /// deletes the key before the row for the same reason in reverse — a crash
  /// between the two here would rather leave a `device` row whose key is
  /// already gone (which just fails the next sync visibly) than a key outliving
  /// the row that was its only reason to exist.
  static Future<bool> forgetRing(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[oura] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) {
      await instance.stop();
    }
    await _dropKey(id);
    await LocalDb.deleteDevice(id);
    return true;
  }

  /// The most recent battery reading the ring reported, or null.
  ///
  /// DELIBERATELY NOT WRITTEN TO `band_battery`. That table has no `device_id`
  /// column and `LocalDb.batteryHealth()` reads it unfiltered — `MAX(millivolts)
  /// WHERE charging = 1` across every row — so a ring cell's voltage would land
  /// in the WHOOP band's pack-health series as the band's own full-charge
  /// voltage, and the charge-cycle count beside it comes from `band_events`,
  /// which the ring cannot contribute to. Two different cells reported as one
  /// pack is a wrong number with no way to notice it. Held here instead.
  int? get batteryPct => _batteryPct;
  int? get batteryMv => _batteryMv;
  int? _batteryPct;
  int? _batteryMv;

  BluetoothDevice? _device;

  /// Kept only so teardown can [BandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same ring.
  BandLink? _link;

  /// The session driving [OuraAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired ring — the `device_id` every row it writes
  /// carries. Never [LocalDb.kPrimaryDeviceId]: `''` is the primary band,
  /// permanently (ASSUMPTIONS A1).
  String? _deviceId;

  /// Wall-clock now, in Unix seconds. A field so a replay is deterministic.
  int Function() _now =
      () => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// The `(ring decisecond, Unix second)` origin, as it is stored: `"ds,unix"`.
  ///
  /// Read from `sync_cursor` at the start of a session and handed to the
  /// adapter, which stamps against it and hands back a better one when a
  /// `time_sync` event gives it a measured pair. The host keeps the STRING
  /// because keeping it is all it does — parsing it into two ints and stamping
  /// with them here would be a second implementation of an origin, and two
  /// origins is the bug this whole mechanism exists to prevent.
  String? _anchor;

  /// Cursor writes, in arrival order, so teardown can wait for them.
  ///
  /// SERIALISED AND AWAITED, both load-bearing. The bookmark is written from an
  /// event callback that nothing awaits, so fire-and-forget let a teardown run
  /// first — and `stop()` clears `_deviceId`, which made the write a silent
  /// no-op. It also let a stranded-bookmark RESET be overtaken by an ordinary
  /// advance arriving after it, putting the useless bookmark straight back.
  Future<void> _cursorWrites = Future.value();

  void _writeCursor(int ds) {
    _cursorWrites =
        _cursorWrites.then((_) => _persistCursor(ds)).catchError((Object e) {
      // Kept off the error path so later writes still run, but NOT silent:
      // a bookmark that never persisted means the checkpoint chain broke,
      // and `_runSession` must not report that session as synced.
      _cursorWriteFailed = true;
      debugPrint('[oura] cursor write failed: $e');
    });
  }

  /// A cursor write of the CURRENT session failed. Reset per session.
  bool _cursorWriteFailed = false;

  /// Drop the bookmark and the stored time anchor, through the same queue.
  ///
  /// The reset means the ring's decisecond counter restarted, so the stored
  /// `(ds, unix)` anchor belongs to the dead boot; left in place it would
  /// stamp the new boot's readings wrong. Without it they wait for the new
  /// boot's own `time_sync`. [deviceId] is captured because this can run
  /// after `stop()` nulled `_deviceId`. A failed anchor delete aborts the
  /// reset, so cursor 0 never lands next to the old anchor.
  void _resetCursor(String deviceId) {
    _cursorWrites = _cursorWrites.then((_) async {
      _anchor = null;
      await LocalDb.deleteCursor(_anchorItem(deviceId));
      await _persistCursor(0, deviceId);
    }).catchError((e) {
      debugPrint('[oura] stranded reset incomplete; the bookmark stays and '
          'the next sync re-runs it: $e');
    });
  }

  /// Whether the last session's drain reached the ring's honest end (empty
  /// up-to-date answer, or `bytesLeft` drained to zero). A session that ends on
  /// a refused write, a timeout, an authentication failure or a host commit
  /// failure is a session that connected and synced nothing — reported as
  /// itself, not as "Synced.".
  bool _drainOk = false;

  /// Why the LAST session ended the way it did — session-scoped, set by the
  /// adapter's own notes, read by the UI between syncs. Never sticky across
  /// sessions: `_runSession` clears it at the start of every session.
  OuraSyncCategory _category = OuraSyncCategory.none;

  /// Test-only fault seams, NEVER set in production: [commitFaultForTest]
  /// wraps the durable batch commit at its real site inside `BandHost`;
  /// [cursorFaultForTest] makes the cursor persistence throw. Both are
  /// reset by every test's teardown (the tests set them to null in a
  /// `finally`), so no test can influence the next one.
  Future<void> Function(Future<void> Function() commit)? _commitFaultForTest;
  Future<void> Function(String item, String value)? _cursorFaultForTest;

  bool _busy = false;

  /// Connect to the paired ring, drain its history to the end, disconnect.
  ///
  /// Returns false when nothing is paired, the key is unreadable, or the
  /// connect failed. SERIALISED: a second call while one is in flight is a
  /// no-op rather than a second radio session over the same peripheral.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    // THE CATEGORY DESCRIBES THIS CALL, not the previous one: cleared before
    // the FIRST return, so every early exit below (nothing paired, primary
    // id, unreadable key, adapter off, connect/discovery failure) reports
    // `none` — never a stale category from an earlier attempt. A BUSY
    // second call never reaches here (see `sync()`), so it cannot clobber
    // the running session's category either.
    _category = OuraSyncCategory.none;
    final row = await pairedRingRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      // The primary band's id, permanently. A ring writing under it would
      // interleave its seconds with the band's in one REPLACE-keyed table.
      debugPrint('[oura] refusing to sync: the ring row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    final key = await _readKey(deviceId);
    if (key == null) {
      // Distinct from "not paired": the row exists, so the user believes they
      // paired it. A locked keystore fixes itself on the next unlocked run.
      debugPrint('[oura] paired, but the pairing key could not be read. '
          'Nothing is written and nothing is re-keyed.');
      return false;
    }

    _deviceId = deviceId;
    await _loadAnchor(deviceId);
    final cursor = await LocalDb.getCursorInt(_cursorItem(deviceId)) ?? 0;

    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). This offload
      // sync's connect, drain and disconnect all complete inside this one
      // call, so the simple scoped form is correct here — unlike HrsLink's
      // live session, nothing outlives this method.
      //
      // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately. Held in an outer
      // `finally` it ran AFTER `withSecondaryLinkSlot` had already released
      // the slot, so the next queued link could connect while this one was
      // still disconnecting — one more live GATT link than the cap allows.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await _awaitAdapterOn();
          await device.connect(timeout: const Duration(seconds: 20));
          // NO EXPLICIT MTU REQUEST, deliberately. `flutter_blue_plus` 1.36.8
          // ASKS for MTU 512 right after `connect()` on Android (its
          // `connect` defaults `mtu: 512`); iOS negotiates its own.
          //
          // A REQUEST IS NOT A NEGOTIATED VALUE. What the ring and the phone
          // actually settle on is not known here, and nothing below depends
          // on it. Whether this ring ever sends a frame too large for a
          // default-MTU notification is an unverified hardware question —
          // the wire format allows up to 257 bytes, but that a frame CAN be
          // that large does not mean the ring SENDS one, and no fix may be
          // built on that assumption without a capture. A second explicit
          // `requestMtu` here is the one change that could make things
          // worse: on Android 14+ later requests on the same ACL are
          // ignored, and on older Android it could only LOWER a value the
          // library already asked for. Read the negotiated MTU from a
          // hardware log before drawing any conclusion from frame sizes.
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kOura,
            services: services,
            onLog: (m) => debugPrint('[oura] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kOura.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[oura] ${kOura.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          // `return await`, NOT a bare `return future`. The claim that a
          // bare `return future` in an async function is always equivalent
          // to `return await` is NOT sound as specified: Dart SDK issue
          // #44395 and language issue #870 document a specification/
          // implementation divergence around exactly this try/finally
          // interaction, and behavior around `finally`-vs-await ordering
          // for a bare returned future has been implementation-defined
          // territory rather than guaranteed semantics. The safe, explicit
          // form is `return await` — the finally provably runs AFTER the
          // session completes. The teardown itself lives in
          // [_runSessionAndTeardown] so the exact production order is
          // testable without a radio.
          return await _runSessionAndTeardown(link, deviceId,
              key: key, cursor: cursor);
        } finally {
          // Drop the link and DISCONNECT before the slot is released. Also
          // covers the EARLY returns above (adapter off, no characteristics),
          // which do not go through [_runSessionAndTeardown]; for the
          // session path this is a second, idempotent stop. A failure of
          // THIS stop must never MASK an exception the session already
          // raised (a throwing finally replaces the in-flight error in
          // Dart) — so it is logged, not propagated. The FIRST stop, the
          // one on the session path, already applied the same priority
          // rule in [_runSessionAndTeardown] and propagates its own
          // teardown failure when the session SUCCEEDED.
          try {
            await stop();
          } catch (e) {
            debugPrint('[oura] teardown failed: $e — the session\'s own '
                'verdict is the one reported.');
          }
        }
      });
    } catch (e) {
      debugPrint('[oura] sync failed: $e');
      return false;
    }
  }

  /// THE POST-DISCOVERY DRAIN — the exact code `sync()` runs once a live
  /// link exists, and the only place the session's result is decided.
  ///
  /// SUCCESS IS `oura_drain_ok`, the adapter's own statement that the drain
  /// reached its honest end, and that note is emitted only AFTER the last
  /// batch's `OffloadCheckpoint` was confirmed — which the host does only
  /// after its durable commit landed (`BandHost._commitThenConfirm`). So a
  /// storage failure, an unconfirmed batch, an authentication refusal, a
  /// refused write or a silent ring all end the session WITHOUT the note and
  /// report `false`; an honestly empty, up-to-date ring ends WITH it and
  /// reports `true` without inventing a single measurement. A BLE link alone
  /// is not a successful sync — that distinction is this method's whole job.
  ///
  /// Shared with the test replay path ([ingestForTest],
  /// [syncResultForTest]) so the result a test drives IS the result `sync()`
  /// returns, not a parallel construction of it.
  Future<bool> _runSession(
    BandLink link,
    String deviceId, {
    required List<int> key,
    required int cursor,
    Duration? replyTimeout,
    Duration? confirmTimeout,
  }) async {
    _drainOk = false;
    _cursorWriteFailed = false;
    // A NEW SESSION STARTS CLEAN: the category describes THIS session only.
    // A previous failure must not colour the next attempt's report.
    _category = OuraSyncCategory.none;
    final host = _makeHost(
      deviceId,
      OuraAdapter(
        key: key,
        startCursorDs: cursor,
        anchor: _parseAnchor(_anchor),
        nowSeconds: _now,
        replyTimeout: replyTimeout ?? const Duration(seconds: 5),
        confirmTimeout: confirmTimeout ?? const Duration(seconds: 30),
      ),
    );
    _host = host;
    await host.run(link);
    // The bookmark writes the drain queued must have landed before the
    // drain counts as done: a cursor that never persisted is a broken
    // checkpoint chain, not a sync.
    await _cursorWrites;
    if (_cursorWriteFailed) {
      _drainOk = false;
      _category = OuraSyncCategory.storageFailed;
    }
    if (!_drainOk) {
      debugPrint('[oura] session ended before the drain reached its '
          'end — reporting the sync as unsuccessful.');
    }
    return _drainOk;
  }

  /// THE PRODUCTION OUTER ORDER, extracted so a test can drive it: the
  /// session first, `stop()` in a `finally` after it ends — and `return await`
  /// inside the `try`, because a bare `return _runSession(...)` runs the
  /// `finally` before the returned future completes, i.e. teardown while the
  /// drain is still open. `sync()` calls this; the lifecycle test drives the
  /// same method through the replay seam, not a copy of it.
  Future<bool> _runSessionAndTeardown(
    BandLink link,
    String deviceId, {
    required List<int> key,
    required int cursor,
    Duration? replyTimeout,
    Duration? confirmTimeout,
  }) async {
    var sessionThrew = false;
    try {
      return await _runSession(link, deviceId,
          key: key,
          cursor: cursor,
          replyTimeout: replyTimeout,
          confirmTimeout: confirmTimeout);
    } catch (_) {
      sessionThrew = true;
      rethrow;
    } finally {
      // ERROR PRIORITY, spelled out for all three cases:
      //  - session returned (true OR false — both are VERDICTS, not errors)
      //    and the teardown failed: the teardown failure propagates with
      //    its own stacktrace — a `false` session does not license a lost
      //    cleanup;
      //  - session THREW and the teardown failed too: the session's
      //    ORIGINAL error (already in flight, with its stacktrace) is the
      //    one that propagates — a throwing `finally` would REPLACE it in
      //    Dart, so the teardown failure is logged beside it instead and
      //    is never silent.
      try {
        await stop();
      } catch (e, s) {
        if (sessionThrew) {
          debugPrint('[oura] teardown failed as well: $e — the session\'s '
              'own error is the one reported.');
        } else {
          Error.throwWithStackTrace(e, s);
        }
      }
    }
  }

  /// Drop the link, flush what the session can still stamp, disconnect.
  /// Safe to call when nothing is connected. NO EPOCH GUARD is needed: the
  /// production path serializes sessions on `[_busy]`, and the replay
  /// harness never surfaces its verdict while the session body is still
  /// live — `close()` releases every await boundary the fixture owns
  /// (write gate, buffered channels), so the session ALWAYS unwinds and
  /// its own `finally { stop() }` runs BEFORE the harness's `done` future
  /// completes. A caller that awaited the session result can therefore
  /// never observe a teardown racing a follow-up session.
  Future<void> stop() {
    // RE-ENTRANT BY SHARING THE ONE CLEANUP: a second caller must not run a
    // second cleanup over the same (already nulled) fields, and an empty
    // `_link`/`_host` is not proof the FIRST cleanup finished — only that
    // it started. Every caller awaits the SAME future, so the second call
    // neither duplicates the teardown nor returns before it is done.
    final running = _stopping;
    if (running != null) return running;
    final done = _doStop();
    _stopping = done;
    // Clear the guard when the cleanup settles, so a LATER stop (a next
    // session's teardown) is not swallowed by the previous session's run.
    done.whenComplete(() {
      if (identical(_stopping, done)) _stopping = null;
    }).catchError((Object e, StackTrace st) {
      // The DERIVED future's error, not the original's: `whenComplete`
      // returns a NEW future that replays the cleanup's result, and nobody
      // awaits that one — an erroring cleanup would surface as an unhandled
      // async error here. Swallowing it on the DERIVED future changes
      // nothing for real awaiters: they hold `done` and still see the
      // error, its stacktrace intact.
      debugPrint('[oura] teardown finished with an error: $e');
    });
    return done;
  }

  /// The one actual teardown. Owned by [stop] above.
  Future<void>? _stopping;

  Future<void> _doStop() async {
    // Before the host's run subscription is cancelled: an adapter's `finally`
    // can still write on the way out, and that write must not reach the radio.
    // The link and host are captured LOCALLY before the first await: the
    // fields are cleared immediately, so a late caller cannot hand the SAME
    // resources to a second cleanup. The close future is STARTED here (the
    // write refusal must be in force at once) but NOT awaited yet: the replay
    // link's channel closes can wait on a consumer that only ends when the
    // host stops, so awaiting close before `host.stop()` could deadlock
    // before the cleanup it is part of. Its error is recorded and, AFTER the
    // host shutdown and the remaining steps, the close future is AWAITED —
    // by then every consumer the close could be waiting on has ended, so the
    // wait is bounded by the close's own work. Only then is the cleanup
    // complete, and only then do the captured failures surface, with their
    // original stacktraces, in a fixed priority (close first, host second —
    // the session's own error keeps priority in the CALLERS, via
    // `_runSessionAndTeardown`'s `sessionThrew` and `_sync`'s finally).
    final link = _link;
    _link = null;
    Future<void>? closing;
    Object? closeError;
    StackTrace? closeStack;
    if (link != null) {
      closing = Future<void>.sync(() => link.close()).catchError(
          (Object e, StackTrace s) {
        closeError = e;
        closeStack = s;
      });
    }
    final host = _host;
    _host = null;
    Object? hostError;
    StackTrace? hostStack;
    if (host != null) {
      // A host teardown failure must not SKIP the cursor flush and the
      // disconnect still pending below. It is recorded and surfaces after
      // the cleanup, under the close error if both failed.
      try {
        await host.stop();
      } catch (e, s) {
        hostError = e;
        hostStack = s;
      }
    }
    Object? cursorError;
    StackTrace? cursorStack;
    try {
      await _cursorWrites;
    } catch (e, s) {
      cursorError = e;
      cursorStack = s;
    }
    _anchor = null;
    _deviceId = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (e) {
        // Observed, not blanket-swallowed: a disconnect that fails AFTER a
        // successful close/host teardown is "already gone"; one that fails
        // after an erroring close is a second, independent failure worth a
        // log line. It never masks the prioritised errors above - it is
        // datasparsely logged beside them.
        debugPrint('[oura] disconnect during teardown failed: $e');
      }
    }
    // The host consumers are gone: the close wait can no longer deadlock on
    // one. Await the STARTED close so a failure that lands only now is still
    // captured — without this await, a close that fails after the checks
    // below would drop its error silently and stop() would report a cleanup
    // that is still running as complete.
    if (closing != null) await closing;
    // The cleanup has now fully run. Surface the captured failures with
    // their ORIGINAL stacktraces — none may be silent, and none may have
    // prevented any part of the teardown from happening.
    if (closeError != null) {
      Error.throwWithStackTrace(closeError!, closeStack!);
    }
    if (hostError != null) {
      Error.throwWithStackTrace(hostError, hostStack!);
    }
    if (cursorError != null) {
      Error.throwWithStackTrace(cursorError, cursorStack!);
    }
  }

  /// Build this session's [BandHost]. One place, so `_sync()` and
  /// [ingestForTest] cannot drift on what each callback does.
  BandHost _makeHost(String deviceId, OuraAdapter adapter) => BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[oura] $m'),
        onNote: _handleNote,
        admitSample: _isPlausibleSecond,
        buildArchive: _buildArchiveRow,
        faultCommitForTest: _commitFaultForTest,
        // The anchor is folded into the SAME commit transaction as the rows it
        // stamped — see `_makeHost`'s own caller and [BandHost]'s doc on
        // `extraCursors` — so an origin can never survive a commit its own
        // rows did not.
        extraCursors: () =>
            _anchor == null ? const {} : {_anchorItem(deviceId): _anchor!},
        nowSeconds: _now,
      );

  /// Verbatim the old `BandNote` switch — moved, not rewritten.
  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'oura_cursor_ds':
        // Emitted only AFTER the host confirmed, which is only after the
        // commit landed. Persisting it here is therefore always behind the
        // durable data, never ahead of it.
        if (value is int) _writeCursor(value);
      case 'oura_anchor':
        // The origin the adapter measured. Read back by `_makeHost`'s
        // `extraCursors` at the NEXT commit, so an origin can never survive a
        // commit its own rows did not.
        if (value is String) _anchor = value;
      case 'oura_cursor_stranded':
        // The bookmark points past everything the ring holds, which happens
        // when the ring reboots and its decisecond counter restarts below
        // it. Dropping it costs one full re-read and is otherwise free: a
        // re-read is idempotent here (`decoded_onehz` REPLACEs by second,
        // `raw_archive` dedups on the frame bytes). Leaving it costs every
        // record the ring takes from here on, silently.
        debugPrint('[oura] the bookmark is past the end of the ring — '
            'dropping it so the next sync re-reads from the beginning.');
        final deviceId = _deviceId;
        if (deviceId != null) _resetCursor(deviceId);
      case 'oura_drain_ok':
        // The adapter's own statement that the drain reached the ring's end.
        _drainOk = true;
        _category = OuraSyncCategory.drained;
      case 'oura_auth_refused':
        // The ring's OWN explicit key rejection. NOT emitted for silence.
        _category = OuraSyncCategory.authRefused;
      case 'oura_write_refused':
        // The link refused a command write: subscription/transport-level.
        _category = OuraSyncCategory.writeRefused;
      case 'oura_no_batch_summary':
        // Connected and authenticated, but the batch never ended inside the
        // reply window — a protocol timeout, not an unreachable ring.
        _category = OuraSyncCategory.protocolTimeout;
      case 'host_commit_failed':
        // The host observed a failed durable batch commit — the most
        // specific persistence signal. Recorded ahead of the adapter's
        // generic unconfirmed-note below, which arrives later and must not
        // overwrite it.
        _category = OuraSyncCategory.storageFailed;
      case 'oura_batch_unconfirmed':
        // Only the CONFIRM is known to have failed here — the commit's own
        // outcome is not named by this note, so the category must not claim
        // one: `checkpointUnconfirmed`, not `storageFailed`. A commit failure
        // the host already reported stays the more specific truth.
        if (_category != OuraSyncCategory.storageFailed) {
          _category = OuraSyncCategory.checkpointUnconfirmed;
        }
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'battery_mv':
        if (value is int) _batteryMv = value;
      default:
        debugPrint('[oura] $key = $value');
    }
  }

  /// NO RECORD IS FROM THE FUTURE. The only plausibility bound available for
  /// free, and the one that catches a stale origin extrapolating FORWARD
  /// after a ring reboot. The backwards direction has no free bound — the
  /// ring's history depth is not a number this project knows — so the lower
  /// bound is only the "an absolute Unix second in this decade" window an
  /// origin has to be inside to be an origin at all.
  bool _isPlausibleSecond(int tsEpoch) {
    if (tsEpoch > _now() + 300 || tsEpoch < 1700000000) {
      debugPrint('[oura] refusing an implausible second ($tsEpoch); the '
          'bytes are archived, the reading is not stored.');
      return false;
    }
    return true;
  }

  /// Bank one frame verbatim, decoded or not (owner rulings R1-R3): the beat
  /// intervals, SpO2 and the steps are all in here undecoded and the bytes
  /// are banked now so a decoder written when someone owns a ring can be run
  /// over them.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final f = parseOuraFrame(bytes);
    if (f == null) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This band has no flash-record counter, and `counter` is
      // what `thinRawArchiveBefore` samples on — a 0 for every row would make
      // every Oura frame `0 % 60 == 0`, i.e. permanently exempt, which is
      // accidental policy.
      counter: null,
      // The frame TAG. `packet_type` is documented as a WHOOP inner[0], and
      // this is the same thing one layer over — safe to share the column
      // because `reason` below is what every reader of this table selects on.
      packetType: f.tag,
      // NULL, and it stays NULL. `rec_ts` would be this frame's wall-clock
      // second, which is exactly the thing that may not be knowable.
      recTs: null,
      capturedAt: capturedAtMs,
      // ONE REASON PER TAG, so a decoder written later finds its records by
      // name instead of re-scanning the table. NOT in
      // `LocalDb.redrivableArchiveReasons`, deliberately and permanently:
      // `redriveArchivedRecords` replays a row's `hex` through
      // `_decodeOneHzSample`, which is the WHOOP R24 chain. Handing it an
      // Oura frame would run the wrong decoder over the right bytes, which is
      // the one failure this project treats as worse than an absent number.
      reason: 'oura_evt_0x${f.tag.toRadixString(16).padLeft(2, '0')}',
    );
  }

  Future<void> _persistCursor(int ds, [String? forDevice]) async {
    final deviceId = forDevice ?? _deviceId;
    if (deviceId == null) return;
    final fault = _cursorFaultForTest;
    if (fault != null) {
      await fault(_cursorItem(deviceId), '$ds');
      return;
    }
    // NOT MONOTONIC, and it must not be. 0 arrives here when the ring reports
    // data remaining and answers this bookmark with nothing — a bookmark past
    // the end, which only ever gets there by going BACKWARDS. A guard that
    // refused to lower it would turn the one recoverable case into the
    // permanent stall it exists to fix.
    await LocalDb.setCursor(_cursorItem(deviceId), '$ds');
  }

  Future<void> _loadAnchor(String deviceId) async {
    _anchor = await LocalDb.getCursor(_anchorItem(deviceId));
  }

  /// The stored origin as a pair, or null when there is not a usable one.
  /// A malformed value is treated as no origin: the session then abstains
  /// until the ring hands it a measured one, which is the safe direction.
  static (int, int)? _parseAnchor(String? raw) {
    final parts = raw?.split(',') ?? const [];
    if (parts.length != 2) return null;
    final ds = int.tryParse(parts[0]);
    final unix = int.tryParse(parts[1]);
    return (ds == null || unix == null) ? null : (ds, unix);
  }

  static Future<List<int>?> _readKey(String deviceId) async {
    try {
      final hex = await _secure.read(
        key: _keyItem(deviceId),
        iOptions: _kApple,
        mOptions: _kMacos,
      );
      return hex == null ? null : _unhex(hex);
    } catch (e) {
      // A locked keychain and a wedged keystore both land here. Distinct from
      // "no key": there is nothing for the user to redo, and the next unlocked
      // run reads it fine.
      debugPrint('[oura] the keychain was unavailable: $e');
      return null;
    }
  }

  /// Replay a scripted ring through the REAL [OuraAdapter] and the real write
  /// path. The only way in: the entry point is a BLE notification and
  /// `flutter_blue_plus` has no simulator path.
  ///
  /// [reply] answers each write the way the ring would, exactly as
  /// `oura_adapter_test.dart` scripts it — a replay link records writes but
  /// cannot react to them.
  ///
  /// PR #389 bumped this from 50ms to 2s to chase the same flake this comment
  /// now documents properly — it wasn't enough, because it was diagnosing the
  /// wrong wait. Bisected with `print()`s at every `return` in
  /// `OuraAdapter.run`/`_authenticate`/`_collectBatch`, sweeping this value
  /// from 1us to 10ms: below ~1ms the auth-challenge round trip (pure
  /// microtask hops, no I/O) times out first; between roughly 1ms and 10ms
  /// the failure is ALWAYS `confirmTimeout` firing on `BandHost
  /// ._commitThenConfirm`'s `await done.future`, which does not complete
  /// until `LocalDb`'s REAL sqflite commit for the batch lands — genuine disk
  /// I/O this file's own header deliberately keeps real (`raw_archive` /
  /// `decoded_onehz`, not a mock). That commit is not driven by a fake clock
  /// or a Timer this test controls, so no amount of `FakeAsync`/virtual-time
  /// plumbing here can make its completion deterministic — only a real
  /// wall-clock bound can, and CI wedges that bound with GC pauses and
  /// scheduler jitter ~1000+ tests deep into one isolate. So this cannot be
  /// made deterministic; the honest fix is a bound generous enough that a
  /// small local sqlite commit could never legitimately approach it. 2s
  /// already wasn't that bound (10ms was enough on an idle laptop above);
  /// 30s is — nothing on the happy path here waits anywhere near it, it only
  /// still exists to bound a genuinely wedged production ring.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<int> key,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    int Function()? nowSeconds,
    Duration timeouts = const Duration(seconds: 30),
  }) async {
    await _replaySession(
      deviceId,
      key,
      reply,
      nowSeconds: nowSeconds,
      timeouts: timeouts,
    );
    return _lastLink!;
  }

  /// The same replay as [ingestForTest], but returning the SESSION RESULT —
  /// the same bool `_runSession` (and therefore `sync()`) computes — instead
  /// of the link. The regression tests for "connected ≠ synced" assert on
  /// THIS, not on a field, so the result path a test drives is the result
  /// path production runs.
  @visibleForTesting
  Future<bool> syncResultForTest(
    String deviceId,
    List<int> key,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    int Function()? nowSeconds,
    Duration timeouts = const Duration(seconds: 30),
    bool writeSucceeds = true,
    Duration harnessTimeout = const Duration(seconds: 30),
    void Function(ReplayBandLink link)? onLink,
  }) async =>
      await _replaySession(
        deviceId,
        key,
        reply,
        nowSeconds: nowSeconds,
        timeouts: timeouts,
        writeSucceeds: writeSucceeds,
        harnessTimeout: harnessTimeout,
        onLink: onLink,
      );

  /// One scripted ring session through the REAL result path: `_runSession`,
  /// the same method `sync()` calls once a live link exists. The reply script
  /// and the replay link are test-only; every line that decides whether this
  /// session was a successful sync is production code.
  Future<bool> _replaySession(
    String deviceId,
    List<int> key,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    int Function()? nowSeconds,
    required Duration timeouts,
    bool writeSucceeds = true,
    Duration harnessTimeout = const Duration(seconds: 30),
    void Function(ReplayBandLink link)? onLink,
  }) async {
    // LINK and the [onLink] hook are set up SYNCHRONOUSLY, before the
    // first await: a test's `onLink` (installing a write gate, capturing the
    // link) must not race the session's first write or the test's own first
    // read of the captured link.
    final link = ReplayBandLink()..writeSucceeds = writeSucceeds;
    _lastLink = link;
    onLink?.call(link);
    // REGISTERED AS THE SESSION'S LINK, exactly as `_sync` does after
    // discovery and `startSessionForTest` does before its session: without
    // this, the session's own teardown (`stop()` → `_link?.close()`) has
    // NOTHING to close and the harness's fallback close below would do the
    // production teardown's job — masking, in every `syncResultForTest` /
    // `ingestForTest` test, the exact code path a real sync runs. Exclusivity
    // is the replay path's own: it is test-only, awaited to completion by
    // its caller before anything else can start a session, so no second
    // owner can appear between this assignment and the teardown.
    _link = link;
    _now = nowSeconds ?? _now;
    _deviceId = deviceId;
    await _loadAnchor(deviceId);
    final cursor = await LocalDb.getCursorInt(_cursorItem(deviceId)) ?? 0;
    var finished = false;
    // THE REAL RESULT PATH, including the production outer order:
    // `_runSessionAndTeardown` is the session-then-stop pairing `sync()`
    // runs, so a replayed session also proves teardown happens after the
    // drain, never during it. The loop below only scripts what the ring
    // would answer.
    final done = _runSessionAndTeardown(
      link,
      deviceId,
      key: key,
      cursor: cursor,
      replyTimeout: timeouts,
      confirmTimeout: timeouts,
    ).whenComplete(() => finished = true);
    var served = 0;
    // ONE deadline, started ONCE and shared by every stage below: the
    // serving loop, the link close and the session wait all draw on the
    // SAME remaining budget. The bound is the HARNESS patience, not the
    // protocol timeouts: a session still running when the budget expires
    // is wedged from the harness's point of view, and the watchdog turns
    // that into a test failure — it can never become a normal `false`,
    // whichever stage expired first.
    final clock = Stopwatch()..start();
    Duration left() => harnessTimeout - clock.elapsed;
    while (!finished && left() > Duration.zero) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      while (served < link.writes.length) {
        for (final f in reply(served, link.writes[served].$2)) {
          link.feed(kOuraNotifyChar, f, atSec: _now());
        }
        served++;
      }
    }
    final servingExpired = !finished;
    // The wedged session's link: closed UNCONDITIONALLY on the shared
    // budget — close() releases every await boundary this fixture owns
    // (the write gate, the buffered channels), so the parked session can
    // ALWAYS unwind: `_authenticate` returns false behind the closed
    // channels and `run()` ends. Without this, `BandHost.stop`'s
    // `cancel()` would wait forever on a generator parked on a dead
    // link — the cleanup hang the review called out.
    try {
      await link.close().timeout(left() > Duration.zero ? left() : Duration.zero,
          onTimeout: () {});
    } catch (_) {
      // A fixture whose close throws still leaves `closed`/`writesRefused`
      // set synchronously at its top — the refusal is already in force.
    }
    // TWO DIFFERENT TIMEOUTS, deliberately not collapsed:
    //  - the SESSION's own protocol timeouts (replyTimeout/confirmTimeout)
    //    produce a regular `false` — a reachable, tested behaviour;
    //  - THIS watchdog is the HARNESS giving up on a wedged session. A
    //    negative test expecting `false` must NOT be able to pass because
    //    the harness hung: the watchdog therefore THROWS a visible test
    //    failure instead of returning `false` and greenwashing a hang.
    Object? harnessFailure;
    StackTrace? harnessFailureTrace;
    bool result = false;
    try {
      result = await done.timeout(left() > Duration.zero ? left() : Duration.zero,
          onTimeout: () {
        // Record, do not resolve: a `false` HERE would hand a negative
        // test the very `false` it expects and let a hang pass as a
        // verdict. The flag is `servingExpired || deadline spent` below.
        return false;
      });
    } catch (e, s) {
      // The session's OWN exception survives WITH its cause and stacktrace —
      // the watchdog wraps, it does not swallow.
      harnessFailure = e;
      harnessFailureTrace = s;
    }
    // CLEANUP RUNS ON EVERY PATH — including the harness timeout. It
    // reuses the production teardown: when the wedged session is still
    // the current one, `stop()` does the full cleanup (host stopped,
    // cursor writes flushed, fields cleared) exactly as a normal path
    // would. The close above already released every await boundary the
    // session can be parked on, so `stop()` cannot hang on it; only
    // AFTER cleanup does the watchdog's failure surface, so a wedged
    // session can never leave a half-torn OuraLink behind either.
    await stop();
    // THE HARNESS VERDICT: if the shared deadline expired with the session
    // unfinished — whether the serving loop, the close, or the session
    // wait drew the last of the budget — that is a wedged session and a
    // TEST FAILURE, never a normal `false`. An expired deadline cannot be
    // turned into a clean verdict by the session aborting (and returning
    // false) only AFTER the deadline.
    if (servingExpired || clock.elapsed >= harnessTimeout) {
      if (harnessFailure != null) {
        // The session threw on its own (close released it into an error,
        // or it failed for its own reasons): its ORIGINAL error and
        // stacktrace are the verdict, not a timeout label.
        Error.throwWithStackTrace(harnessFailure, harnessFailureTrace!);
      }
      throw StateError(
          'Oura replay session did not finish within $harnessTimeout — the '
          'harness cannot tell a wedged session from a slow one, so this is '
          'a test failure, not a sync result.');
    }
    if (harnessFailure != null) {
      // The session threw on its own WELL WITHIN the budget: its error
      // with its original stacktrace is the verdict.
      Error.throwWithStackTrace(harnessFailure, harnessFailureTrace!);
    }
    return result;
  }

  /// The replay link of the last [ingestForTest] or [syncResultForTest]
  /// session, so a test can assert on BOTH the session result and the
  /// writes the adapter actually put on the wire.
  ReplayBandLink? _lastLink;

  /// Why the last session ended the way it did. Read by the UI after
  /// `sync()` returns; session-scoped (cleared at every session start), so
  /// it can never describe an earlier attempt. NOT test-only: the devices
  /// screen reads it to pick the honest failure sentence.
  OuraSyncCategory get lastSyncCategory => _category;

  /// Test-only drive of the PRODUCTION note handler — the one place the
  /// category decisions live. For regression tests of note priority only;
  /// never a way for production code to set categories.
  @visibleForTesting
  void handleSyncNoteForTest(String key) => _handleNote(key, null);

  /// Test-only fault injection at the REAL durable-commit site. Set it,
  /// run `syncResultForTest`, clear it in a `finally`.
  @visibleForTesting
  set commitFaultForTest(
          Future<void> Function(Future<void> Function() commit)? fault) =>
      _commitFaultForTest = fault;

  /// Test-only fault injection at the REAL cursor persistence site.
  @visibleForTesting
  set cursorFaultForTest(
          Future<void> Function(String item, String value)? fault) =>
      _cursorFaultForTest = fault;

  /// The live session's host, so a test can prove the harness cleared it
  /// before its verdict surfaced (identity, not just non-null).
  @visibleForTesting
  BandHost? get hostForTest => _host;

  @visibleForTesting
  ReplayBandLink? get lastReplayLink => _lastLink;

  /// A MANUAL-DRIVE session for the lifecycle tests: starts the production
  /// session-plus-teardown pairing ([_runSessionAndTeardown], the same
  /// method `sync()` runs) over a replay link and returns IMMEDIATELY, with
  /// the live link and the pending result future. The test drives the ring
  /// itself — [onWrite] fires synchronously at the top of every write, before
  /// the write resolves, so the test can feed replies and observe ordering
  /// against [ReplayBandLink.closed] with completers, not sleeps.
  ///
  /// The session's own teardown runs INSIDE the returned future's chain, so
  /// awaiting the result future and then checking the link is already the
  /// production cleanup order.
  @visibleForTesting
  Future<(Future<bool> result, ReplayBandLink link)> startSessionForTest(
    String deviceId,
    List<int> key, {
    int Function()? nowSeconds,
    void Function(String uuid, List<int> value)? onWrite,
    void Function(ReplayBandLink link)? onLink,
  }) async {
    // Set up SYNCHRONOUSLY before the first await — see `_replaySession`.
    final link = ReplayBandLink()..onWrite = onWrite;
    onLink?.call(link);
    _now = nowSeconds ?? _now;
    _deviceId = deviceId;
    _drainOk = false;
    await _loadAnchor(deviceId);
    final cursor = await LocalDb.getCursorInt(_cursorItem(deviceId)) ?? 0;
    // Set as `_link`, exactly as `_sync` does after discovery, so the
    // teardown's `_link?.close()` runs the same code path production runs.
    _link = link;
    final result = _runSessionAndTeardown(
      link,
      deviceId,
      key: key,
      cursor: cursor,
      replyTimeout: const Duration(seconds: 30),
      confirmTimeout: const Duration(seconds: 30),
    );
    return (result, link);
  }
}

/// The `device_id` a pairing should REUSE for [priorRow], or null to mint one.
///
/// One physical ring must keep one id across re-pairings: the id is the storage
/// key for `decoded_onehz`, `raw_archive` and every `sync_cursor` item, so a
/// fresh one forks the ring into N identities and orphans everything the last
/// pairing banked. [OuraLink.pairedRingRow] is the same single-ring lookup
/// `sync()` resolves against, which is what makes reuse reconcile rather than
/// fork.
///
/// Null for a row claiming [LocalDb.kPrimaryDeviceId]: `sync()` refuses such a
/// row and tells the user to re-pair with a minted id, so carrying it forward
/// would re-create the exact state that message asks them to escape.
@visibleForTesting
String? ouraReusableDeviceId(Map<String, Object?>? priorRow) {
  final id = priorRow?['id'] as String?;
  return (id == null || id == LocalDb.kPrimaryDeviceId) ? null : id;
}

/// What to tell a user whose OWN key the ring refused, by result code. Not
/// [_kResetFirst]: that sentence tells them to reset the ring, which is exactly
/// what pairing with an existing key exists to avoid.
/// The message when the ring turned down every candidate.
///
/// ONE CANDIDATE KEEPS THE RING'S OWN REFUSAL, verbatim. That sentence names
/// what the ring actually said and what to do about it; wrapping it in "none of
/// your 1 keys worked" would be worse English carrying less information.
///
/// SEVERAL ADMIT TO WHAT WAS NOT TRIED. A user who pasted six lines and is told
/// "none of your 5 keys matched" has been told something false about their
/// sixth, and a line that was silently unparseable is the likeliest thing they
/// would want to fix first.
String _exhausted(
  int tried,
  String lastRefusal, {
  required int skipped,
  required int overflow,
}) {
  final aside = <String>[
    if (overflow > 0)
      '$overflow further key(s) went untried — this tries at most '
          '$kOuraMaxCandidateKeys',
    if (skipped > 0) '$skipped line(s) were not a key and were skipped',
  ];
  if (tried == 1) {
    return aside.isEmpty ? lastRefusal : '$lastRefusal (${aside.join('; ')}.)';
  }
  return 'The ring turned down all $tried keys, so it holds a different one — '
      'or this is a different ring.'
      '${aside.isEmpty ? '' : ' (${aside.join('; ')}.)'}';
}

String _existingKeyRefusal(int? result) => switch (result) {
      kOuraAuthWrongKey => 'The ring refused that key. Check that it is this '
          'ring\'s key and that all of it was copied.',
      kOuraAuthFactoryReset => 'This ring holds no key yet, so there is nothing '
          'to match. Pair it without a key instead.',
      kOuraAuthNotOnboarded => 'The ring matched the key but reported that this '
          'is not the device it was set up with (code 3).',
      _ => 'The ring refused that key (code ${result ?? "none"}).',
    };

/// Pair [device] as this phone's Oura ring. Null on success, or a sentence the
/// user can act on.
///
/// FACTORY RESET IS A PRECONDITION, NOT A CONSEQUENCE. The ring holds exactly
/// one 16-byte key and will only accept a new one while it is factory reset —
/// so a ring currently onboarded to its own vendor app cannot be paired here at
/// all until the owner resets it, and resetting is what removes it from that
/// app. There is no state in which both work. Say that BEFORE the user commits;
/// this function is the point of no return, not the warning.
///
/// THE KEY IS OURS AND NEVER LEAVES THE PHONE. It is generated here by
/// `Random.secure()`, there is no vendor server anywhere in the handshake and
/// no account is needed. Losing it costs another factory reset, nothing more.
///
/// THE ORDER IS INSTALL, THEN PROVE. The key install is unauthenticated — it
/// has to be, since it is what creates the credential — so it goes out first,
/// before any nonce request. The authentication round trip after it is not
/// required by the protocol; it is here because "the ring acknowledged the
/// write" and "the ring will now let us in" are different claims, and a pairing
/// that only checks the first hands the user a device row that can never sync.
///
/// STILL HARDWARE-UNVERIFIED, like everything else on this path (R6).
Future<String?> pairOuraRing(BluetoothDevice device) =>
    _pairOuraRing(device, existingKeys: null);

/// Pair [device] with the 16-byte key the ring ALREADY holds — no factory
/// reset, nothing written to the ring. Null on success, or a sentence the user
/// can act on.
///
/// THE OTHER HALF OF "THERE IS NO STATE IN WHICH BOTH WORK". [pairOuraRing]
/// installs a key of ours, which the ring only accepts while factory reset, and
/// that reset is what removes it from the Oura app. A ring that is in use keeps
/// the key its app installed, and a user who has that key (it is stored in the
/// app's own database on their own phone) can hand it to this app instead:
/// the ring then answers both, one connection at a time.
///
/// READ-ONLY ON THE RING. Only the authentication round trip goes out — the
/// key-install command is never sent on this path — so a wrong key costs a
/// refusal and nothing else. The key is still stored before the device row and
/// dropped if pairing fails, exactly as on the install path.
///
/// [key] is the vendor app's key, which is a credential for the user's own
/// ring: it is kept in the keychain like ours and never leaves the phone.
Future<String?> pairOuraRingWithKey(BluetoothDevice device, List<int> key) =>
    pairOuraRingWithKeys(device, [key]);

/// [pairOuraRingWithKey] for up to [kOuraMaxCandidateKeys] candidates: try each
/// in the order given and keep the first the ring accepts. Null on success, or
/// a sentence the user can act on.
///
/// WHY SEVERAL. A user who extracted keys from a previous setup often has a
/// handful and no way to tell which belongs to which ring — the key is not
/// labelled with a serial anywhere. Trying them one at a time by hand means
/// re-running the whole pairing flow per guess.
///
/// ONE KEY PER CONNECTION, and this is the part not to "optimise". Each
/// candidate gets its own connect and its own handshake: a ring that has just
/// refused an authentication does not hand out a second nonce on the same link,
/// so a loop that re-challenged over one connection would report every
/// candidate after the first as wrong whatever it was. NOT verified here on
/// hardware (R6).
///
/// STILL READ-ONLY ON THE RING. The key-install command is never sent on this
/// path, whatever the candidate count — so a wrong key costs a refusal and
/// nothing else, five times over.
///
/// NOTHING IS STORED UNTIL ONE WINS. The install path writes its key to the
/// keychain BEFORE sending it, because a crash in between would leave the ring
/// holding a key the phone lost; that cannot happen here, since nothing is
/// written to the ring, so the winner's key is stored only once the ring has
/// accepted it. Five candidates therefore leave at most one secret behind, not
/// five.
Future<String?> pairOuraRingWithKeys(
  BluetoothDevice device,
  List<List<int>> keys,
) {
  final draft = <List<int>>[];
  final seen = <String>{};
  for (final k in keys) {
    if (k.length != 16) {
      return Future.value(
          'That is not a ring key: it must be exactly 16 bytes.');
    }
    if (seen.add(_hex(k)) && draft.length < kOuraMaxCandidateKeys) {
      draft.add(List<int>.unmodifiable(k));
    }
  }
  if (draft.isEmpty) {
    return Future.value('No key to try.');
  }
  return _pairOuraRing(device, existingKeys: draft);
}

/// What one candidate key's handshake came to.
///
/// THE DISTINCTION IS THE WHOLE POINT, and it is a §4.1 one. A ring that
/// REJECTED the key has delivered a verdict on that key; a ring that stopped
/// answering, or would not take a command, has delivered a verdict on nothing.
/// A multi-key trial may only advance to the next candidate on the first kind,
/// and may only tell the user "none of these keys is the right one" when every
/// attempt produced one. Collapsing the two is how a flat battery or a ring on
/// the far side of the room gets reported as five wrong keys.
class OuraPairAttempt {
  /// The ring let us in.
  const OuraPairAttempt.accepted()
      : refusal = null,
        keyRejected = false;

  /// The ring answered, and the answer was no. A verdict on this key.
  const OuraPairAttempt.rejected(String this.refusal) : keyRejected = true;

  /// The attempt did not get far enough to be a verdict on this key alone, or
  /// got an answer that holds for every key, so a multi-key trial stops here.
  const OuraPairAttempt.failed(String this.refusal) : keyRejected = false;

  /// The sentence to show the user, or null when the ring let us in.
  final String? refusal;

  /// True only when the ring itself turned this key down.
  final bool keyRejected;

  bool get ok => refusal == null;
}

/// The pairing handshake over an open [link]: install [key] when [install],
/// then prove it.
///
/// Split out of [_pairOuraRing] so the bytes it puts on the wire can be pinned
/// without a radio — in particular that the key-install command is NEVER sent
/// on the existing-key path, which is what makes that path read-only on the
/// ring.
///
/// Over the real wire builders and nothing else.
@visibleForTesting
Future<OuraPairAttempt> ouraPairHandshake(
  BandLink link,
  List<int> key, {
  required bool install,
  Duration replyWindow = const Duration(seconds: 10),
  void Function()? onKeyInstalled,
}) async {
  // ONE subscription and a growing list, rather than a `firstWhere` per
  // reply: `BandLink.notify` is single-subscription, so the second
  // `firstWhere` would throw "already listened to" AFTER the first reply had
  // been consumed — a pairing that fails on a ring that answered correctly.
  // ponytail: a 20 ms poll over the list is the smallest correct thing here.
  // The alternative is a second copy of `oura.dart`'s private `_Inbox`, for
  // three replies, once, during pairing.
  final inbox = <OuraFrame>[];
  final sub = link.notify(kOuraNotifyChar).listen((rec) {
    final f = parseOuraFrame(rec.$2);
    if (f != null) inbox.add(f);
  });
  var read = 0;
  Future<OuraFrame?> waitFor(bool Function(OuraFrame) matches) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < replyWindow) {
      while (read < inbox.length) {
        final f = inbox[read++];
        if (matches(f)) return f;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  try {
    // The key install only when the key is OURS. A key the ring already holds
    // needs nothing but the proof below.
    if (install) {
      if (!await link.write(kOuraCommandChar, ouraCmdSetAuthKey(key))) {
        return const OuraPairAttempt.failed(
            'The ring would not accept a command. Try again with it on '
            'the charger and next to the phone.');
      }
      final installed = await waitFor((f) => ouraSetAuthKeyResult(f) != null);
      // SILENCE IS A REFUSAL, NOT CONSENT. A ring that already holds a key is
      // the case that matters here and it does not necessarily answer at all —
      // and carrying on to mint a `device` row on the strength of a quiet ring
      // is how a user spends a factory reset and ends up with nothing working.
      if (installed == null || ouraSetAuthKeyResult(installed) != 0) {
        return const OuraPairAttempt.rejected(_kResetFirst);
      }
      onKeyInstalled?.call();
    }
    if (!await link.write(kOuraCommandChar, ouraCmdAuthNonce())) {
      return const OuraPairAttempt.failed(
          'The ring would not accept a command. Try again with it on '
          'the charger and next to the phone.');
    }
    final challenge = await waitFor((f) => ouraAuthNonce(f) != null);
    if (challenge == null) {
      return const OuraPairAttempt.failed(
          'The ring stopped answering part-way through pairing. Put it on '
          'the charger, keep it next to the phone, and try again.');
    }
    final answer = ouraAuthResponse(key, ouraAuthNonce(challenge)!);
    if (!await link.write(kOuraCommandChar, ouraCmdAuthenticate(answer))) {
      return const OuraPairAttempt.failed(
          'The ring would not accept the pairing answer.');
    }
    final replyFrame = await waitFor((f) => ouraAuthResult(f) != null);
    if (replyFrame == null) {
      return const OuraPairAttempt.failed(
          'The ring stopped answering part-way through pairing. Put it on '
          'the charger, keep it next to the phone, and try again.');
    }
    // THE CODES CARRY DIFFERENT REMEDIES, so they are not collapsed into one
    // sentence. On the install path, `factoryReset` here means the install did
    // not actually take even though it was acknowledged — retrying is worth a
    // try and does not cost another reset. Everything else means the ring
    // belongs to something else, and only a reset frees it. On the
    // existing-key path a reset is the one thing NOT to suggest.
    final result = ouraAuthResult(replyFrame);
    if (result == 0) return const OuraPairAttempt.accepted();
    // On the install path every branch below is `rejected`: the ring answered
    // the challenge, so it is a verdict on this key. On the existing-key path
    // only a wrong key is; "holds no key" and "matched but not onboarded" are
    // the same answer for every remaining candidate, so they end the trial
    // (`failed`) and are reported as themselves.
    if (!install) {
      return result == kOuraAuthWrongKey
          ? OuraPairAttempt.rejected(_existingKeyRefusal(result))
          : OuraPairAttempt.failed(_existingKeyRefusal(result));
    }
    if (result == kOuraAuthFactoryReset) {
      return const OuraPairAttempt.rejected(
          'The ring took the key but is still waiting for one, which '
          'should not happen. Try pairing again.');
    }
    return const OuraPairAttempt.rejected(_kResetFirst);
  } finally {
    await sub.cancel();
  }
}

/// [pairOuraRingWithKey] for a key as the user typed or pasted it — the shape
/// a pairing screen's text field hands over. See [parseOuraKey].
Future<String?> pairOuraRingWithTypedKey(BluetoothDevice device, String raw) {
  final draft = parseOuraKeys(raw);
  if (draft.isEmpty) {
    // Counts, never the characters. A key that fails to parse is refused before
    // any radio work, so saying so here is what distinguishes it from a key the
    // ring rejected.
    debugPrint('[oura pair] nothing in the key field parsed — '
        '${draft.malformed} line(s) of ${raw.trim().length} character(s), '
        'need 32 hex or 24 base64 each');
    return Future.value(draft.malformed > 1
        ? 'None of those lines is a ring key. Each one needs to be 32 hex '
            'digits, or the 24-character base64 form, on its own line.'
        : 'That is not a ring key. Paste 32 hex digits, or the '
            '24-character base64 form, with nothing else around it.');
  }
  debugPrint('[oura pair] key field parsed to ${draft.keys.length} '
      'candidate key(s) of 16 bytes'
      '${draft.malformed > 0 ? ", ${draft.malformed} unparseable line(s) "
          "skipped" : ""}'
      '${draft.overflow > 0 ? ", ${draft.overflow} beyond the "
          "$kOuraMaxCandidateKeys-key limit not tried" : ""}');
  return _pairOuraRing(
    device,
    existingKeys: draft.keys,
    skipped: draft.malformed,
    overflow: draft.overflow,
  );
}

/// [existingKeys] null = the install path with one freshly minted key;
/// otherwise the candidates to try, in order, one connection each.
///
/// [skipped] and [overflow] are what the field parse threw away, carried here
/// only so the exhausted message can admit to them — a user told "none of your
/// 2 keys matched" when they pasted 4 lines is being told something false.
Future<String?> _pairOuraRing(
  BluetoothDevice device, {
  required List<List<int>>? existingKeys,
  int skipped = 0,
  int overflow = 0,
}) async {
  final rnd = Random.secure();
  final install = existingKeys == null;
  final keys = existingKeys ??
      [List<int>.unmodifiable(List<int>.generate(16, (_) => rnd.nextInt(256)))];
  // Which of the two pairings this is, said out loud at the top. They have
  // opposite preconditions on the ring and opposite remedies when they fail,
  // and every failure below reads the same either way.
  debugPrint(install
      ? '[oura pair] INSTALL path: minting a fresh 16-byte key. Needs a '
          'factory-reset ring.'
      : '[oura pair] EXISTING-KEY path: trying ${keys.length} key(s) supplied '
          'by the user, one connection each. No key is written to the ring.');
  // REUSE THE RING ROW'S ID, and mint only when there is no row to reuse. A
  // device_id is the storage key for `decoded_onehz`, `raw_archive` and every
  // `sync_cursor` item (`oura_cursor_ds:`, `oura_anchor:`, `counter_hw:`,
  // `rec_ts_hw:`), so minting a fresh one on every pairing forks one physical
  // ring into N identities: the re-paired ring drains from a zero cursor and
  // everything the previous pairing banked is orphaned under an id nothing
  // reads. [OuraLink.pairedRingRow] is the SAME single-ring lookup `sync()`
  // resolves against, so reusing its id is precisely what makes a re-pair
  // reconcile with the earlier data instead of starting beside it.
  //
  // NOT the BLE remote id, deliberately — see `HrsLink.pairedSensorRow`'s
  // header: a remote id is a per-app CBPeripheral UUID on iOS and a rotating
  // RPA on Android, which is the fragmentation this minted id exists to avoid.
  // `remote_id` is the column allowed to change under a stable row.
  final priorRow = await OuraLink.pairedRingRow();
  final reusedId = ouraReusableDeviceId(priorRow);
  final deviceId = reusedId ??
      'oura-${_hex(List<int>.generate(4, (_) => rnd.nextInt(256)))}';
  // A different remote id may be a different ring. The id is still reused (one
  // ring slot), but its ring-clock bookmark and anchor are not carried over —
  // see `_cursorItem`'s doc.
  final sameRing = priorRow?['remote_id'] == device.remoteId.str;
  // What the keychain held for [deviceId] before this attempt touched it. Only
  // meaningful when an id is being reused: the key is stored BEFORE the ring
  // has proved it (see the write below), so a failed re-pair would otherwise
  // leave this attempt's unproven key sitting where the working one was — a
  // pairing broken past recovery by anything short of another factory reset.
  // NOT `_readKey`: that swallows a locked keychain as "no key", and a read
  // that failed must stop here, before the write below overwrites a key this
  // run could not see.
  List<int>? priorKey;
  if (reusedId != null) {
    try {
      final hex = await _secure.read(
        key: _keyItem(reusedId),
        iOptions: _kApple,
        mOptions: _kMacos,
      );
      priorKey = hex == null ? null : _unhex(hex);
    } catch (e) {
      debugPrint('[oura pair] the keychain was unavailable: $e');
      return 'The phone’s keychain is locked. Unlock the phone and try again.';
    }
  }
  // Set once the ring acknowledged the new key. From then on the ring holds
  // it and not the old one, so the old key is worth nothing to restore.
  var keyInstalled = false;
  // Set true only on the one path that writes the `device` row. Every OTHER
  // exit — a refused command, a silent ring, a caught exception, even the
  // early `missingCharacteristics` return before the key is written at all —
  // leaves this false, and the `finally` below restores the keychain to what
  // it held before, so a failed pairing never outlives itself as an orphaned
  // secret with no row pointing at it.
  var paired = false;
  try {
    // A cap on concurrent SECONDARY links (never the band's own connect —
    // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). This pairing
    // flow's connect and disconnect both complete inside this one call, so
    // the simple scoped form is correct here.
    //
    // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately. Held in the outer
    // `finally` it ran AFTER the slot had already been released, so the next
    // queued link could connect while this one was still disconnecting — one
    // more live GATT link than the cap allows.
    //
    // AND THE WAIT IS BOUNDED, unlike every other caller's. A person is
    // holding the ring against the phone with a spinner in front of them; the
    // queue is FIFO behind whatever is already connected (an Oura offload can
    // run for minutes), so an unbounded wait here is a pairing screen that
    // never answers. 30 s is longer than a connect+discovery and shorter than
    // anyone's patience.
    // THE SLOT IS HELD ACROSS THE WHOLE TRIAL, not re-queued per candidate. A
    // key trial is one pairing operation from the user's side; releasing the
    // slot between candidates would let another sensor's link in and put the
    // next candidate back at the end of a FIFO queue, so a five-key trial could
    // wait out the 30 s timeout four more times and report a key verdict it
    // never actually obtained.
    return await withSecondaryLinkSlot<String?>(
      timeout: const Duration(seconds: 30),
      onTimeout: () => 'Another sensor is using this phone’s Bluetooth right '
          'now. Try pairing again in a moment.',
      () async {
        for (var i = 0; i < keys.length; i++) {
          final key = keys[i];
          if (keys.length > 1) {
            debugPrint('[oura pair] candidate ${i + 1} of ${keys.length}');
          }
          // Per candidate, so the teardown below cannot close the NEXT
          // candidate's link.
          GattBandLink? link;
          // ONE CONNECTION PER CANDIDATE — see pairOuraRingWithKeys. The
          // teardown is inside the loop, not an outer `finally`: the next
          // candidate's connect must not start while this link is still
          // closing, which is the same ordering the slot comment below cares
          // about one level up.
          try {
            // NOT a key verdict: Bluetooth being off says nothing about any
            // candidate, so it ends the trial and is reported as itself rather
            // than being retried against the remaining keys.
            if (!await _awaitAdapterOn()) {
              return 'Bluetooth is off. Turn it on and try again.';
            }
            await device.connect(timeout: const Duration(seconds: 20));
            final services = await device.discoverServices();
            final localLink = GattBandLink(
              entry: kOura,
              services: services,
              onLog: (m) => debugPrint('[oura pair] $m'),
            );
            // Captured var, so this candidate's `finally` can still close it
            // when the handshake below throws.
            link = localLink;
            final missing = localLink
                .missingCharacteristics(kOura.requiredCharacteristics);
            if (missing.isNotEmpty) {
              // Not a key verdict and not worth four more connections: the
              // device is the wrong device whatever key comes next.
              return 'That device does not expose the ring service this app '
                  'speaks.';
            }

            // THE KEY IS STORED BEFORE IT IS SENT, on the INSTALL path only,
            // and the order is deliberate there. A crash between the write and
            // the store leaves the ring holding a key this phone does not have
            // — unrecoverable except by another factory reset, the one cost in
            // this flow the user cannot undo. A stored key with no ring behind
            // it costs nothing: `sync()` never looks at it, because there is no
            // `device` row pointing to it yet.
            //
            // THAT REASONING DOES NOT APPLY TO A CANDIDATE. Nothing is written
            // to the ring on this path, so the ring can never end up holding a
            // key the phone lost, and storing each candidate before trying it
            // would put up to five secrets in the keychain to prove one. The
            // winner is stored below instead.
            if (install) {
              await _secure.write(
                key: _keyItem(deviceId),
                value: _hex(key),
                iOptions: _kApple,
                mOptions: _kMacos,
              );
            }
            final attempt = await ouraPairHandshake(
              localLink,
              key,
              install: install,
              onKeyInstalled: () => keyInstalled = true,
            );
            if (!attempt.ok) {
              // A ring that stopped answering is not a verdict on this key, so
              // it ends the trial and is reported as itself. Burying it under
              // the remaining candidates would turn a flat battery into "none
              // of your keys is right".
              if (!attempt.keyRejected) return attempt.refusal;
              if (i + 1 < keys.length) continue;
              return _exhausted(keys.length, attempt.refusal!,
                  skipped: skipped, overflow: overflow);
            }

            if (!install) {
              // The winner, and only now — see the note above.
              await _secure.write(
                key: _keyItem(deviceId),
                value: _hex(key),
                iOptions: _kApple,
                mOptions: _kMacos,
              );
            }
            if (keys.length > 1) {
              debugPrint('[oura pair] candidate ${i + 1} of ${keys.length} was '
                  'accepted; it is the one stored');
            }
            // The `device` row LAST, because it is what makes the ring
            // reachable: a row that exists is a ring `sync()` will try to
            // drain, so it is only written once the key is stored AND the ring
            // has proved it accepts it.
            //
            // A reused id on what may be a different ring drops the old ring's
            // decisecond bookmark and anchor first: another ring's counter is
            // not this one's, and a stale origin would stamp its seconds wrong.
            // Same reset the stranded path runs; costs one full re-read.
            if (reusedId != null && !sameRing) {
              await LocalDb.deleteCursor(_anchorItem(deviceId));
              await LocalDb.deleteCursor(_cursorItem(deviceId));
            }
            await LocalDb.upsertDevice(
              id: deviceId,
              adapterId: kOura.id,
              remoteId: device.remoteId.str,
              // Same filter the notify-class pairing path runs the advertised
              // name through — the device list renders this column assuming it
              // was cleaned here, and an unfiltered ring name would be the one
              // row that was not.
              label: cleanDeviceLabel(device.platformName) ?? kOura.label,
              // `tier` is left unset on purpose. It means MEASUREMENT QUALITY
              // and it is what decides precedence between two sources — and
              // this ring supplies no signal at all today
              // (`OuraAdapter.signals` is `const {}`), so there is no quality
              // to rank. NULL is a refusal, not a default.
            );
            paired = true;
            return null;
          } finally {
            link?.close();
            try {
              await device.disconnect();
            } catch (_) {/* already gone */}
          }
        }
        // Unreachable: the loop returns on every path, and `keys` is non-empty
        // by construction in both callers.
        return 'No key to try.';
      },
    );
  } catch (e) {
    debugPrint('[oura pair] failed: $e');
    return 'Could not connect to that ring.';
  } finally {
    // Touches no radio, so it stays outside the slot.
    //
    // A FRESHLY MINTED id's key is an orphan once pairing failed — nothing
    // points at it and nothing ever will, so it goes. A REUSED id's key is the
    // one the working pairing still depends on, and this attempt overwrote it
    // before the ring proved anything, so it is put back (or dropped, when
    // there was none to put back). Once the ring acknowledged the new key, a
    // reused id keeps it: the ring answers to nothing else now, and the row
    // already points here.
    if (!paired && !(reusedId != null && keyInstalled)) {
      if (priorKey == null) {
        await OuraLink._dropKey(deviceId);
      } else {
        try {
          await _secure.write(
            key: _keyItem(deviceId),
            value: _hex(priorKey),
            iOptions: _kApple,
            mOptions: _kMacos,
          );
        } catch (e) {
          debugPrint('[oura pair] could not restore the prior key: $e');
        }
      }
    }
  }
}
