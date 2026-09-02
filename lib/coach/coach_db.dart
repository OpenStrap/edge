// CoachDb — a READ-ONLY SQL layer the AI coach queries directly.
//
// The model emits raw SELECTs; we execute them against a SEPARATE read-only
// handle, over DERIVED-only views (v_metric/v_daily/v_series/v_hypnogram/
// v_sessions/v_baselines/v_insights — created by LocalDb._ensureCoachViews).
//
// THREE layers of safety, all fail-closed:
//
//   1. guardAndPrepare() — a static validator built on a real (small) SQL
//      lexer + table-reference parser, NOT a single regex. It is an
//      ALLOW-LIST: SELECT/WITH only, single statement, no comments, no
//      DML/DDL/PRAGMA, and EVERY table position (including the extra members
//      of a comma-separated implicit cross-join, which the old FROM/JOIN
//      regex never even looked at) must resolve to an allow-listed `v_*` view
//      or a CTE declared in the same statement. Anything else — a base table,
//      a schema-qualified name, sqlite_master/sqlite_schema, a table-valued
//      function, a subquery in FROM — is rejected because it is not on the
//      list, so a table added to the schema tomorrow is closed by default
//      instead of open by default.
//
//   2. _assertAllowedBtrees() — a STRUCTURAL check that does not trust the
//      parser at all. sqflite exposes no sqlite3_set_authorizer() hook and a
//      read-only handle still sees every table in the file, so we ask SQLite
//      itself which btrees a statement would open: `EXPLAIN <sql>` lists the
//      OpenRead/ReopenIdx opcodes with the ROOT PAGE of each btree, and
//      sqlite_master maps root pages back to the owning table. The allowed
//      root-page set is derived (once, at runtime) by EXPLAINing the allowed
//      views themselves, so it is exactly "the base tables the coach views
//      are made of" — every other btree in the database, including
//      workout_route (raw GPS) and sqlite_master, is unreachable no matter
//      what the text-level parser thinks. This is the authorizer we can't
//      install, implemented with the compiler's own answer.
//
//   3. A read-only Database handle (openDatabase readOnly:true) — even if
//      both layers above were bypassed, SQLite physically refuses writes/DDL.

import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// The ONLY relations the coach may name in a table position — derived,
  /// never raw. This is the whole allow-list: a CTE declared inside the same
  /// statement is the only other thing that may appear after FROM/JOIN.
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
    'into', 'load_extension', 'explain',
  };

  /// Real on-disk relations. This is NOT the security boundary any more (the
  /// allow-list above is) — it is a redundant net whose only jobs are to give
  /// the model a clearer rejection reason and to stop a CTE from SHADOWING a
  /// real table name. Anything missing from it is still rejected by the
  /// allow-list; nothing here is ever reachable.
  static const Set<String> reservedTableNames = {
    // derived / user tables
    'day_result', 'metric_series', 'baselines', 'derived_day', 'sessions',
    'notifications', 'journal', 'cycle_log', 'cycle_symptom', 'notif_fired',
    'sleep_override', 'sleep_session_candidates', 'wake_day_features',
    'workout_suggestions', 'workout_route', 'live_coverage',
    // raw / decoded substrate
    'raw_records', 'raw_archive', 'decoded_onehz', 'decoded_rr', 'samples',
    'events', 'band_events', 'band_battery',
    'device_coverage', 'signal_priority',
    // sync / compute bookkeeping
    'sync_ledger', 'sync_quarantine', 'sync_cursor', 'sync_ledger_legacy',
    'sync_quarantine_legacy', 'sync_cursor_legacy', 'compute_jobs',
    'compute_freshness',
    // sqlite internals (the sqlite_* prefix is rejected wholesale as well)
    'sqlite_master', 'sqlite_schema', 'sqlite_temp_master',
    'sqlite_temp_schema', 'sqlite_sequence', 'sqlite_stat1', 'dbstat',
  };

  /// Tokens that can follow a table reference without being an alias.
  static const Set<String> _clauseKeywords = {
    'where', 'group', 'order', 'limit', 'offset', 'having', 'window', 'union',
    'intersect', 'except', 'on', 'using', 'join', 'inner', 'left', 'right',
    'full', 'cross', 'natural', 'and', 'or', 'as', 'values', 'returning',
    'select', 'from', 'with',
  };

  static Database? _ro;
  static Set<int>? _allowedRoots;

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
    _allowedRoots = null;
  }

  // ── layer 1: lexer + table-reference parser ────────────────────────────────

  /// Validate + normalize an LLM-supplied SELECT. Throws [SqlGuardError] on any
  /// rejection. Returns the (possibly LIMIT-appended) query to execute.
  static String guardAndPrepare(String raw, {int rowCap = 200}) {
    var s = raw.trim();
    if (s.isEmpty) throw SqlGuardError('Empty query.');
    if (s.codeUnits.contains(0)) throw SqlGuardError('Illegal character.');

    // (a) Strip one optional trailing ';' before anything else, so the
    //     single-statement check below sees only genuine inner separators.
    var body = s.endsWith(';') ? s.substring(0, s.length - 1).trim() : s;
    if (body.isEmpty) throw SqlGuardError('Empty query.');

    // (b) Mask string literals to a neutral numeric token. Quoted IDENTIFIERS
    //     ("x", `x`, [x]) are rejected outright — the coach never needs them,
    //     and SQLite's double-quote fallback (a bare "foo" silently becomes a
    //     string when it doesn't resolve to a column) is a parser trap.
    final masked = _maskStrings(body);

    // (c) No comments (they can hide payloads) — checked on the MASKED text so
    //     an inline '--' inside a legitimate string value isn't a false hit.
    if (masked.contains('--') ||
        masked.contains('/*') ||
        masked.contains('*/')) {
      throw SqlGuardError('Comments are not allowed.');
    }
    // (d) Single statement.
    if (masked.contains(';')) {
      throw SqlGuardError('Only one statement is allowed.');
    }
    // (e) Must start with SELECT or WITH.
    final lower = masked.toLowerCase();
    if (!(lower.startsWith('select') || lower.startsWith('with'))) {
      throw SqlGuardError('Query must start with SELECT or WITH.');
    }

    final toks = _lex(lower);

    // (f) Banned keywords + reserved relation names, anywhere.
    for (final t in toks) {
      if (!t.ident) continue;
      if (_banned.contains(t.text)) {
        throw SqlGuardError('Disallowed keyword: ${t.text}');
      }
      if (t.text.startsWith('sqlite_') || t.text.startsWith('pragma_')) {
        throw SqlGuardError('SQLite internals are not queryable: ${t.text}');
      }
      if (reservedTableNames.contains(t.text)) {
        throw SqlGuardError('Table not allowed: ${t.text}. '
            'Allowed views: ${allowedViews.join(', ')}.');
      }
    }

    // (g) CTE names declared via `<name> AS (` become valid table targets.
    //     A CTE may not shadow an allowed view (that would silently redefine
    //     the coach's data surface) — shadowing a REAL table is already
    //     impossible because (f) rejects every reserved name outright.
    final cte = _cteNames(toks);
    for (final c in cte) {
      if (allowedViews.contains(c)) {
        throw SqlGuardError('A CTE may not shadow the view "$c".');
      }
    }

    // (h) THE allow-list gate: parse every table position and require it to be
    //     an allowed view or a declared CTE. Comma-separated cross-joins,
    //     subqueries in FROM, table-valued functions and schema-qualified
    //     names are all handled here (the old single-regex version only ever
    //     saw the identifier directly after FROM/JOIN).
    final refs = _tableRefs(toks, allowed: {...allowedViews, ...cte});
    if (refs.isEmpty) throw SqlGuardError('No table reference found.');

    // (i) Auto-append a LIMIT to protect context.
    if (!RegExp(r'\blimit\b', caseSensitive: false).hasMatch(lower)) {
      body = '$body LIMIT $rowCap';
    }
    return body;
  }

  /// Replace every single-quoted string literal with the neutral token `0`.
  /// Rejects unterminated literals and every quoted-identifier form.
  static String _maskStrings(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == "'") {
        i++;
        var closed = false;
        while (i < src.length) {
          if (src[i] == "'") {
            if (i + 1 < src.length && src[i + 1] == "'") {
              i += 2;
              continue;
            }
            i++;
            closed = true;
            break;
          }
          i++;
        }
        if (!closed) throw SqlGuardError('Unterminated string literal.');
        out.write('0');
        continue;
      }
      if (c == '"' || c == '`' || c == '[' || c == ']') {
        throw SqlGuardError(
            'Quoted identifiers are not allowed — use bare view names.');
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static List<_Tok> _lex(String s) {
    final out = <_Tok>[];
    var i = 0;
    bool identStart(String c) =>
        (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122) || c == '_';
    bool identPart(String c) =>
        identStart(c) || (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57);
    bool digit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
    while (i < s.length) {
      final c = s[i];
      if (c.trim().isEmpty) {
        i++;
        continue;
      }
      if (identStart(c)) {
        final st = i;
        while (i < s.length && identPart(s[i])) {
          i++;
        }
        out.add(_Tok(s.substring(st, i), true));
        continue;
      }
      if (digit(c)) {
        final st = i;
        while (i < s.length && (digit(s[i]) || s[i] == '.')) {
          i++;
        }
        out.add(_Tok(s.substring(st, i), false));
        continue;
      }
      out.add(_Tok(c, false));
      i++;
    }
    return out;
  }

  /// CTE names: an identifier preceded by `with`/`recursive`/`,` and followed
  /// (past an optional parenthesised column list) by `as (`.
  static Set<String> _cteNames(List<_Tok> toks) {
    final names = <String>{};
    for (var i = 1; i < toks.length; i++) {
      final prev = toks[i - 1];
      final t = toks[i];
      if (!t.ident) continue;
      final opensCte = (prev.ident && (prev.text == 'with' || prev.text == 'recursive')) ||
          (!prev.ident && prev.text == ',');
      if (!opensCte) continue;
      var j = i + 1;
      if (j < toks.length && !toks[j].ident && toks[j].text == '(') {
        j = _skipParens(toks, j);
      }
      if (j < toks.length && toks[j].ident && toks[j].text == 'as') {
        var k = j + 1;
        // AS [NOT] MATERIALIZED (
        while (k < toks.length &&
            toks[k].ident &&
            (toks[k].text == 'not' || toks[k].text == 'materialized')) {
          k++;
        }
        if (k < toks.length && !toks[k].ident && toks[k].text == '(') {
          names.add(t.text);
        }
      }
    }
    return names;
  }

  /// Index just past the balanced ')' that matches the '(' at [open].
  static int _skipParens(List<_Tok> toks, int open) {
    var depth = 0;
    for (var i = open; i < toks.length; i++) {
      if (toks[i].ident) continue;
      if (toks[i].text == '(') depth++;
      if (toks[i].text == ')') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return toks.length;
  }

  /// Every table position in the statement, validated against [allowed].
  /// Walks the FULL table-reference list after each FROM/JOIN — including the
  /// comma-separated members of an implicit cross-join.
  static List<String> _tableRefs(List<_Tok> toks, {required Set<String> allowed}) {
    final refs = <String>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (!t.ident || (t.text != 'from' && t.text != 'join')) continue;
      var j = i + 1;
      while (true) {
        if (j >= toks.length) {
          throw SqlGuardError('Malformed FROM clause.');
        }
        final n = toks[j];
        if (!n.ident) {
          if (n.text == '(') {
            throw SqlGuardError(
                'Subqueries in FROM are not allowed — query a view directly.');
          }
          throw SqlGuardError('Expected a view name after FROM/JOIN.');
        }
        final name = n.text;
        j++;
        // Schema-qualified (main.x / temp.x) or a table-valued function.
        if (j < toks.length && !toks[j].ident && toks[j].text == '.') {
          throw SqlGuardError('Schema-qualified names are not allowed: $name');
        }
        if (j < toks.length && !toks[j].ident && toks[j].text == '(') {
          throw SqlGuardError('Functions are not allowed in FROM: $name');
        }
        if (!allowed.contains(name)) {
          throw SqlGuardError(
              'Table "$name" is not queryable. Allowed views: '
              '${allowedViews.join(', ')}.');
        }
        refs.add(name);
        // Optional alias: `AS x` or a bare `x`.
        if (j < toks.length && toks[j].ident && toks[j].text == 'as') {
          j++;
          if (j >= toks.length || !toks[j].ident) {
            throw SqlGuardError('Malformed alias after "$name".');
          }
          j++;
        } else if (j < toks.length &&
            toks[j].ident &&
            !_clauseKeywords.contains(toks[j].text)) {
          j++;
        }
        // Another member of the same (comma-separated) table list?
        if (j < toks.length && !toks[j].ident && toks[j].text == ',') {
          j++;
          continue;
        }
        break;
      }
      i = j - 1;
    }
    return refs;
  }

  // ── layer 2: structural btree gate (SQLite's own answer) ───────────────────

  /// Root pages of every btree the ALLOWED VIEWS themselves read. Computed
  /// once per read-only handle by EXPLAINing `SELECT * FROM <view>`; SQLite
  /// expands the view and reports exactly which base tables/indexes it opens.
  static Future<Set<int>> _allowedRootPages(Database db) async {
    final cached = _allowedRoots;
    if (cached != null) return cached;
    final roots = <int>{};
    for (final v in allowedViews) {
      try {
        roots.addAll(await _btreeRoots(db, 'SELECT * FROM $v'));
      } catch (_) {/* a view that can't compile contributes nothing */}
    }
    // Indexes on an allowed base table are allowed too (the planner may pick
    // one for a WHERE the plain scan above never used).
    final schema = await db.rawQuery(
        'SELECT type, name, tbl_name, rootpage FROM sqlite_master');
    final tableOfRoot = <int, String>{};
    for (final r in schema) {
      final rp = (r['rootpage'] as num?)?.toInt();
      final tbl = r['tbl_name']?.toString();
      if (rp != null && rp > 0 && tbl != null) tableOfRoot[rp] = tbl;
    }
    final allowedTables = <String>{
      for (final rp in roots)
        if (tableOfRoot[rp] != null) tableOfRoot[rp]!,
    };
    for (final e in tableOfRoot.entries) {
      if (allowedTables.contains(e.value)) roots.add(e.key);
    }
    _allowedRoots = roots;
    return roots;
  }

  /// Root pages of every btree a prepared [sql] opens, per SQLite's own
  /// bytecode. Only cursor-opening opcodes carry a root page in P2 —
  /// OpenEphemeral/SorterOpen/OpenPseudo reuse P2 for a column count and are
  /// deliberately ignored.
  static Future<Set<int>> _btreeRoots(Database db, String sql) async {
    const opening = {'OpenRead', 'OpenWrite', 'ReopenIdx'};
    final rows = await db.rawQuery('EXPLAIN $sql');
    final out = <int>{};
    for (final r in rows) {
      final op = r['opcode']?.toString();
      if (op == null || !opening.contains(op)) continue;
      final p2 = (r['p2'] as num?)?.toInt();
      if (p2 != null && p2 > 0) out.add(p2);
    }
    return out;
  }

  /// Fail-closed structural gate: reject unless every btree the statement
  /// opens belongs to a base table one of the allowed views is built from.
  static Future<void> _assertAllowedBtrees(Database db, String sql) async {
    final allowed = await _allowedRootPages(db);
    if (allowed.isEmpty) {
      throw SqlGuardError('Query surface unavailable.');
    }
    final Set<int> used;
    try {
      used = await _btreeRoots(db, sql);
    } catch (e) {
      throw SqlGuardError('Query could not be compiled: $e');
    }
    for (final r in used) {
      if (!allowed.contains(r)) {
        throw SqlGuardError('Query reaches storage outside the coach views. '
            'Allowed views: ${allowedViews.join(', ')}.');
      }
    }
  }

  /// Test seam for layer 2 on its own (layer 1 normally rejects these first).
  @visibleForTesting
  static Future<void> debugAssertAllowedBtrees(String sql) async =>
      _assertAllowedBtrees(await _readonly(), sql);

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
      await _assertAllowedBtrees(db, sql);
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
    } on SqlGuardError catch (e) {
      return jsonEncode({'error': e.reason});
    } catch (e) {
      return jsonEncode({'error': 'Query failed: $e'});
    }
  }
}

class _Tok {
  final String text;
  final bool ident;
  const _Tok(this.text, this.ident);
}
