// CoachDb — a READ-ONLY SQL layer the AI coach queries directly.
//
// The model emits raw SELECTs; we execute them against a SEPARATE read-only
// handle, over DERIVED-only views (v_metric/v_daily/v_series/v_hypnogram/
// v_sessions/v_baselines/v_insights — created by LocalDb._ensureCoachViews).
//
// Two layers of safety, both fail-closed:
//   1. guardAndPrepare() — a static validator: SELECT/WITH only, single
//      statement, no comments, no DML/DDL/PRAGMA, every FROM/JOIN target must be
//      an allow-listed view, no base/raw table name anywhere, auto-LIMIT.
//   2. A read-only Database handle (openDatabase readOnly:true) — even if the
//      guard were bypassed, SQLite physically refuses writes/DDL, and raw byte
//      tables are blocked by the guard's identifier allow-list.

import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/db.dart';

/// Thrown by [CoachDb.guardAndPrepare] when a query is rejected. The reason is
/// surfaced back to the model so it can self-correct.
class SqlGuardError implements Exception {
  final String reason;
  SqlGuardError(this.reason);
  @override
  String toString() => reason;
}

class CoachDb {
  CoachDb._();

  /// The only tables the coach may read — derived, never raw.
  static const Set<String> allowedViews = {
    'v_metric',
    'v_daily',
    'v_series',
    'v_hypnogram',
    'v_sessions',
    'v_baselines',
    'v_insights',
  };

  // Keywords that must never appear as standalone tokens (anything mutating or
  // schema-touching). SELECT/WITH/FROM/JOIN/WHERE/etc. are fine and not listed.
  static const Set<String> _banned = {
    'insert', 'update', 'delete', 'drop', 'alter', 'create', 'replace',
    'truncate', 'attach', 'detach', 'pragma', 'vacuum', 'reindex', 'analyze',
    'begin', 'commit', 'rollback', 'savepoint', 'grant', 'revoke', 'trigger',
    'into', 'load_extension',
  };

  // Base/raw table names that must NOT appear anywhere (force the views).
  static const Set<String> _denyTables = {
    'raw_records', 'decoded_onehz', 'decoded_rr', 'samples', 'sqlite_master',
    'day_result', 'metric_series', 'baselines', 'sessions', 'notifications',
    'derived_day', 'events', 'band_events', 'band_battery', 'live_coverage',
    'sync_ledger', 'sync_quarantine', 'sync_cursor', 'compute_jobs',
    'compute_freshness', 'journal', 'cycle_log', 'cycle_symptom',
    'primitive_artifacts', 'wake_day_features', 'workout_suggestions',
  };

  static Database? _ro;

  /// Open (and cache) a read-only handle. Ensures the RW handle first so the
  /// views exist (a read-only handle can't CREATE VIEW).
  static Future<Database> _readonly() async {
    if (_ro != null) return _ro!;
    await LocalDb.instance; // creates/repairs schema + views on the RW handle
    final dir = await getDatabasesPath();
    _ro = await openDatabase(p.join(dir, LocalDb.dbName), readOnly: true);
    return _ro!;
  }

  static Future<void> close() async {
    await _ro?.close();
    _ro = null;
  }

  /// Validate + normalize an LLM-supplied SELECT. Throws [SqlGuardError] on any
  /// rejection. Returns the (possibly LIMIT-appended) query to execute.
  static String guardAndPrepare(String raw, {int rowCap = 200}) {
    var s = raw.trim();
    if (s.isEmpty) throw SqlGuardError('Empty query.');

    // (a) No comments (they can hide payloads).
    if (s.contains('--') || s.contains('/*') || s.contains('*/')) {
      throw SqlGuardError('Comments are not allowed.');
    }
    // (b) Single statement — strip one optional trailing ';', reject any inner.
    var body = s.endsWith(';') ? s.substring(0, s.length - 1).trim() : s;
    if (body.contains(';')) {
      throw SqlGuardError('Only one statement is allowed.');
    }
    // (c) Must start with SELECT or WITH.
    final lower = body.toLowerCase();
    if (!(lower.startsWith('select') || lower.startsWith('with'))) {
      throw SqlGuardError('Query must start with SELECT or WITH.');
    }
    // (d) Tokenize; reject any banned keyword + collect identifiers.
    final tokens = RegExp(r'[A-Za-z_][A-Za-z0-9_]*')
        .allMatches(lower)
        .map((m) => m.group(0)!)
        .toList();
    for (final t in tokens) {
      if (_banned.contains(t)) throw SqlGuardError('Disallowed keyword: $t');
      if (_denyTables.contains(t)) throw SqlGuardError('Table not allowed: $t');
    }
    // (e) CTE names declared via WITH … AS ( become valid FROM targets.
    final cte = <String>{};
    for (final m in RegExp(r'(?:with|,)\s+([A-Za-z_][A-Za-z0-9_]*)\s+as\s*\(',
            caseSensitive: false)
        .allMatches(lower)) {
      cte.add(m.group(1)!);
    }
    // (f) Every FROM/JOIN target must be an allowed view (or a CTE name).
    final refRe = RegExp(r'\b(?:from|join)\s+("?)([A-Za-z_][A-Za-z0-9_.]*)\1',
        caseSensitive: false);
    final refs = <String>[];
    for (final m in refRe.allMatches(lower)) {
      final id = m.group(2)!;
      if (id.contains('.')) {
        throw SqlGuardError('Schema-qualified names are not allowed: $id');
      }
      refs.add(id);
    }
    if (refs.isEmpty) throw SqlGuardError('No table reference found.');
    for (final r in refs) {
      if (!allowedViews.contains(r) && !cte.contains(r)) {
        throw SqlGuardError(
            'Table "$r" is not queryable. Allowed views: ${allowedViews.join(', ')}.');
      }
    }
    // (g) Auto-append a LIMIT to protect context.
    if (!RegExp(r'\blimit\b', caseSensitive: false).hasMatch(lower)) {
      body = '$body LIMIT $rowCap';
    }
    return body;
  }

  /// Run an LLM SELECT and return compact JSON for the tool result. On a guard
  /// rejection, returns the reason (so the model fixes its query) — never throws.
  static Future<String> runCoachSql(String llmSql, {int rowCap = 200}) async {
    String sql;
    try {
      sql = guardAndPrepare(llmSql, rowCap: rowCap);
    } on SqlGuardError catch (e) {
      return jsonEncode({'error': e.reason});
    }
    try {
      final db = await _readonly();
      final rows = await db.rawQuery(sql);
      final shown = rows.take(rowCap).toList();
      final out = <String, dynamic>{
        'columns': shown.isEmpty ? <String>[] : shown.first.keys.toList(),
        'rows': shown,
        'row_count': shown.length,
      };
      if (rows.length > rowCap) {
        out['note'] = 'Truncated to $rowCap of ${rows.length}+ rows. Add a '
            'tighter WHERE or aggregate (AVG/MIN/MAX/COUNT) instead of selecting '
            'all rows.';
      }
      var s = jsonEncode(out);
      if (s.length > 16000) s = '${s.substring(0, 16000)}…(truncated)';
      return s;
    } catch (e) {
      return jsonEncode({'error': 'Query failed: $e'});
    }
  }
}
