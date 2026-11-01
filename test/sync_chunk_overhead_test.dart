// Band-sync per-chunk overhead (design: edge.research/design-sync-throughput.md).
//
// Each ACK-gating commit sets synchronous=FULL, reads it back, and restores
// NORMAL in finally. An active offload leaves the connection at NORMAL between
// chunks. Capture freshness shares the rows + cursor transaction; the two
// post-ACK ledger upserts share one separate transaction. Each completed chunk
// logs its counts and commit, ACK and post-ACK timings.
//
// AGENTS.md invariant 1: rows + cursor commit BEFORE the verbatim token is
// echoed; a failed commit or incomplete burst produces no ACK.
//
// Layout:
//   A. LocalDb.commitSyncBatch durability and transactional freshness (2-3).
//   B. The engine's HISTORY_END path over a real database (2g, 4-6), including
//      a FULL/read-back/commit/NORMAL bracket for every chunk during an offload.
//
// The sqflite logger sees every call LocalDb makes, extending the SQL spy in
// ack_commit_sync_full_test.dart. Calls made outside a transaction carry
// no transactionId; that is how "one transaction" is told from "N autocommits".

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── call log ────────────────────────────────────────────────────────────────

/// One thing that happened, in order: either a sqflite call or a marker the
/// test dropped in ('ack', 'commit-start', 'commit-end').
class _Ev {
  final String? method; // null for a marker
  final List<String> sql;
  final Object? txId;
  final String mark;
  _Ev.call(this.method, this.sql, this.txId) : mark = '';
  _Ev.mark(this.mark) : method = null, sql = const [], txId = null;

  bool touches(String table) {
    final re = RegExp('\\b$table\\b');
    return sql.any(re.hasMatch);
  }

  bool get isWrite => sql.any(
        (s) => RegExp(r'^\s*(INSERT|UPDATE|DELETE|REPLACE)\b', caseSensitive: false)
            .hasMatch(s),
      );

  bool get isSynchronousPragma =>
      sql.any((s) => RegExp(r'pragma\s+synchronous', caseSensitive: false).hasMatch(s));

  bool sqlIs(String re) =>
      sql.any((s) => RegExp(re, caseSensitive: false).hasMatch(s));
}

final _log = <_Ev>[];
var _counting = false;

void _mark(String m) {
  if (_counting) _log.add(_Ev.mark(m));
}

/// Every SQL string one sqflite call carries (a batch carries one per op).
Iterable<String> _sqlOf(Object? args) sync* {
  if (args is Map) {
    final sql = args['sql'];
    if (sql is String) yield sql;
    for (final v in args.values) {
      if (v is List || v is Map) yield* _sqlOf(v);
    }
  } else if (args is List) {
    for (final v in args) {
      yield* _sqlOf(v);
    }
  }
}

/// How many separate commits the writes to [table] in [events] cost: every
/// autocommit write is one, and every transaction holding a write is one.
/// Reads do not count; a batch outside a transaction is one call.
int _commitsTouching(Iterable<_Ev> events, String table) {
  var autocommit = 0;
  final txns = <Object>{};
  for (final e in events) {
    if (e.method == null || !e.touches(table) || !e.isWrite) continue;
    if (e.txId == null) {
      autocommit++;
    } else {
      txns.add(e.txId!);
    }
  }
  return autocommit + txns.length;
}

// ── fixtures ────────────────────────────────────────────────────────────────

const _t0 = 1780000000;

String _hex(int counter) => '2f18${counter.toRadixString(16).padLeft(8, '0')}';

RawRecord _raw(int counter) => RawRecord(
      counter: counter,
      packetType: 0x2f,
      hex: _hex(counter),
      capturedAt: (_t0 + counter) * 1000,
      recTs: _t0 + counter,
    );

Sample _sample(int counter) =>
    Sample(tsEpoch: _t0 + counter, counter: counter, hr: 60);

/// `n` consecutive records starting at counter `from`.
(List<RawRecord>, List<Sample?>) _records(int from, int n) => (
      [for (var i = 0; i < n; i++) _raw(from + i)],
      <Sample?>[for (var i = 0; i < n; i++) _sample(from + i)],
    );

Future<void> _commit(int from, int n, {String? token}) {
  final (raws, samples) = _records(from, n);
  return LocalDb.commitSyncBatch(raws, samples, trimToken: token);
}

late String _dbDir;

Future<Database> _freshLocal() async {
  await LocalDb.close();
  await databaseFactory.deleteDatabase(p.join(_dbDir, LocalDb.dbName));
  SharedPreferences.setMockInitialValues({});
  return LocalDb.instance;
}

/// `PRAGMA synchronous` as the connection reports it now: 2 FULL, 1 NORMAL.
Future<int?> _syncLevel() async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery('PRAGMA synchronous');
  final v = rows.isEmpty ? null : rows.first.values.firstOrNull;
  return v is num ? v.toInt() : null;
}

Future<int> _count(String table, [String where = '1=1']) async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT COUNT(*) AS c FROM $table WHERE $where');
  return (r.first['c'] as num).toInt();
}

// ── engine rig (B) ──────────────────────────────────────────────────────────

int _wallNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _historyStart() =>
    Uint8List.fromList(<int>[PacketType.metadata, 0x01, SyncMeta.historyStart]);

Uint8List _historyEnd({required int expected, required int token}) {
  final inner = Uint8List(24);
  inner[0] = PacketType.metadata;
  inner[1] = 0x02;
  inner[2] = SyncMeta.historyEnd;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 1786000000, Endian.little);
  v.setUint32(9, expected, Endian.little);
  v.setUint32(13, token, Endian.little);
  v.setUint32(17, 0x18, Endian.little);
  return inner;
}

Uint8List _gen5V18Inner({required int ts, required int counter}) {
  final inner = Uint8List(kGen5V18InnerLen);
  final v = ByteData.sublistView(inner);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, ts, Endian.little);
  inner[14] = 64;
  v.setFloat32(33, 0.5, Endian.little);
  v.setFloat32(45, 1.0, Endian.little);
  return inner;
}

/// The same fake gen5 link history_task_safety_test.dart uses, but its commit
/// sink is the REAL `LocalDb.commitSyncBatch`, so the call log sees the
/// commit, the ACK write and the post-ACK ledger writes in one timeline.
class _Rig {
  final logs = <String>[];
  final acks = <List<int>>[]; // body of each success result, in order
  late final BleEngine engine;

  _Rig() {
    _rigs.add(this);
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {}, log: logs.add);
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      onCommit: (raws, samples, token,
          {archives, ecgRawPackets, deviceFamily}) async {
        _mark('commit-start');
        await LocalDb.commitSyncBatch(
          raws,
          samples,
          trimToken: token,
          archives: archives,
          ecgRawPackets: ecgRawPackets,
          deviceFamily: deviceFamily,
        );
        _mark('commit-end');
      },
      onWrite: (f) async {
        final parsed = parseFrame(f, profile: BandProfile.gen5);
        if (parsed == null || !parsed.valid) return true;
        final opcode = parsed.inner[2];
        final body = parsed.inner.sublist(3);
        if (opcode == Cmd.getClock) {
          final seq = parsed.inner[1];
          scheduleMicrotask(() => engine.debugAbsorbDecoded(Decoded(
                'cmd_response',
                {
                  'opcode': Cmd.getClock,
                  'req_seq': seq,
                  'cmd_status': 1,
                  'clock_epoch': _wallNow(),
                },
              )));
        }
        if (opcode == Cmd.historicalDataResult &&
            body.isNotEmpty &&
            body[0] == 0x01) {
          acks.add(body);
          _mark('ack');
        }
        return true;
      },
    );
  }

  void rx(Uint8List inner) =>
      engine.debugReceiveFrame(Frame(inner, true, true), role: 'data');

  /// One full burst: [n] records, then the marker for [token].
  void chunk(int n, int token, {required int ts, required int counter}) {
    for (var i = 0; i < n; i++) {
      rx(_gen5V18Inner(ts: ts + i, counter: counter + i));
    }
    rx(_historyEnd(expected: n, token: token));
  }

  /// Wait for the real receive queue, then for the logs to stop growing.
  /// A quiet log alone could mean an ffi transaction is still in flight.
  Future<void> settle() async {
    var last = -1;
    var stable = 0;
    for (var i = 0; i < 200 && stable < 4; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final now = _log.length + logs.length;
      final snapshot = engine.offloadSnapshot;
      final idle = snapshot['queue_draining'] == false &&
          snapshot['queued_frames'] == 0;
      stable = idle && now == last ? stable + 1 : 0;
      last = now;
    }
    expect(stable, 4, reason: 'the real receive queue must finish before assertions');
  }
}

final _rigs = <_Rig>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    // The logger is the only public hook that sees every sqflite call.
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (e) {
          if (_counting && e is SqfliteLoggerInvokeEvent) {
            final args = e.arguments;
            _log.add(_Ev.call(
              e.method,
              _sqlOf(args).toList(),
              args is Map ? args['transactionId'] : null,
            ));
          }
        },
      ),
    );
    SharedPreferences.setMockInitialValues({});
    LocalDb.dbName = 'openstrap_sync_chunk_overhead_test.db';
    _dbDir = await databaseFactory.getDatabasesPath();
  });

  tearDownAll(() async {
    _counting = false;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(_dbDir, LocalDb.dbName));
  });

  setUp(() async {
    _counting = false;
    _log.clear();
    await _freshLocal();
  });

  tearDown(() async {
    _counting = false;
    for (final r in _rigs) {
      await r.engine.disconnect();
      await r.settle();
    }
    _rigs.clear();
  });

  group('A. commitSyncBatch round trips and durability', () {
    // 2. Durability is bracketed per commit, including failures.
    test('2b. a throwing commit restores NORMAL (1)', () async {
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER t_cursor_boom BEFORE INSERT ON sync_cursor '
          "WHEN NEW.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      _counting = true;
      await expectLater(_commit(1, 50, token: 't'), throwsA(anything));
      _counting = false;

      final full = _log.indexWhere(
          (e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*FULL'));
      final verify = _log.indexWhere(
          (e) => e.sqlIs(r'^\s*pragma\s+synchronous\s*;?\s*$'));
      final begin = _log.indexWhere((e) => e.sqlIs(r'^\s*BEGIN'));
      final rollback = _log.indexWhere((e) => e.sqlIs(r'^\s*ROLLBACK'));
      final normal = _log.indexWhere(
          (e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*NORMAL'));
      expect(full, isNonNegative);
      expect(verify, greaterThan(full));
      expect(begin, greaterThan(verify));
      expect(rollback, greaterThan(begin));
      expect(normal, greaterThan(rollback),
          reason: 'finally restores NORMAL after a failed transaction');
      expect(await _syncLevel(), 1);
      expect(await _count('samples'), 0);
    });

    test('2d. a commit runs at FULL and restores NORMAL after COMMIT', () async {
      _counting = true;
      await _commit(1, 50, token: 't');
      _counting = false;

      int idx(bool Function(_Ev) f) => _log.indexWhere(f);
      final full = idx((e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*FULL'));
      final verify = idx(
          (e) => e.sqlIs(r'^\s*pragma\s+synchronous\s*;?\s*$'));
      final begin = idx((e) => e.sqlIs(r'^\s*BEGIN'));
      final commit = idx((e) => e.sqlIs(r'^\s*COMMIT'));
      final normal = idx((e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*NORMAL'));
      expect(full, isNonNegative);
      expect(verify, greaterThan(full));
      expect(begin, greaterThan(verify),
          reason: 'FULL is set and read back BEFORE the txn opens');
      expect(commit, greaterThan(begin));
      expect(normal, greaterThan(commit), reason: 'NORMAL restored after COMMIT');
      expect(await _syncLevel(), 1);
    });

    // 3. Freshness rides in the batch transaction.
    test('3a. a failing freshness write rolls the whole batch back '
        '(freshness is inside the transaction)', () async {
      final db = await LocalDb.instance;
      await db.execute(
          'CREATE TRIGGER t_fresh_boom BEFORE INSERT ON compute_freshness '
          "WHEN NEW.\"key\" = 'capture' BEGIN SELECT RAISE(ABORT, 'boom'); END");

      await expectLater(_commit(1, 50, token: 't'), throwsA(anything));

      expect(await _count('samples'), 0,
          reason: 'the rows must roll back with the freshness row; today the '
              'batch is already committed when freshness fails');
      expect(await _count('sync_cursor', "name = 'counter_hw'"), 0,
          reason: 'and so must the cursor');
      expect(await _count('compute_freshness', "\"key\" = 'capture'"), 0);
    });

    test('3b. a failing cursor write leaves neither rows nor freshness '
        '(guard: holds today, must stay)', () async {
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER t_cursor_boom BEFORE INSERT ON sync_cursor '
          "WHEN NEW.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'boom'); END");

      await expectLater(_commit(1, 50, token: 't'), throwsA(anything));

      expect(await _count('samples'), 0);
      expect(await _count('sync_cursor', "name = 'counter_hw'"), 0);
      expect(await _count('compute_freshness', "\"key\" = 'capture'"), 0);
    });

    test('3c. the capture-freshness select and write happen inside the batch '
        'transaction, not after it', () async {
      _counting = true;
      await _commit(1, 50, token: 't');
      _counting = false;

      final fresh = _log.where((e) => e.touches('compute_freshness')).toList();
      expect(fresh, isNotEmpty, reason: 'harness check: freshness is written');
      final outside = fresh.where((e) => e.txId == null).length;
      expect(outside, 0,
          reason: '$outside freshness call(s) ran outside the commit '
              'transaction (today: a select and an insert, 2 extra round trips)');
      final rows = _log.singleWhere((e) => e.touches('samples') && e.isWrite);
      final cursor = _log.where((e) => e.touches('sync_cursor') && e.isWrite);
      expect(rows.txId, isNotNull);
      expect(cursor, isNotEmpty);
      expect([...fresh, ...cursor].every((e) => e.txId == rows.txId), isTrue,
          reason: 'freshness, decoded rows and trim cursor share the SAME txn');
    });

    test('3d. the freshness row still carries the batch max record time '
        '(guard: holds today, must stay)', () async {
      await _commit(1, 50, token: 't');
      final row = await LocalDb.computeFreshness('capture');
      expect(row, isNotNull);
      expect(row!['payload_json'] as String,
          contains('"latest_raw_rec_ts":${_t0 + 50}'));
    });
  });

  group('B. HISTORY_END over a real database', () {
    final ts = _wallNow() - 3600;

    test('2g. EVERY commit during an offload has its own FULL bracket and '
        'leaves NORMAL between chunks', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      expect(await _syncLevel(), 1,
          reason: 'starting an offload must leave the connection at NORMAL');
      for (var i = 0; i < 3; i++) {
        _log.clear();
        _counting = true;
        r.rx(_historyStart());
        r.chunk(3, 0xB200 + i, ts: ts + i * 100, counter: 2000 + i * 100);
        await r.settle();
        _counting = false;

        expect(r.acks, hasLength(i + 1));
        expect(r.engine.offloadActive, isTrue,
            reason: 'the same offload remains active between chunks');
        expect(_log.where((e) => e.isSynchronousPragma), hasLength(3),
            reason: 'chunk $i sets FULL, reads it back, then restores NORMAL');
        final full = _log.indexWhere(
            (e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*FULL'));
        final verify = _log.indexWhere(
            (e) => e.sqlIs(r'^\s*pragma\s+synchronous\s*;?\s*$'));
        final begin = _log.indexWhere((e) => e.sqlIs(r'^\s*BEGIN'));
        final commit = _log.indexWhere((e) => e.sqlIs(r'^\s*COMMIT'));
        final normal = _log.indexWhere(
            (e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*NORMAL'));
        final ack = _log.indexWhere((e) => e.mark == 'ack');
        expect(full, isNonNegative);
        expect(verify, greaterThan(full));
        expect(begin, greaterThan(verify));
        expect(commit, greaterThan(begin));
        expect(normal, greaterThan(commit));
        expect(ack, greaterThan(normal));
        expect(await _syncLevel(), 1,
            reason: 'chunk $i must leave NORMAL for post-ACK writes and idle time');
      }
    });

    // 4. Ledger: one transaction per marker.
    test('4. the two post-ACK ledger upserts cost one commit, and both rows '
        'still land', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      await LocalDb.instance; // opened before counting: opening is not the cost
      _counting = true;
      r.rx(_historyStart());
      r.chunk(3, 0xB400, ts: ts, counter: 4000);
      await r.settle();
      _counting = false;

      expect(r.acks, hasLength(1), reason: 'harness check: the chunk was ACKed');
      final ackAt = _log.indexWhere((e) => e.mark == 'ack');
      expect(ackAt, isNonNegative);
      final after = _log.sublist(ackAt + 1);
      final commits = _commitsTouching(after, 'sync_ledger');
      expect(commits, 1,
          reason: 'one marker costs one ledger commit after the ACK; '
              'today it is $commits (two separate upserts)');

      // Same content as before: the 'capture' row and the per-token row.
      final ledger = await LocalDb.syncLedger();
      final capture = ledger.where((e) => e['chunk_id'] == 'capture').toList();
      expect(capture, hasLength(1));
      expect(capture.single['status'], 'acknowledged');
      expect(capture.single['meta_json'] as String, contains('last_batch_token'));
      final tok = ledger.where((e) => (e['chunk_id'] as String).startsWith('batch:'));
      expect(tok, hasLength(1));
      expect(tok.single['status'], 'acked');
      expect(tok.single['meta_json'] as String, contains('"chunk_rows":3'));
    });

    // 5. Perf line.
    test('5. each HISTORY_END commit logs exactly one [perf] sync chunk line '
        'with per-chunk counts and timings', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      r.rx(_historyStart());
      r.chunk(3, 0xB500, ts: ts, counter: 5000);
      await r.settle();
      r.rx(_historyStart());
      r.chunk(2, 0xB501, ts: ts + 100, counter: 5100);
      await r.settle();

      expect(r.acks, hasLength(2), reason: 'harness check: both chunks ACKed');
      final lines = r.logs.where((l) => l.contains('[perf] sync chunk')).toList();
      expect(lines, hasLength(2),
          reason: 'one line per HISTORY_END, no more, no fewer; saw $lines');

      final re = RegExp(r'\brecords=(\d+)\b.*\bbeats=(\d+)\b.*\bcommit_ms=(\d+)\b'
          r'.*\back_ms=(\d+)\b.*\bpost_ms=(\d+)\b');
      for (final l in lines) {
        expect(re.hasMatch(l), isTrue,
            reason: 'line must carry records= beats= commit_ms= ack_ms= '
                'post_ms= in that order: $l');
      }
      // Per chunk, not cumulative for the connection.
      expect(re.firstMatch(lines[0])!.group(1), '3');
      expect(re.firstMatch(lines[1])!.group(1), '2');
    });

    // 6. Invariant guards (must pass today and stay green).
    test('6a. the ACK is written only after the commit completed, and echoes '
        'the verbatim token (guard)', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      _counting = true;
      r.rx(_historyStart());
      r.chunk(3, 0xB600, ts: ts, counter: 6000);
      await r.settle();
      _counting = false;

      final commitEnd = _log.indexWhere((e) => e.mark == 'commit-end');
      final txnCommit = _log.indexWhere((e) => e.sqlIs(r'^\s*COMMIT'));
      final ack = _log.indexWhere((e) => e.mark == 'ack');
      expect(commitEnd, isNonNegative);
      expect(txnCommit, isNonNegative);
      expect(ack, greaterThan(commitEnd),
          reason: 'ACK must follow commitSyncBatch returning');
      expect(ack, greaterThan(txnCommit));
      expect(r.acks.single.take(9).toList(), [
        0x01,
        0x00, 0xB6, 0x00, 0x00, // token u32 LE
        0x18, 0x00, 0x00, 0x00, // batch id u32 LE
      ]);
    });

    test('6b. a commit that throws produces no ACK and no acked ledger row '
        '(guard)', () async {
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER t_cursor_boom BEFORE INSERT ON sync_cursor '
          "WHEN NEW.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      r.rx(_historyStart());
      r.chunk(3, 0xB601, ts: ts, counter: 6100);
      await r.settle();

      expect(r.acks, isEmpty, reason: 'no ACK for a chunk that rolled back');
      expect(await _count('samples'), 0, reason: 'harness check: it rolled back');
      final ledger = await LocalDb.syncLedger();
      expect(
          ledger.where((e) => e['status'] == 'acked' || e['status'] == 'acknowledged'),
          isEmpty);
      expect(r.logs.where((l) => l.contains('[perf] sync chunk')), isEmpty,
          reason: 'a failed commit is not a completed chunk');
    });

    test('6c. an incomplete burst is neither committed nor ACKed (guard)',
        () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      _counting = true;
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 6200));
      r.rx(_historyEnd(expected: 3, token: 0xB602));
      await r.settle();
      _counting = false;

      expect(r.acks, isEmpty, reason: 'a partial chunk must never trim flash');
      // Upstream's count gate stores what arrived without the trim token
      // (_refuseHistoryEndOnShortCount), so only the cursor and ACK are pinned.
      expect(await LocalDb.getCursor('strap_trim'), isNull);
      final ledger = await LocalDb.syncLedger();
      expect(ledger.where(
          (e) => e['status'] == 'acked' || e['status'] == 'acknowledged'), isEmpty);
    });

  });
}
