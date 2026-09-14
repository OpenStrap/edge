// CoachEngine — the agentic core. Talks to an OpenAI-compatible provider directly
// (BYOK), runs a tool-calling loop over read-only data tools + a plot tool + action
// tools (writes require user confirmation), and streams items back to the UI.
//
// Data flow: user asks → model calls data tools (we read via the LocalRepository
// seam) → model reasons → optionally calls plot_chart with a figure it built →
// optionally proposes an action (we confirm) → model returns the final text.
//
// CLOUD EXCISED: the data tools used to hit the authed backend via ApiClient. They
// now go through LocalRepository (lib/data/local_repository.dart) — the same
// surface, implemented on-device by the future analytics re-layer. The LLM call
// itself still uses `http` directly (BYOK, the user's own provider — not our backend).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/day_label.dart';
import '../data/db.dart';
import '../data/local_repository.dart';
import 'coach_actions.dart';
import 'coach_config.dart';
import 'coach_db.dart';
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
enum CoachItemKind { user, assistant, chart, render, error }

class CoachItem {
  final CoachItemKind kind;
  final String? text;
  final ChartSpec? chart;
  /// Generic render spec ({type, title?, ...payload}) drawn by [CoachRender].
  final Map<String, dynamic>? render;
  CoachItem.user(this.text) : kind = CoachItemKind.user, chart = null, render = null;
  CoachItem.assistant(this.text) : kind = CoachItemKind.assistant, chart = null, render = null;
  CoachItem.error(this.text) : kind = CoachItemKind.error, chart = null, render = null;
  CoachItem.chart(this.chart) : kind = CoachItemKind.chart, text = null, render = null;
  CoachItem.render(this.render) : kind = CoachItemKind.render, text = null, chart = null;

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'text': text, 'chart': chart?.toJson(), 'render': render};

  static CoachItem fromJson(Map<String, dynamic> j) {
    final k = j['kind'];
    if (k == 'chart' && j['chart'] is Map) {
      final c = ChartSpec.tryParse((j['chart'] as Map).cast<String, dynamic>());
      if (c != null) return CoachItem.chart(c);
    }
    if (k == 'render' && j['render'] is Map) {
      return CoachItem.render((j['render'] as Map).cast<String, dynamic>());
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
  final LocalRepository api;
  final String storageKey; // per-user, so accounts don't share a transcript
  final http.Client _http = http.Client();

  // OpenAI-format running history (system is added per-request) — the context we
  // resend every turn so the model remembers the conversation.
  final List<Map<String, dynamic>> _history = [];

  // Serializable display transcript (text bubbles + charts) shown in the UI.
  final List<CoachItem> transcript = [];

  /// Test seams for the history-trimming invariant. `_history` is private and
  /// the trim only runs deep inside the tool-calling loop, so there is no other
  /// way to pin the orphaned-`tool` edge case without a live provider.
  @visibleForTesting
  List<Map<String, dynamic>> get debugHistory => _history;

  @visibleForTesting
  void debugTrimHistory() => _trimHistory();

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
    'Decoding last night…',
    'Auditing 90 days of you…',
    'Letting the data confess…',
    'Lining up the z-scores…',
    'Chasing a hunch through your HRV…',
    'Pulling the thread…',
  ];

  CoachEngine({required this.config, required this.api, this.storageKey = 'anon'});

  // ── prompt size ceilings ────────────────────────────────────────────────────
  //
  // The coach's tools read the on-device health database and every result is
  // resent, verbatim, on EVERY subsequent turn. Without a ceiling a model that
  // keeps widening its queries would eventually serialize the whole database
  // into a request bound for a third-party endpoint. Three bounds, all
  // independent of the provider's own context limit:
  //   • per tool result  — one query can't dominate the window;
  //   • rolling history  — the resent conversation is bounded in BYTES, not
  //     just in message count (60 × 16 KB was ~1 MB);
  //   • per request      — a hard fail-closed ceiling in [postChat].

  /// Max characters of any single tool result kept in the resent history.
  static const int kMaxToolResultChars = 16000;

  /// The ceiling for `get_ecg_reading` alone.
  ///
  /// The bound above exists because the MODEL widens its own queries — it can
  /// keep asking `run_sql` for more until one result dominates the window.
  /// `get_ecg_reading` is not that shape: it is a bound lookup of ONE reading
  /// by id, and its size is decided by the band (a completed reading is 30 s
  /// at 100 Hz), not by the model. Clipping it would not restrain a model, it
  /// would only decimate a waveform to make room for the prose describing it.
  static const int kMaxEcgToolResultChars = 24000;

  /// Max characters of running history resent on each turn.
  static const int kMaxHistoryChars = 120000;

  /// Hard ceiling on one serialized provider request body.
  static const int kMaxRequestBytes = 400 * 1024;

  static int _capFor(String tool) =>
      tool == 'get_ecg_reading' ? kMaxEcgToolResultChars : kMaxToolResultChars;

  static String _clipToolResult(String s, String tool) {
    final cap = _capFor(tool);
    return s.length <= cap
        ? s
        : '${s.substring(0, cap)}…(truncated — narrow the query)';
  }

  int _historyChars() {
    var n = 0;
    for (final m in _history) {
      n += jsonEncode(m).length;
    }
    return n;
  }

  /// Bound the resent history in bytes, dropping WHOLE turns from the oldest
  /// end so a `tool` message never outlives the assistant turn whose
  /// `tool_calls` it answers (providers 400 on an orphaned tool message).
  void _trimHistory() {
    while (_historyChars() > kMaxHistoryChars && _history.length > 1) {
      _history.removeAt(0);
      while (_history.length > 1 && _history.first['role'] != 'user') {
        _history.removeAt(0);
      }
    }
    // Both loops stop at `length > 1`, so one turn larger than the whole budget
    // can strand a lone `tool` at the head: [assistant(tool_calls), tool] drops
    // the assistant and then has nothing left to pair with. That orphan is the
    // exact shape this method exists to prevent, and providers 400 on it, so
    // enforce the invariant unconditionally rather than as a side effect of the
    // loop bounds.
    while (_history.isNotEmpty && _history.first['role'] == 'tool') {
      _history.removeAt(0);
    }
  }

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

  /// True when [base]'s host is anthropic.com or one of its subdomains. A
  /// domain-boundary check, not endsWith('anthropic.com'), so a lookalike
  /// host (evil-anthropic.com) never receives the key in Anthropic headers.
  static bool _isAnthropicHost(String base) {
    final host = (Uri.tryParse(base)?.host ?? '').toLowerCase();
    return host == 'anthropic.com' || host.endsWith('.anthropic.com');
  }

  /// Live model list from the provider's /models endpoint (OpenAI-compatible).
  /// Static so Settings can probe an as-yet-unsaved base URL + key.
  static Future<List<String>> fetchModels(String apiBase, String apiKey) async {
    var b = apiBase.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    // Anthropic's native Models API authenticates with x-api-key +
    // anthropic-version (a bearer token is rejected) and paginates with
    // has_more/last_id, but its response shape (data[].id) matches OpenAI's.
    final isAnthropic = _isAnthropicHost(b);
    final ids = <String>[];
    String? after;
    do {
      final uri = Uri.parse(isAnthropic
          ? '$b/models?limit=1000${after == null ? '' : '&after_id=$after'}'
          : '$b/models');
      final resp = await http.get(
        uri,
        headers: isAnthropic
            ? {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'}
            : {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw CoachException('Models request failed (${resp.statusCode}): ${_short(resp.body)}');
      }
      final j = jsonDecode(resp.body);
      final data = (j['data'] as List?) ?? const [];
      ids.addAll(data
          .map((e) => (e as Map)['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty));
      after = (isAnthropic && j['has_more'] == true) ? j['last_id']?.toString() : null;
    } while (after != null);
    ids.sort();
    return ids;
  }

  static String _short(String s) => s.length > 200 ? s.substring(0, 200) : s;

  // LOCAL day label — the coach's SQL views (v_daily/v_metric/…) are keyed by
  // the device-local dates the derivation engine files days under, so "today"
  // must be local too (a UTC date here pointed the model one day back until
  // ~05:30 for a UTC+5:30 user).
  static String _today() => todayLabel();

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
      _trimHistory();
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': '$kCoachSystemPrompt\n\nToday is ${_today()} (device-local date; all day-keyed data uses these local dates).'},
        ..._history,
      ];

      final reply = await _chat(messages);
      final toolCalls = (reply['tool_calls'] as List?) ?? const [];
      final content = (reply['content'] as String?)?.trim();

      if (toolCalls.isEmpty) {
        if (content != null && content.isNotEmpty) _emitAssistantText(content, emit);
        _history.add({'role': 'assistant', 'content': content ?? ''});
        onStatus(null);
        return;
      }

      // Assistant turn that requested tools (echo any interim text).
      if (content != null && content.isNotEmpty) _emitAssistantText(content, emit);
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
        _history.add({
          'role': 'tool',
          'tool_call_id': id,
          'name': name,
          'content': _clipToolResult(result, name),
        });
      }
    }
    emit(CoachItem.assistant('I dug through several steps but couldn’t wrap that up — try narrowing the question.'));
    onStatus(null);
  }

  // Some providers (esp. ones with shaky tool-calling) sometimes answer with a
  // fenced JSON code block instead of actually calling plot_chart/render — that
  // renders as an unexplained grey code block in the UI (GptMarkdown's default
  // code-field styling), not a chart. Detect a chart/render JSON payload inside
  // any fence and draw it as a real figure instead; leave real code fences (rare,
  // the coach is told never to write code) or non-figure JSON untouched.
  static void _emitAssistantText(String content, void Function(CoachItem) emit) {
    final fence = RegExp(r'```[a-zA-Z0-9_-]*\n([\s\S]*?)```');
    final figures = <CoachItem>[];
    final cleaned = content.replaceAllMapped(fence, (m) {
      try {
        final decoded = jsonDecode((m.group(1) ?? '').trim());
        if (decoded is Map && decoded['type'] != null) {
          final j = decoded.cast<String, dynamic>();
          final type = j['type'].toString().toLowerCase();
          if ((type == 'bar' || type == 'line' || type == 'area') && j['series'] != null) {
            final spec = ChartSpec.tryParse(j);
            if (spec != null) {
              figures.add(CoachItem.chart(spec));
              return '';
            }
          }
          figures.add(CoachItem.render(j));
          return '';
        }
      } catch (_) {
        // not JSON / not a figure — leave the fence as-is.
      }
      return m.group(0) ?? '';
    }).trim();
    if (cleaned.isNotEmpty) emit(CoachItem.assistant(cleaned));
    for (final f in figures) {
      emit(f);
    }
  }

  // ── provider call ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _chat(List<Map<String, dynamic>> messages) =>
      postChat(config, {
        'model': config.model,
        'messages': messages,
        'tools': _toolDefs,
        'tool_choice': 'auto',
        'temperature': 0.3,
      }, client: _http);

  /// True when [model] names a Claude version that rejects OpenAI sampling
  /// params (temperature/top_p/top_k) with a 400: Opus >= 4.7, Sonnet and
  /// Haiku >= 5, and the Fable/Mythos family. Claude is served under many
  /// provider namings — bare "claude-…", OpenRouter "anthropic/claude-…",
  /// Bedrock-style "anthropic.claude-…-v1:0" — with "-" or "." version
  /// separators, so match the id anywhere and parse family + version instead
  /// of keying off a prefix. Older Claude models still accept sampling and are
  /// deliberately excluded, as is every non-Claude model. Public for tests.
  static bool claudeRejectsSampling(String model) {
    final m = model.toLowerCase();
    final i = m.indexOf('claude');
    if (i < 0) return false;
    final id = m.substring(i);
    if (id.startsWith('claude-fable') || id.startsWith('claude-mythos')) {
      return true;
    }
    // Minor is capped at 2 digits with no digit following, so a date suffix
    // (claude-opus-4-20250514) never parses as a minor version.
    final v =
        RegExp(r'^claude-(opus|sonnet|haiku)[-.](\d+)(?:[-.](\d{1,2})(?!\d))?')
            .firstMatch(id);
    // Legacy version-first ids (claude-3-5-sonnet-…) all accept sampling.
    if (v == null) return false;
    final major = int.parse(v.group(2)!);
    final minor = int.tryParse(v.group(3) ?? '') ?? 0;
    if (v.group(1) == 'opus') {
      return major > 4 || (major == 4 && minor >= 7);
    }
    return major >= 5; // sonnet, haiku
  }

  /// THE one OpenAI-compatible chat-completions POST. Every LLM call in the app
  /// (the coach tool loop, the daily briefings, the journal chat) goes through
  /// here so there is exactly ONE provider client + error contract. Returns the
  /// first choice's `message` map. Throws [CoachException] on any provider error.
  static Future<Map<String, dynamic>> postChat(
    CoachConfig config,
    Map<String, dynamic> body, {
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    // Recent Claude models reject sampling params with a 400, on Anthropic's
    // own endpoint and through any pass-through provider alike. Strip them for
    // exactly those model versions; older Claude models and every other
    // provider keep their sampling params untouched.
    if (claudeRejectsSampling(body['model'] as String? ?? '')) {
      body = {...body}
        ..remove('temperature')
        ..remove('top_p')
        ..remove('top_k');
    }
    // FAIL-CLOSED size ceiling. Nothing leaves the device until this passes —
    // the request is never truncated and silently sent, it is refused, so a
    // runaway tool loop cannot ship the health database to a third party.
    final payload = jsonEncode(body);
    if (payload.length > kMaxRequestBytes) {
      throw CoachException(
          'That request grew to ${payload.length ~/ 1024} KB, over the '
          '${kMaxRequestBytes ~/ 1024} KB safety limit for data leaving this '
          'device. Start a new chat or ask a narrower question (aggregate with '
          'AVG/MIN/MAX/COUNT instead of selecting every row).');
    }
    try {
      final resp = await c
          .post(
            Uri.parse('${config.apiBase}/chat/completions'),
            headers: {
              'Authorization': 'Bearer ${config.apiKey}',
              'content-type': 'application/json',
            },
            body: payload,
          )
          .timeout(const Duration(seconds: 120));
      if (resp.statusCode != 200) {
        throw CoachException(
            'Provider error (${resp.statusCode}): ${_briefErr(resp.body)}');
      }
      final Object? j;
      try {
        j = jsonDecode(utf8.decode(resp.bodyBytes));
      } catch (_) {
        throw CoachException(
            'Provider returned a non-JSON response. Check the API base URL — '
            'it must point at an OpenAI-compatible /chat/completions endpoint.');
      }
      if (j is! Map) throw CoachException('Unexpected response from provider.');
      final choices = (j['choices'] as List?) ?? const [];
      if (choices.isEmpty) throw CoachException('Empty response from provider.');
      // Every shape below is a REAL thing OpenAI-compatible proxies return:
      // a streaming chunk (`delta` instead of `message`), the legacy
      // completions shape (`text`), or a bare string. Reaching for
      // `choices.first['message'] as Map<String,dynamic>` blind surfaced a raw
      // TypeError ("type 'Null' is not a subtype of type 'Map<String,
      // dynamic>'") instead of the documented CoachException, so the UI showed
      // a Dart type name to the user rather than an actionable message.
      final first = choices.first;
      if (first is! Map) throw CoachException('Unexpected response from provider.');
      final msg = first['message'] ?? first['delta'];
      if (msg is Map) return msg.cast<String, dynamic>();
      final text = first['text'];
      if (text is String) return <String, dynamic>{'content': text};
      throw CoachException(
          'Provider returned an unsupported response shape (no message/delta). '
          'Streaming-only endpoints are not supported — use a standard '
          'OpenAI-compatible /chat/completions endpoint.');
    } finally {
      if (client == null) c.close();
    }
  }

  /// One-shot multi-turn text completion (no tools). Reuses [postChat] — the
  /// briefing + journal engines call this instead of owning an HTTP client.
  static Future<String> chatOnce({
    required CoachConfig config,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.4,
  }) async {
    final msg = await postChat(config, {
      'model': config.model,
      'messages': messages,
      'temperature': temperature,
    });
    return ((msg['content'] as String?) ?? '').trim();
  }

  /// One-shot "system + user → text" completion. The simplest reuse surface.
  static Future<String> completeText({
    required CoachConfig config,
    required String system,
    required String user,
    double temperature = 0.4,
  }) =>
      chatOnce(config: config, temperature: temperature, messages: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ]);

  static String _briefErr(String body) {
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
        // data — one read-only SQL tool over the derived views
        case 'run_sql':
          return await CoachDb.runCoachSql('${args['sql'] ?? ''}');

        // data — the two stores that are NOT in the SQL views. Widening
        // `coach_db`'s allow-list to reach them would trade a structural btree
        // gate for a text-level one; a typed read tool costs nothing.
        case 'get_nutrition':
          return await CoachActions.nutritionDay(
              await LocalDb.instance, args['date']);
        case 'get_medications':
          return await CoachActions.medications(await LocalDb.instance);
        // data — one saved ECG reading, by id. Bound query + bounded payload;
        // the packet tables stay unreachable through run_sql.
        case 'get_ecg_reading':
          return await CoachActions.ecgReading(
              await LocalDb.instance, args['reading_id']);

        // plot — legacy bar/line/area figure
        case 'plot_chart':
          final spec = ChartSpec.tryParse(args);
          if (spec == null) return 'Could not parse figure; check the schema.';
          onItem(CoachItem.chart(spec));
          return 'Chart rendered for the user.';

        // render — rich typed widget spec ({type, title?, ...payload})
        case 'render':
          if (args['type'] == null) return 'render needs a "type" field.';
          onItem(CoachItem.render(Map<String, dynamic>.from(args)));
          return 'Rendered "${args['type']}" for the user.';

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
        case 'log_food':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log food',
            summary: 'Add "${args['label']}" to ${args['meal']} on '
                '${args['date'] ?? 'today'}'
                '${args['kcal'] == null ? '' : ' (${args['kcal']} kcal)'}.',
            args: args,
          ), () async => CoachActions.logFood(await LocalDb.instance, args));
        case 'log_journal_fields':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log how the day went',
            summary: 'Record ${_fieldSummary(args['fields'])} for '
                '${args['date'] ?? 'today'}.',
            args: args,
          ), () async => CoachActions.logJournalFields(api, args));
        case 'add_completed_workout':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Log a workout',
            summary: 'Save a ${args['duration_min']}-minute '
                '${args['type'] ?? 'workout'} starting '
                '${args['start_time']} on ${args['date'] ?? 'today'}.',
            args: args,
          ), () async => CoachActions.addCompletedWorkout(api, args));
        case 'add_medication':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Add a medication',
            summary: 'Schedule ${args['name']} at ${args['time']}, '
                '${_daysSummary(args['weekdays'])}. '
                'This app does not check interactions.',
            args: args,
          ), () async => CoachActions.addMedication(await LocalDb.instance, args));
        case 'mark_medication':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Mark a dose',
            summary: 'Record ${args['name']} on ${args['date'] ?? 'today'} as '
                '${args['state']}.',
            args: args,
          ), () async => CoachActions.markMedication(await LocalDb.instance, args));
        case 'set_step_goal':
          return await _action(confirm, ActionRequest(
            tool: name, title: 'Set step goal',
            summary: 'Set your daily step goal to ${args['goal']}.', args: args,
          ), () async {
            // A provider that sends "9000" as a string is not an edge case.
            final goal = CoachActions.num_(args['goal']);
            if (goal == null) throw CoachActionError('A step goal must be a number.');
            await api.setStepGoal(goal.round());
            return 'Step goal updated.';
          });

        default:
          return 'Unknown tool: $name';
      }
    } catch (e) {
      return 'Tool $name failed: ${e is RepositoryException ? e.body : e}';
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

  String _enc(Object? data) {
    final s = jsonEncode(data);
    return s.length > 16000 ? '${s.substring(0, 16000)}…(truncated)' : s;
  }

  /// "500 ml of water and mood 4" — the confirmation has to say what it writes,
  /// not "3 fields".
  static String _fieldSummary(Object? fields) {
    if (fields is! Map || fields.isEmpty) return 'nothing';
    return fields.entries
        .map((e) => '${e.key.toString().replaceAll('_', ' ')} ${e.value}')
        .join(', ');
  }

  static String _daysSummary(Object? weekdays) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (weekdays is! List || weekdays.isEmpty || weekdays.length == 7) {
      return 'every day';
    }
    return weekdays
        .map((d) => d is num && d >= 1 && d <= 7 ? names[d.toInt() - 1] : '?')
        .join(', ');
  }

  String _statusFor(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'run_sql': return 'Querying your data…';
      case 'get_nutrition': return 'Reading your food log…';
      case 'get_medications': return 'Reading your medications…';
      case 'plot_chart': return 'Plotting…';
      case 'render': return 'Rendering ${args['type'] ?? 'figure'}…';
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
    _fn('run_sql',
        'Read your health data by running ONE read-only SQLite SELECT over the '
        'derived views. Views & columns: '
        'v_metric(date,key,value); '
        'v_daily(date,resting_hr,hrv,sdnn,readiness,strain,resp_rate,stress,'
        'sleep_efficiency,sleep_min,deep_min,rem_min,light_min,nap_min,steps,'
        // `odi_per_hour` is NOT listed: the view still has the column but the
        // pipeline stopped writing the key when SpO2 was refused edge-side, so
        // it is permanently NULL. Advertising a column that can never hold a
        // value makes the model query it, get nothing, and reason about the
        // hole. A column that can never have data is a lie to the model.
        'active_calories,total_calories,skin_temp_z,lf_hf,hrv_cv,dip_pct,'
        'worn_min,hrr_bpm,brv_cv,irregular_flag); '
        'v_series(date,series,t,v) — series ∈ hr_curve,strain_curve,hrv_timeline,'
        'hrv_day,resp_day,skin_temp_day,zone_timeline,activity_curve; ALWAYS filter '
        'WHERE date=\'YYYY-MM-DD\' AND series=\'…\'; '
        'v_hypnogram(date,start_ts,end_ts,stage); '
        'v_sessions(id,start_ts,end_ts,date,type,status,calories,strain,max_hr,'
        'duration_min,steps,hrr_bpm,source,zone_min_json) — date is the LOCAL '
        'calendar day; filter "today\'s workout" by date, never by converting '
        'start_ts/end_ts yourself; '
        'v_baselines(key,value,mean,z,delta,ratio,n,updated_at); '
        'v_insights(id,kind,title,body,date,created_at,read); '
        'v_ecg_readings(id,start_ts,end_ts,date,wrist,status,category,'
        'result_code,avg_hr,quality,unreadable_mask,interruptions,duration_s,'
        'sample_count,sample_rate_hz,sample_unit,min_uv,max_uv,rms_uv,'
        'missing_segments) — WHOOP MG ECG readings, SUMMARY only (the '
        'category is the band\'s own result); the waveform is in '
        'get_ecg_reading. '
        'Read-only, derived only — no other tables. Dates are \'YYYY-MM-DD\'; '
        'timestamps are epoch seconds. Prefer aggregates (AVG/MIN/MAX/COUNT) over '
        'SELECT *. Results are capped at 200 rows.',
        {'sql': {'type': 'string', 'description': 'a single SELECT statement'}},
        ['sql']),
    _fn('plot_chart', 'Render a simple chart from data you fetched (bar/line/area). Build the figure yourself.', {
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
    _fn('render',
        'Render a RICH figure from data you fetched. Pick a "type" and provide its '
        'payload. Types: line/area/bar/multi_series {x_labels,series:[{name,values}],unit}; '
        'scatter {points:[{x,y,label?}],x_label,y_label}; '
        'dual_axis {x_labels,left:{name,values,unit},right:{name,values,unit}}; '
        'stacked_zone_bar {x_labels,zones:[{name,values}]}; '
        'hypnogram {segments:[{start,end,stage}]} (stage∈wake|light|deep|rem, epoch sec); '
        'kpi_grid {cards:[{label,value,unit?,delta?,baseline?,spark?:[n]}]}; '
        'gauge {value,min?,max?,label?,unit?}; '
        'heatmap {rows:[label],cols:[label],values:[[n]],unit?}; '
        'range_band {label,value,min,max,unit?}; '
        'table {columns:[..],rows:[[..]]}. Always include a "title".',
        {
          'type': {'type': 'string'},
          'title': {'type': 'string'},
        }, ['type']),
    _fn('get_nutrition',
        'Read one day of food. Returns every entry and the day totals as the '
        'app computes them (a total over an entry with no numbers is a FLOOR '
        'and says so). Food is NOT in run_sql — use this.',
        {'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'}}),
    _fn('get_medications',
        'Read the medication/supplement schedule and today\'s doses '
        '(taken/skipped/missed/upcoming). Not in run_sql — use this.', {}),
    _fn('get_ecg_reading',
        'Read ONE saved WHOOP MG ECG reading by id: local time, status, the '
        'BAND-REPORTED category and result code, average HR, signal quality, '
        'unreadable reasons, duration, sample count, missing segments, '
        'min/max/RMS, and the accepted waveform in microvolts at the band\'s '
        'own sample rate (null where a segment is missing; a window too long '
        'for one result is decimated by a whole-number stride, reported as '
        '`stride`). Never returns raw frames, a band serial or the notes. The '
        'category is the band\'s HeartKey result, not yours; you may read the '
        'waveform yourself and say if you disagree with it.',
        {'reading_id': {'type': 'string', 'description': 'the reading id from v_ecg_readings'}},
        ['reading_id']),
    _fn('log_food',
        'Log something eaten (asks the user to confirm). EVERY nutrient is '
        'optional: an eating occasion with no numbers is a complete log, and '
        'you must never invent a calorie or macro figure to fill a field. Only '
        'pass a number the user told you or that is on a label they described.',
        {
          'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
          'meal': {'type': 'string', 'enum': ['breakfast', 'lunch', 'dinner', 'snack']},
          'label': {'type': 'string', 'description': 'what it was'},
          'time': {'type': 'string', 'description': 'HH:MM, optional'},
          'quantity': {'type': 'number'},
          'unit': {'type': 'string', 'description': 'g, ml, piece…'},
          'kcal': {'type': 'number'},
          'protein_g': {'type': 'number'},
          'carbs_g': {'type': 'number'},
          'fat_g': {'type': 'number'},
          'fibre_g': {'type': 'number'},
          'sugar_g': {'type': 'number'},
          'sat_fat_g': {'type': 'number'},
          'sodium_mg': {'type': 'number'},
          'iron_mg': {'type': 'number'},
          'calcium_mg': {'type': 'number'},
          'note': {'type': 'string'},
        }, ['meal', 'label']),
    _fn('log_journal_fields',
        'Record the user\'s own numbers for a day (asks them to confirm). This '
        'is where WATER and MOOD live. Fields: mood, sleep_quality, energy, '
        'stress, soreness (all 1–5), water_ml, caffeine_mg, alcohol_units, '
        'screens_min, weight_kg. Fields you do not pass are left as they are.',
        {
          'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
          'fields': {'type': 'object', 'description': 'field key -> number'},
          'time': {'type': 'string', 'description': 'HH:MM — only used by caffeine/alcohol'},
        }, ['fields']),
    _fn('add_completed_workout',
        'Log a workout that ALREADY HAPPENED (asks the user to confirm). Use '
        'this for "I ran this morning" — start_workout is only for one starting '
        'right now. The window is scored from the recorded 1 Hz data; a window '
        'with nothing recorded behind it is saved unscored, and the result says '
        'which.',
        {
          'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
          'start_time': {'type': 'string', 'description': 'HH:MM local, 24-h'},
          'duration_min': {'type': 'integer'},
          'type': {'type': 'string', 'description': 'run, ride, walk, strength, swim, yoga…'},
        }, ['start_time', 'duration_min', 'type']),
    _fn('add_medication',
        'Add or replace a medication/supplement schedule (asks the user to '
        'confirm). weekdays are 1=Monday…7=Sunday; pass them whenever the user '
        'says anything other than daily. This app does NOT check interactions '
        'and you must not imply that it does.',
        {
          'name': {'type': 'string'},
          'time': {'type': 'string', 'description': 'HH:MM, 24-h'},
          'weekdays': {'type': 'array', 'items': {'type': 'integer'}},
          'dose_value': {'type': 'number'},
          'dose_unit': {'type': 'string', 'description': 'mg, ml, tablet…'},
          'kind': {'type': 'string', 'enum': ['medication', 'supplement']},
        }, ['name', 'time']),
    _fn('mark_medication',
        'Record one scheduled dose (asks the user to confirm). "skipped" is a '
        'decision the user made; "not_taken" undoes a mark. They are different '
        'facts — do not collapse them.',
        {
          'name': {'type': 'string'},
          'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
          'time': {'type': 'string', 'description': 'HH:MM of the slot; default the first'},
          'state': {'type': 'string', 'enum': ['taken', 'skipped', 'not_taken']},
        }, ['name', 'state']),
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
