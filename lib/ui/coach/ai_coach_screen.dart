// The AI Coach chat (BYOK, agentic). Runs CoachEngine, renders interleaved text +
// animated charts, and surfaces write-actions for explicit confirmation. Distinct
// from the rule-based CoachScreen (deterministic plan).
//
// Presentation is on the design language: AppScaffold chrome, an AiHero entry
// for a fresh chat, tokenised bubbles (soft-accent user / plain-markdown
// assistant), and a pill composer. Engine/session logic is untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';
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
        onItem: (it) {
          setState(() => _items.add(it));
          _scrollDown();
        },
        onStatus: (s) => setState(() => _status = s),
        confirm: _confirm,
      );
    } catch (e) {
      setState(() => _items.add(CoachItem.error(
          e is CoachException ? e.message : 'Something went wrong: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
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
                  Row(
                    children: [
                      Text('Chat history', style: AppText.h2),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _newChat();
                        },
                        icon: AppIcon(OsIcon.plus, size: 16, color: AppColors.accent),
                        label: Text('New chat',
                            style:
                                AppText.label.copyWith(color: AppColors.accent)),
                      ),
                    ],
                  ),
                  const SizedBox(height: Sp.x3),
                  if (snap.connectionState == ConnectionState.waiting)
                    const Padding(
                        padding: EdgeInsets.all(Sp.x6),
                        child: Center(child: CircularProgressIndicator()))
                  else if (sessions.isEmpty)
                    Padding(
                        padding: const EdgeInsets.all(Sp.x4),
                        child:
                            Text('No past chats yet.', style: AppText.captionMuted))
                  else
                    SurfaceCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Sp.x4, vertical: Sp.x1),
                      child: Column(
                        children: [
                          for (var i = 0; i < sessions.length; i++)
                            ListRow(
                              icon: OsIcon.ai,
                              iconColor: AppColors.accent,
                              title: sessions[i].title.isEmpty
                                  ? 'Untitled chat'
                                  : sessions[i].title,
                              subtitle: [
                                if (sessions[i].preview.isNotEmpty)
                                  sessions[i].preview,
                                _relTime(sessions[i].updatedAt),
                              ].join(' · '),
                              divider: i != sessions.length - 1,
                              onTap: () {
                                Navigator.pop(sheetCtx);
                                _openSession(sessions[i].id);
                              },
                              trailing: IconButton(
                                icon: AppIcon(OsIcon.trash,
                                    size: 16, color: AppColors.inkMuted),
                                onPressed: () async {
                                  final s = sessions[i];
                                  final wasCurrent = s.id == engine.sessionId;
                                  await engine.deleteSession(s.id);
                                  setSheet(() {});
                                  // deleting the open chat resets it to a fresh one
                                  if (wasCurrent && mounted) {
                                    setState(() => _items.clear());
                                  }
                                },
                              ),
                            ),
                        ],
                      ),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
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

  void _openSettings() => Navigator.of(context).push(themedRoute(
      (_) => const CoachSettingsScreen(),
      name: 'CoachSettingsScreen'));

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<CoachConfig>();
    final signedIn = context.select<AppState, bool>((s) => s.repo != null);

    return AppScaffold(
      title: 'AI Coach',
      subtitle: cfg.configured ? cfg.model : 'Not configured',
      largeTitle: false,
      actions: [
        RoundIconButton(OsIcon.history, onTap: _openSessions),
        RoundIconButton(OsIcon.plus, onTap: _newChat),
        RoundIconButton(OsIcon.settings, onTap: _openSettings),
      ],
      body: Column(
        children: [
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
        ],
      ),
    );
  }

  Widget _setupPrompt() => ListView(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x4, Sp.screen, Sp.x6),
        children: [
          StateCard(
            icon: OsIcon.ai,
            title: 'Bring your own AI',
            message:
                'Use any OpenAI-compatible provider with your own API key. Your '
                'key stays on this device and talks to the provider directly — '
                'it never touches OpenStrap servers.',
            actionLabel: 'Set up your AI coach',
            onAction: _openSettings,
          ).dsEnter(),
        ],
      );

  Widget _starterView() => ListView(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x6),
        children: [
          AiHero(
            overline: 'YOUR DATA, YOUR AI',
            line: 'Ask anything about your health.',
            cta: 'I can read every metric in your data and chart it.',
          ).dsEnter(index: 0),
          const SizedBox(height: Sp.x5),
          Text('TRY ASKING',
              style: AppText.overline.copyWith(color: AppColors.inkMuted))
              .dsEnter(index: 1),
          const SizedBox(height: Sp.x2),
          SurfaceCard(
            padding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x1),
            child: Column(
              children: [
                for (var i = 0; i < _starters.length; i++)
                  ListRow(
                    title: _starters[i],
                    divider: i != _starters.length - 1,
                    onTap: () => _send(_starters[i]),
                  ),
              ],
            ),
          ).dsEnter(index: 2),
        ],
      );

  Widget _transcript() => ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x4),
        itemCount: _items.length,
        itemBuilder: (_, i) => CoachBubble(item: _items[i]),
      );

  Widget _statusBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.screen, vertical: Sp.x2),
        child: Row(
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.onAccentSoft)),
            const SizedBox(width: Sp.x3),
            Text(_status ?? '', style: AppText.captionMuted),
          ],
        ),
      );

  Widget _composer() => Padding(
        padding: EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen,
            Sp.x3 + MediaQuery.of(context).viewInsets.bottom),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                style: AppText.body,
                textInputAction: TextInputAction.send,
                onSubmitted: _busy ? null : _send,
                decoration: InputDecoration(
                  hintText: 'Ask about your health…',
                  hintStyle:
                      AppText.bodySoft.copyWith(color: AppColors.inkMuted),
                  filled: true,
                  fillColor: AppColors.surfaceAlt,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Sp.x4, vertical: Sp.x3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(R.pill),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Sp.x2),
            RoundIconButton(
              OsIcon.activity,
              bg: AppColors.ink,
              fg: AppColors.surface,
              onTap: _busy ? null : () => _send(_input.text),
            ),
          ],
        ),
      );

  Widget _centered(String msg) => Center(
      child: Padding(
          padding: const EdgeInsets.all(Sp.x6),
          child:
              Text(msg, textAlign: TextAlign.center, style: AppText.bodySoft)));
}

/// One transcript entry, on the design tokens: user = soft-accent bubble on the
/// right; assistant = plain markdown (no card chrome — the answer IS the page);
/// charts/renders keep their own card; errors read as a quiet warn row.
class CoachBubble extends StatelessWidget {
  final CoachItem item;
  const CoachBubble({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case CoachItemKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: Sp.x3, left: 48),
            padding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(R.card),
                topRight: Radius.circular(R.card),
                bottomLeft: Radius.circular(R.card),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(item.text ?? '',
                style: AppText.body.copyWith(color: AppColors.onAccentSoft)),
          ),
        );
      case CoachItemKind.assistant:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4, right: Sp.x2),
          child: GptMarkdown(item.text ?? '', style: AppText.body),
        );
      case CoachItemKind.chart:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4),
          child: CoachChart(spec: item.chart!),
        );
      case CoachItemKind.render:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4),
          child: CoachRender(spec: item.render!),
        );
      case CoachItemKind.error:
        return Padding(
          padding: const EdgeInsets.only(bottom: Sp.x4),
          child: SurfaceCard(
            padding: const EdgeInsets.all(Sp.x3),
            child: Row(
              children: [
                AppIcon(OsIcon.info, size: 16, color: AppColors.warn),
                const SizedBox(width: Sp.x3),
                Expanded(
                    child: Text(item.text ?? '', style: AppText.captionMuted)),
              ],
            ),
          ),
        );
    }
  }
}
