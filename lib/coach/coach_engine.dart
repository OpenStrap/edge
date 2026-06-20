// CoachEngine — the agentic core. Talks to an OpenAI-compatible provider directly
// (BYOK), runs a tool-calling loop over read-only data tools + a plot tool + action
// tools (writes require user confirmation), and streams items back to the UI.
//
// Data flow: user asks → model calls data tools (we hit the authed backend) → model
// reasons → optionally calls plot_chart with a figure it built → optionally proposes
// an action (we confirm with the user) → model returns the final text.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../net/api_client.dart';
import 'coach_config.dart';
import 'coach_prompt.dart';

// ── value types ──────────────────────────────────────────────────────────────

/// A figure the model built from data it fetched; the app renders it animated.
class ChartSpec {
  final String type; // 'bar' | 'line' | 'area'
  final String title;
  final List<String> xLabels;
  final List<ChartSeries> series;
  final String unit;
  final String? note;
  ChartSpec({
    required this.type,
    required this.title,
    required this.xLabels,
    required this.series,
    this.unit = '',
    this.note,
  });

  // Some OpenAI-compatible models (e.g. minimax via NVIDIA NIM) wrap array params
  // as {"item":[...]} and emit numbers as strings. Be liberal in what we accept.
  static List<dynamic> _asList(dynamic v) {
    if (v is List) return v;
    if (v is Map && v['item'] is List) return v['item'] as List;
    if (v is Map && v['items'] is List) return v['items'] as List;
    return const [];
  }

  static double? _asNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      final d = double.tryParse(v.trim());
      if (d != null) return d;
      // tolerate "62 ms", units glued on, etc. — take the first number found.
      final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
      return m == null ? null : double.tryParse(m.group(0)!);
    }
    if (v is Map) return _asNum(v['value'] ?? v['y'] ?? v['v']); // {value:62}/{y:62}
    return null;
  }

  Map<String, dynamic> toJson() => {
        'type': type, 'title': title, 'x_labels': xLabels, 'unit': unit, 'note': note,
        'series': series.map((s) => {'name': s.name, 'values': s.values}).toList(),
      };

  static ChartSpec? tryParse(Map<String, dynamic> j) {
    try {
      final rawSeries = _asList(j['series']);
      final series = rawSeries.whereType<Map>().map((s) {
        final vals = _asList(s['values'] ?? s['data'] ?? s['y']).map(_asNum).toList();
        return ChartSeries(name: (s['name'] ?? s['label'] ?? '').toString(), values: vals);
      }).where((s) => s.values.any((v) => v != null)).toList(); // drop all-null series
      if (series.isEmpty) return null;
      final xs = _asList(j['x_labels'] ?? j['labels'] ?? j['x']).map((e) => '$e').toList();
      return ChartSpec(
        type: (j['type'] ?? 'bar').toString(),
        title: (j['title'] ?? '').toString(),
        xLabels: xs,
        series: series,
        unit: (j['unit'] ?? j['y_unit'] ?? '').toString(),
        note: j['note']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

class ChartSeries {
  final String name;
  final List<double?> values;
  ChartSeries({required this.name, required this.values});
}

/// A write the model wants to perform — surfaced to the user for confirmation.
class ActionRequest {
  final String tool;
  final String title;     // e.g. "Log a period"
  final String summary;   // human description of exactly what will happen
  final Map<String, dynamic> args;
  ActionRequest({required this.tool, required this.title, required this.summary, required this.args});
}

/// One rendered chat item.
enum CoachItemKind { user, assistant, chart, error }

class CoachItem {
  final CoachItemKind kind;
  final String? text;
  final ChartSpec? chart;
  CoachItem.user(this.text) : kind = CoachItemKind.user, chart = null;
  CoachItem.assistant(this.text) : kind = CoachItemKind.assistant, chart = null;
  CoachItem.error(this.text) : kind = CoachItemKind.error, chart = null;
  CoachItem.chart(this.chart) : kind = CoachItemKind.chart, text = null;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'text': text, 'chart': chart?.toJson()};

  static CoachItem fromJson(Map<String, dynamic> j) {
    final k = j['kind'];
    if (k == 'chart' && j['chart'] is Map) {
      final c = ChartSpec.tryParse((j['chart'] as Map).cast<String, dynamic>());
      if (c != null) return CoachItem.chart(c);
    }
    final t = j['text']?.toString();
    if (k == 'user') return CoachItem.user(t);
    if (k == 'error') return CoachItem.error(t);
    return CoachItem.assistant(t);
  }
}

/// Lightweight index entry for a saved chat session (for the history list).
class CoachSessionMeta {
  final String id;
  final String title;
  final int updatedAt; // ms since epoch
  final String preview;
  CoachSessionMeta(this.id, this.title, this.updatedAt, this.preview);
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'updatedAt': updatedAt, 'preview': preview};
  static CoachSessionMeta fromJson(Map<String, dynamic> j) => CoachSessionMeta(
        (j['id'] ?? '').toString(), (j['title'] ?? '').toString(),
        (j['updatedAt'] as num?)?.toInt() ?? 0, (j['preview'] ?? '').toString());
}

// ── engine ───────────────────────────────────────────────────────────────────

class CoachEngine {
  final CoachConfig config;
  final ApiClient api;
  final String storageKey; // per-user, so accounts don't share a transcript
  final http.Client _http = http.Client();

  // OpenAI-format running history (system is added per-request) — the context we
  // resend every turn so the model remembers the conversation.
  final List<Map<String, dynamic>> _history = [];

  // Serializable display transcript (text bubbles + charts) shown in the UI.
  final List<CoachItem> transcript = [];

  // Current session identity (sessions are persisted per-user, many per user).
  String _sessionId = '';
  String _title = '';
  int _createdAt = 0;
  String get sessionId => _sessionId;

  final Random _rand = Random();
  static const List<String> _shenanigans = [
    'Reading your overnight RR…',
    'Doing the Banister math…',
    'Asking your heart rate a few questions…',
    'Reverse-engineering last night…',
    'Auditing 90 days of you…',
    'Letting the data confess…',
    'Lining up the z-scores…',
    'Chasing a hunch through your HRV…',
    'Pulling the thread…',
  ];

  CoachEngine({required this.config, required this.api, this.storageKey = 'anon'});

  void reset() { _history.clear(); transcript.clear(); }
  bool get hasHistory => _history.isNotEmpty;

  Future<Directory> _dir() => getApplicationDocumentsDirectory();
  Future<File> _sessionFile(String id) async => File('${(await _dir()).path}/coach_s_${storageKey}_$id.json');
  Future<File> _indexFile() async => File('${(await _dir()).path}/coach_idx_$storageKey.json');
  String _newId() => '${DateTime.now().millisecondsSinceEpoch}';

  /// All saved sessions for this user, most recent first.
  Future<List<CoachSessionMeta>> listSessions() async {
    try {
      final f = await _indexFile();
      if (!await f.exists()) return [];
      final list = (jsonDecode(await f.readAsString()) as List)
          .map((e) => CoachSessionMeta.fromJson((e as Map).cast<String, dynamic>())).toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    } catch (_) {
      return [];
    }
  }

  /// On open: resume the most recent session, or start fresh if none.
  Future<void> restore() async {
    final metas = await listSessions();
    if (metas.isEmpty) {
      newSession();
      return;
    }
    await openSession(metas.first.id);
  }

  /// Start a brand-new conversation (not written to disk until first message).
  void newSession() {
    _sessionId = _newId();
    _title = '';
    _createdAt = 0;
    _history.clear();
    transcript.clear();
  }

  /// Load a specific session into the working set.
  Future<void> openSession(String id) async {
    try {
      final f = await _sessionFile(id);
      if (!await f.exists()) {
        newSession();
        return;
      }
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _sessionId = id;
      _title = (j['title'] ?? '').toString();
      _createdAt = (j['createdAt'] as num?)?.toInt() ?? 0;
      _history
        ..clear()
        ..addAll(((j['history'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()));
      transcript
        ..clear()
        ..addAll(((j['transcript'] as List?) ?? const [])
            .map((e) => CoachItem.fromJson((e as Map).cast<String, dynamic>())));
    } catch (_) {
      newSession();
    }
  }

  /// Persist the current session (caps history, updates the index).
  Future<void> persist() async {
    if (transcript.isEmpty) return;
    if (_sessionId.isEmpty) _sessionId = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_createdAt == 0) _createdAt = now;
    if (_title.isEmpty) _title = _deriveTitle();
    if (_history.length > 60) _history.removeRange(0, _history.length - 60);
    try {
      final f = await _sessionFile(_sessionId);
      await f.writeAsString(jsonEncode({
        'title': _title, 'createdAt': _createdAt, 'updatedAt': now,
        'history': _history, 'transcript': transcript.map((e) => e.toJson()).toList(),
      }));
      await _updateIndex(_sessionId, _title, now, _preview());
    } catch (_) {}
  }

  Future<void> _updateIndex(String id, String title, int updatedAt, String preview) async {
    final metas = await listSessions();
    metas.removeWhere((m) => m.id == id);
    metas.insert(0, CoachSessionMeta(id, title, updatedAt, preview));
    final keep = metas.take(30).toList();
    for (final d in metas.skip(30)) {
      try {
        final f = await _sessionFile(d.id);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      final f = await _indexFile();
      await f.writeAsString(jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  /// Delete a session (and start fresh if it was the current one).
  Future<void> deleteSession(String id) async {
    try {
      final f = await _sessionFile(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final metas = await listSessions()..removeWhere((m) => m.id == id);
    try {
      final f = await _indexFile();
      await f.writeAsString(jsonEncode(metas.map((m) => m.toJson()).toList()));
    } catch (_) {}
    if (id == _sessionId) newSession();
  }

  String _deriveTitle() {
    for (final it in transcript) {
      if (it.kind == CoachItemKind.user && (it.text ?? '').trim().isNotEmpty) {
        final t = it.text!.trim();
        return t.length > 40 ? '${t.substring(0, 40)}…' : t;
      }
    }
    return 'New chat';
  }

  String _preview() {
    for (final it in transcript.reversed) {
      final t = it.text?.trim();
      if (t != null && t.isNotEmpty) return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
    return '';
  }

  /// Live model list from the provider's /models endpoint (OpenAI-compatible).
  /// Static so Settings can probe an as-yet-unsaved base URL + key.
  static Future<List<String>> fetchModels(String apiBase, String apiKey) async {
    var b = apiBase.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    final resp = await http.get(
      Uri.parse('$b/models'),
      headers: {'Authorization': 'Bearer $apiKey'},
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw CoachException('Models request failed (${resp.statusCode}): ${_short(resp.body)}');
    }
    final j = jsonDecode(resp.body);
    final data = (j['data'] as List?) ?? const [];
    final ids = data.map((e) => (e as Map)['id']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
    ids.sort();
    return ids;
  }

  static String _short(String s) => s.length > 200 ? s.substring(0, 200) : s;

  static String _today() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

  /// Run one user turn. Emits items via [onItem]; reports the current tool via
  /// [onStatus]; asks the user to confirm writes via [confirm] (returns true to
  /// proceed). Returns when the model produces its final answer (or hits the cap).
  Future<void> send(
    String userText, {
    required void Function(CoachItem) onItem,
    required void Function(String?) onStatus,
    required Future<bool> Function(ActionRequest) confirm,
  }) async {
    void emit(CoachItem it) { transcript.add(it); onItem(it); }
    emit(CoachItem.user(userText));
    _history.add({'role': 'user', 'content': userText});

    const maxIters = 10;
    for (var i = 0; i < maxIters; i++) {
      onStatus(_shenanigans[_rand.nextInt(_shenanigans.length)]);
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': '$kCoachSystemPrompt\n\nToday is ${_today()} (UTC).'},
        ..._history,
      ];

      final reply = await _chat(messages);
      final toolCalls = (reply['tool_calls'] as List?) ?? const [];
      final content = (reply['content'] as String?)?.trim();

      if (toolCalls.isEmpty) {
        if (content != null && content.isNotEmpty) emit(CoachItem.assistant(content));
        _history.add({'role': 'assistant', 'content': content ?? ''});
        onStatus(null);
        return;
      }

      // Assistant turn that requested tools (echo any interim text).
      if (content != null && content.isNotEmpty) emit(CoachItem.assistant(content));
      _history.add({'role': 'assistant', 'content': content ?? '', 'tool_calls': toolCalls});

      for (final tcRaw in toolCalls) {
        final tc = tcRaw as Map;
        final id = tc['id']?.toString() ?? '';
        final fn = (tc['function'] as Map?) ?? const {};
        final name = fn['name']?.toString() ?? '';
        Map<String, dynamic> args = {};
        try {
          final a = fn['arguments'];
          if (a is String && a.isNotEmpty) {
            args = jsonDecode(a) as Map<String, dynamic>;
          } else if (a is Map) {
            args = a.cast<String, dynamic>();
          }
        } catch (_) {}

        onStatus(_statusFor(name, args));
        final result = await _runTool(name, args, onItem: emit, confirm: confirm);
        _history.add({'role': 'tool', 'tool_call_id': id, 'name': name, 'content': result});
      }
    }
    emit(CoachItem.assistant('I dug through several steps but couldn’t wrap that up — try narrowing the question.'));
    onStatus(null);
  }

  // ── provider call ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _chat(List<Map<String, dynamic>> messages) async {
    final resp = await _http.post(
      Uri.parse('${config.apiBase}/chat/completions'),
      headers: {
        'Authorization': 'Bearer ${config.apiKey}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': config.model,
        'messages': messages,
        'tools': _toolDefs,
        'tool_choice': 'auto',
        'temperature': 0.3,
      }),
    ).timeout(const Duration(seconds: 120));
    if (resp.statusCode != 200) {
      throw CoachException('Provider error (${resp.statusCode}): ${_briefErr(resp.body)}');
    }
    final j = jsonDecode(utf8.decode(resp.bodyBytes));
    final choices = (j['choices'] as List?) ?? const [];
    if (choices.isEmpty) throw CoachException('Empty response from provider.');
    return (choices.first as Map)['message'] as Map<String, dynamic>;
  }

  String _briefErr(String body) {
    try {
      final j = jsonDecode(body);
      return (j['error']?['message'] ?? body).toString();
    } catch (_) {
      return body.length > 300 ? body.substring(0, 300) : body;
    }
  }

  // ── tool execution ───────────────────────────────────────────────────────────
  Future<String> _runTool(
    String name,
    Map<String, dynamic> args, {
    required void Function(CoachItem) onItem,
    required Future<bool> Function(ActionRequest) confirm,
  }) async {
    try {
      switch (name) {
        // reads
        case 'get_today':
          return _enc(await api.getToday());
        case 'get_trend':
          return _enc(await api.getTrend('${args['metric']}', scale: '${args['scale'] ?? 'week'}'));
        case 'get_day':
          return _enc(await _day('${args['kind']}', '${args['date']}'));
        case 'get_sleep_history':
          return _enc(await api.getSleep());
        case 'get_strain_history':
          return _enc(await api.getStrain());
        case 'get_sessions':
          return _enc(await api.getSessions());
        case 'get_workouts':
          return _enc(await api.getWorkouts(range: '${args['range'] ?? 'month'}'));
        case 'get_cycle':
          return _enc(await api.getCycle());
        case 'get_journal':
          return _enc(await api.getJournal(range: '${args['range'] ?? '30d'}'));
        case 'get_journal_insights':
          return _enc(await api.getJournalInsights(range: '${args['range'] ?? '90d'}'));
        case 'get_profile':
          return _enc(await api.getProfile());
        case 'get_records':
          return _enc(await api.getRecords());
        case 'get_history':
          return _enc(await api.getHistory(range: '${args['range'] ?? '30d'}'));

        // plot
        case 'plot_chart':
          final spec = ChartSpec.tryParse(args);
          if (spec == null) return 'Could not parse figure; check the schema.';
          onItem(CoachItem.chart(spec));
          return 'Chart rendered for the user.';

        // actions (confirmed)
        case 'log_journal':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log journal',
            summary: 'Add journal for ${args['date']}: tags ${args['tags'] ?? []}, note "${args['note'] ?? ''}".',
            args: args,
          ), () async {
            await api.postJournal('${args['date']}',
                ((args['tags'] as List?) ?? const []).map((e) => '$e').toList(), '${args['note'] ?? ''}');
            return 'Journal saved.';
          });
        case 'log_period':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log period',
            summary: 'Log a period start on ${args['date']}.', args: args,
          ), () async { await api.postCycleLog('${args['date']}', kind: 'start'); return 'Period logged.'; });
        case 'start_workout':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Start workout',
            summary: 'Start a ${args['type'] ?? 'workout'} session now.', args: args,
          ), () async { final r = await api.startWorkout('${args['type'] ?? 'other'}'); return _enc(r); });
        case 'end_workout':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'End workout',
            summary: 'End the active workout.', args: args,
          ), () async { final r = await api.endWorkout('${args['workout_id']}'); return _enc(r); });
        case 'set_step_goal':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Set step goal',
            summary: 'Set your daily step goal to ${args['goal']}.', args: args,
          ), () async { await api.setStepGoal((args['goal'] as num).toInt()); return 'Step goal updated.'; });

        default:
          return 'Unknown tool: $name';
      }
    } catch (e) {
      return 'Tool $name failed: ${e is ApiException ? e.body : e}';
    }
  }

  Future<String> _action(
    Future<bool> Function(ActionRequest) confirm,
    ActionRequest req,
    Future<String> Function() run,
  ) async {
    final ok = await confirm(req);
    if (!ok) return 'User declined the action. Do not retry it.';
    return await run();
  }

  Future<Map<String, dynamic>> _day(String kind, String date) {
    switch (kind) {
      case 'sleep': return api.getDaySleep(date);
      case 'strain': return api.getDayStrain(date);
      case 'stress': return api.getDayStress(date);
      case 'wear': return api.getDayWear(date);
      case 'timeline': return api.getDayTimeline(date);
      case 'lungs': return api.getDayLungs(date);
      case 'heart':
      default: return api.getDayHeart(date);
    }
  }

  String _enc(Object? data) {
    final s = jsonEncode(data);
    return s.length > 16000 ? '${s.substring(0, 16000)}…(truncated)' : s;
  }

  String _statusFor(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'get_today': return 'Reading today…';
      case 'get_trend': return 'Pulling ${args['metric']} trend…';
      case 'get_day': return 'Reading ${args['kind']} for ${args['date']}…';
      case 'get_sleep_history': return 'Reading sleep history…';
      case 'get_strain_history': return 'Reading strain history…';
      case 'get_sessions': return 'Reading workouts…';
      case 'get_workouts': return 'Reading workouts…';
      case 'get_cycle': return 'Reading cycle…';
      case 'get_journal': case 'get_journal_insights': return 'Reading journal…';
      case 'get_records': return 'Checking your records…';
      case 'plot_chart': return 'Plotting…';
      default: return 'Working…';
    }
  }

  void dispose() => _http.close();

  // ── tool schema (OpenAI format) ───────────────────────────────────────────────
  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> required = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  static final List<Map<String, dynamic>> _toolDefs = [
    _fn('get_today', 'Today\'s snapshot: recovery, strain, sleep, resting HR, steps, readiness, skin-temp/SpO₂ deviations.', {}),
    _fn('get_trend', 'A metric over time (server-aggregated buckets). Use for "trend/last week/month".', {
      'metric': {'type': 'string', 'description': 'one of: strain, recovery, resting_hr, hrv, sdnn, lf_hf, hrv_cv, calories, steps, wear, readiness, vo2max, fitness, fatigue, form, monotony, acwr, dip, efficiency, deep, rem, light, regularity, resp, sleep, stress, skin_temp, spo2'},
      'scale': {'type': 'string', 'enum': ['week', 'month', 'quarter']},
    }, ['metric']),
    _fn('get_day', 'Detailed data for one day & domain.', {
      'kind': {'type': 'string', 'enum': ['heart', 'sleep', 'strain', 'stress', 'wear', 'timeline', 'lungs']},
      'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
    }, ['kind', 'date']),
    _fn('get_sleep_history', 'Recent nightly sleep rows.', {}),
    _fn('get_strain_history', 'Recent daily strain rows.', {}),
    _fn('get_sessions', 'Recent detected/auto workouts.', {}),
    _fn('get_workouts', 'Workouts over a range.', {'range': {'type': 'string', 'enum': ['week', 'month', 'quarter']}}),
    _fn('get_cycle', 'Menstrual cycle status + prediction (if the user enabled tracking).', {}),
    _fn('get_journal', 'Behavior-tag journal entries.', {'range': {'type': 'string'}}),
    _fn('get_journal_insights', 'How tags correlate with the user\'s own metrics.', {'range': {'type': 'string'}}),
    _fn('get_profile', 'Profile: age, sex, height, weight, step goal.', {}),
    _fn('get_records', 'Personal records & streaks.', {}),
    _fn('get_history', 'Compact multi-metric history.', {'range': {'type': 'string'}}),
    _fn('plot_chart', 'Render a chart for the user from data you fetched. Build the figure yourself.', {
      'type': {'type': 'string', 'enum': ['bar', 'line', 'area']},
      'title': {'type': 'string'},
      'x_labels': {'type': 'array', 'items': {'type': 'string'}},
      'series': {'type': 'array', 'items': {'type': 'object', 'properties': {
        'name': {'type': 'string'},
        'values': {'type': 'array', 'items': {'type': ['number', 'null']}},
      }}},
      'unit': {'type': 'string'},
      'note': {'type': 'string'},
    }, ['type', 'x_labels', 'series']),
    _fn('log_journal', 'Log a journal entry (asks the user to confirm).', {
      'date': {'type': 'string'}, 'tags': {'type': 'array', 'items': {'type': 'string'}}, 'note': {'type': 'string'},
    }, ['date']),
    _fn('log_period', 'Log a period start (asks the user to confirm).', {'date': {'type': 'string'}}, ['date']),
    _fn('start_workout', 'Start a live workout (asks the user to confirm).', {'type': {'type': 'string'}}),
    _fn('end_workout', 'End the active workout (asks the user to confirm).', {'workout_id': {'type': 'string'}}, ['workout_id']),
    _fn('set_step_goal', 'Set the daily step goal (asks the user to confirm).', {'goal': {'type': 'integer'}}, ['goal']),
  ];
}

class CoachException implements Exception {
  final String message;
  CoachException(this.message);
  @override
  String toString() => message;
}
