// The AI Coach chat (BYOK, agentic). Runs CoachEngine, renders interleaved text +
// animated charts, and surfaces write-actions for explicit confirmation. Distinct
// from the rule-based CoachScreen (deterministic plan).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import 'coach_chart.dart';
import 'coach_render.dart';
import 'coach_settings_screen.dart';

class AiCoachScreen extends StatefulWidget {
  const AiCoachScreen({super.key});
  @override
  State<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends State<AiCoachScreen> {
  CoachEngine? _engine;
  final List<CoachItem> _items = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  String? _status;

  static const _starters = [
    'How recovered am I today, and why?',
    'Show my HRV trend this month',
    'Compare my resting HR vs HRV over 2 weeks',
    'How has my sleep been this week?',
    'What should my training look like today?',
  ];

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  Future<void> _initEngine() async {
    final app = context.read<AppState>();
    final cfg = context.read<CoachConfig>();
    final api = app.repo;
    if (api == null) return;
    final uid = (app.user?['id'] ?? 'anon').toString();
    final engine = CoachEngine(config: cfg, api: api, storageKey: uid);
    await engine.restore();
    if (!mounted) return;
    setState(() {
      _engine = engine;
      _items
        ..clear()
        ..addAll(engine.transcript);
    });
    _scrollDown();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _engine?.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy) return;
    final engine = _engine;
    if (engine == null) return;
    _input.clear();
    setState(() => _busy = true);
    try {
      await engine.send(
        t,
        onItem: (it) { setState(() => _items.add(it)); _scrollDown(); },
        onStatus: (s) => setState(() => _status = s),
        confirm: _confirm,
      );
    } catch (e) {
      setState(() => _items.add(CoachItem.error(
          e is CoachException ? e.message : 'Something went wrong: $e')));
    } finally {
      if (mounted) setState(() { _busy = false; _status = null; });
      await engine.persist(); // survive reopen
      _scrollDown();
    }
  }

  void _newChat() {
    _engine?.newSession();
    setState(() => _items.clear());
  }

  void _openSession(String id) async {
    await _engine?.openSession(id);
    if (mounted) {
      setState(() => _items
        ..clear()
        ..addAll(_engine?.transcript ?? const []));
      _scrollDown();
    }
  }

  Future<void> _openSessions() async {
    final engine = _engine;
    if (engine == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => FutureBuilder<List<CoachSessionMeta>>(
          future: engine.listSessions(),
          builder: (_, snap) {
            final sessions = snap.data ?? const <CoachSessionMeta>[];
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.6,
              maxChildSize: 0.9,
              builder: (_, controller) => ListView(
                controller: controller,
                padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
                children: [
                  Row(children: [
                    Text('Chat history', style: AppText.h2),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () { Navigator.pop(sheetCtx); _newChat(); },
                      icon: AppIcon(Ic.plus, size: 16, color: AppColors.coral),
                      label: Text('New chat', style: AppText.label.copyWith(color: AppColors.coral)),
                    ),
                  ]),
                  const SizedBox(height: Sp.x3),
                  if (snap.connectionState == ConnectionState.waiting)
                    const Padding(padding: EdgeInsets.all(Sp.x6), child: Center(child: CircularProgressIndicator()))
                  else if (sessions.isEmpty)
                    Padding(padding: const EdgeInsets.all(Sp.x4),
                        child: Text('No past chats yet.', style: AppText.captionMuted))
                  else
                    for (final s in sessions)
                      ProCard(
                        onTap: () { Navigator.pop(sheetCtx); _openSession(s.id); },
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.title.isEmpty ? 'Untitled chat' : s.title,
                                style: AppText.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            if (s.preview.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(s.preview, style: AppText.captionMuted, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                            const SizedBox(height: 2),
                            Text(_relTime(s.updatedAt), style: AppText.captionMuted),
                          ])),
                          IconButton(
                            icon: AppIcon(Ic.trash, size: 16, color: AppColors.inkMuted),
                            onPressed: () async {
                              final wasCurrent = s.id == engine.sessionId;
                              await engine.deleteSession(s.id);
                              setSheet(() {});
                              // deleting the open chat resets it to a fresh one
                              if (wasCurrent && mounted) setState(() => _items.clear());
                            },
                          ),
                        ]),
                      ),
                  const SizedBox(height: 40),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static String _relTime(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Future<bool> _confirm(ActionRequest req) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(req.title, style: AppText.title),
        content: Text(req.summary, style: AppText.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<CoachConfig>();
    final signedIn = context.select<AppState, bool>((s) => s.repo != null);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(children: [
          _topBar(cfg),
          Expanded(
            child: !cfg.configured
                ? _setupPrompt()
                : !signedIn
                    ? _centered('Pair your strap to use the coach.')
                    : _items.isEmpty
                        ? _starterView()
                        : _transcript(),
          ),
          if (_status != null) _statusBar(),
          if (cfg.configured && signedIn) _composer(),
        ]),
      ),
    );
  }

  Widget _topBar(CoachConfig cfg) => Padding(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x4, Sp.screen, Sp.x2),
        child: Row(children: [
          RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: Sp.x3),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('AI Coach', style: AppText.h1),
            Text(cfg.configured ? cfg.model : 'Not configured', style: AppText.caption),
          ])),
          RoundIconButton(Ic.history, onTap: _openSessions),
          const SizedBox(width: Sp.x2),
          RoundIconButton(Ic.plus, onTap: _newChat),
          const SizedBox(width: Sp.x2),
          RoundIconButton(Ic.settings, onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CoachSettingsScreen()))),
        ]),
      );

  Widget _setupPrompt() => Center(child: Padding(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(Ic.ai, size: 40, color: AppColors.coral),
          const SizedBox(height: Sp.x4),
          Text('Bring your own AI', style: AppText.h2),
          const SizedBox(height: Sp.x3),
          Text('Use any OpenAI-compatible provider with your own API key. Your key '
              'stays on this device and talks to the provider directly — it never '
              'touches OpenStrap servers.',
              textAlign: TextAlign.center, style: AppText.bodySoft),
          const SizedBox(height: Sp.x5),
          FilledButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CoachSettingsScreen())),
            child: const Text('Set up your AI coach'),
          ),
        ]),
      ));

  Widget _starterView() => ListView(
        padding: const EdgeInsets.all(Sp.screen),
        children: [
          const SizedBox(height: Sp.x4),
          Text('Ask me anything about your health', style: AppText.h2),
          const SizedBox(height: Sp.x2),
          Text('I can read every metric in your data and chart it.', style: AppText.captionMuted),
          const SizedBox(height: Sp.x5),
          for (final s in _starters)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.x3),
              child: ProCard(onTap: () => _send(s), child: Row(children: [
                Expanded(child: Text(s, style: AppText.body)),
                AppIcon(Ic.arrowRight, size: 16, color: AppColors.inkMuted),
              ])),
            ),
        ],
      );

  Widget _transcript() => ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(Sp.screen),
        itemCount: _items.length,
        itemBuilder: (_, i) => _bubble(_items[i]),
      );

  Widget _bubble(CoachItem it) {
    switch (it.kind) {
      case CoachItemKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: Sp.x3, left: 40),
            padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
            decoration: BoxDecoration(color: AppColors.coralSoft, borderRadius: BorderRadius.circular(R.card)),
            child: Text(it.text ?? '', style: AppText.body.copyWith(color: AppColors.coralInk)),
          ),
        );
      case CoachItemKind.assistant:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4, right: 8),
          child: GptMarkdown(it.text ?? '', style: AppText.body),
        );
      case CoachItemKind.chart:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4),
          child: CoachChart(spec: it.chart!),
        );
      case CoachItemKind.render:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4),
          child: CoachRender(spec: it.render!),
        );
      case CoachItemKind.error:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4),
          child: ProCard(child: Row(children: [
            AppIcon(Ic.info, size: 16, color: AppColors.warn),
            const SizedBox(width: Sp.x3),
            Expanded(child: Text(it.text ?? '', style: AppText.captionMuted)),
          ])),
        );
    }
  }

  Widget _statusBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.screen, vertical: Sp.x2),
        child: Row(children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: Sp.x3),
          Text(_status ?? '', style: AppText.captionMuted),
        ]),
      );

  Widget _composer() => Padding(
        padding: EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen,
            Sp.x3 + MediaQuery.of(context).viewInsets.bottom),
        child: Row(children: [
          Expanded(child: TextField(
            controller: _input,
            minLines: 1, maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: _busy ? null : _send,
            decoration: const InputDecoration(hintText: 'Ask about your health…'),
          )),
          const SizedBox(width: Sp.x3),
          FilledButton(
            onPressed: _busy ? null : () => _send(_input.text),
            child: const AppIcon(Ic.arrowRight, size: 18, color: Colors.white),
          ),
        ]),
      );

  Widget _centered(String msg) => Center(child: Padding(
      padding: const EdgeInsets.all(Sp.x6),
      child: Text(msg, textAlign: TextAlign.center, style: AppText.bodySoft)));
}
