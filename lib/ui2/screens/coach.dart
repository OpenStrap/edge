// COACH — the door onto the agentic AI that was already built.
//
// `lib/coach` has had a working tool-calling loop for months: read-only SQL over
// the derived views, figures the app draws natively, and confirmation-gated
// writes. It had no screen, so none of it could run. This is the screen.
//
// Three rules this file keeps:
//
//   1. LOCAL FIRST. The app is zero-egress by design, so the setup screen offers
//      Ollama and LM Studio before it offers anyone's cloud. A cloud key is a
//      deliberate choice, and the screen says what leaving the device means.
//   2. EVERY WRITE IS CONFIRMED. `confirm` is wired to a real dialog carrying
//      the tool's own human-readable summary. There is no path from a tool call
//      to a write that does not pass through it, and a destructive action gets
//      its own wording rather than the same "Confirm" as an add.
//   3. NO SECOND DESIGN SYSTEM. Figures are `CoachFigure` (the app's own
//      painters); everything else is grammar.dart. The one thing that is not is
//      the markdown body, because there is no house widget for prose.

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../ai/briefing.dart' show currentBriefingPeriod;
import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'ai_briefing.dart';
import 'coach_figures.dart';
import 'home_screen.dart' show go, pad, repoOf;
import 'journal_compose.dart' show OsTextField;

/// The coach's accent. Not a domain colour: the coach reads across all five.
const Color kCoachAccent = C.purple;

/// Whether the coach has a model behind it — false when there is no
/// [CoachConfig] above us, which is every golden.
///
/// Home shows its sparkles button only when this is true. An icon that opens a
/// setup form nobody asked for is clutter on a screen built around three rings,
/// and the place to go and set the thing up is Profile, with the other
/// settings. [keyUnreadable] counts as configured: the key IS saved, this
/// process just could not read it through a locked keychain, and hiding the
/// button there would tell a configured user their coach had vanished.
bool coachReady(BuildContext c) {
  try {
    final cfg = c.watch<CoachConfig>();
    return cfg.configured || cfg.keyUnreadable;
  } catch (_) {
    return false;
  }
}

/// [coachReady] for an event handler, which must not listen.
///
/// `watch` outside `build` trips a provider assert, and the catch above turns
/// that into a plain "not configured" — so a tap handler asking [coachReady]
/// sends a fully configured user to the setup form every time.
bool coachReadyNow(BuildContext c) {
  try {
    final cfg = c.read<CoachConfig>();
    return cfg.configured || cfg.keyUnreadable;
  } catch (_) {
    return false;
  }
}

/// What the Profile row should say under "AI coach", or null when there is no
/// [CoachConfig] above this context at all.
///
/// Same try/catch as [coachReady] and for the same reason: the golden harness
/// mounts screens without the app's providers, and a throw there is a red test
/// about the harness rather than about the screen. Null and "Not set up" are
/// deliberately the same sentence to the reader — from the row's point of view
/// an unreadable config and an unset one both mean the setup form is what the
/// tap should open.
String? coachSubtitle(BuildContext c) {
  try {
    final cfg = c.watch<CoachConfig>();
    return cfg.configured
        ? cfg.model
        : (AppLocalizations.of(c)?.coachNotSetUp ?? 'Not set up');
  } catch (_) {
    return null;
  }
}

class CoachScreen extends StatefulWidget {
  /// A message to send the moment the engine is up — visibly, as the user's
  /// own turn, so the model runs its tools on it like any other question
  /// (nothing is injected as trusted prose). [startNewSession] opens a fresh
  /// conversation for it first.
  final String? initialMessage;
  final bool startNewSession;

  const CoachScreen({
    super.key,
    this.initialMessage,
    this.startNewSession = false,
  });

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<CoachScreen> {
  CoachEngine? _engine;
  final List<CoachItem> _items = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  String? _status;

  static List<String> _starters(BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
      l?.coachStarterRecovery ?? 'How recovered am I today, and why?',
      l?.coachStarterHrvChart ?? 'Chart my HRV over the last month',
      l?.coachStarterSleep ?? 'How has my sleep been this week?',
      l?.coachStarterAteYesterday ?? 'What did I eat yesterday?',
      l?.coachStarterLogWater ?? 'Log 500 ml of water for today',
      l?.coachStarterLogRun ?? 'I ran for 40 minutes this morning — log it',
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initEngine());
  }

  Future<void> _initEngine() async {
    if (!mounted) return;
    final repo = repoOf(context);
    if (repo == null) return;
    final app = context.read<AppState>();
    final cfg = context.read<CoachConfig>();
    final engine = CoachEngine(
      config: cfg,
      api: repo,
      storageKey: (app.user?['id'] ?? 'local').toString(),
    );
    await engine.restore();
    if (!mounted) {
      engine.dispose();
      return;
    }
    if (widget.startNewSession) engine.newSession();
    setState(() {
      _engine = engine;
      _items
        ..clear()
        ..addAll(engine.transcript);
    });
    _scrollDown();
    final first = widget.initialMessage;
    if (first != null && first.trim().isNotEmpty && !_sentInitial) {
      _sentInitial = true;
      await _send(first);
    }
  }

  bool _sentInitial = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _engine?.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    final engine = _engine;
    if (t.isEmpty || _busy || engine == null) return;
    _input.clear();
    setState(() => _busy = true);
    try {
      // `send` can block for up to 120 s, so every callback below can land after
      // the user has popped the screen.
      await engine.send(
        t,
        onItem: (it) {
          if (!mounted) return;
          setState(() => _items.add(it));
          _scrollDown();
        },
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
        confirm: _confirm,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _items.add(
            CoachItem.error(
              e is CoachException
                  ? e.message
                  : (AppLocalizations.of(context)?.coachSomethingWrong('$e') ??
                      'Something went wrong: $e'),
            ),
          );
        });
      }
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

  /// THE write gate. Every action tool routes through here, and the dialog
  /// carries the tool's own summary rather than a generic "the AI wants to do
  /// something" — a confirmation that does not say what it confirms is a tap
  /// target, not consent.
  Future<bool> _confirm(ActionRequest req) async {
    final destructive = req.tool.startsWith('delete_');
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: p.card,
        title: Text(req.title, style: F.head.copyWith(color: p.ink)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              req.summary,
              style: F.body.copyWith(color: p.ink2, height: 1.4),
            ),
            const SizedBox(height: S.x3),
            Text(
              destructive
                  ? (l?.coachDestructiveWarning ??
                      'This removes data from this device and cannot be undone.')
                  : (l?.coachSafeWarning ?? 'Nothing is written until you tap below.'),
              style: F.cap.copyWith(color: p.ink3),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.actionCancel ?? 'Cancel', style: F.body.copyWith(color: p.ink2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(
              destructive ? (l?.coachDeleteIt ?? 'Delete it') : (l?.coachSaveIt ?? 'Save it'),
              style: F.body.copyWith(
                color: p.on(destructive ? C.red : kCoachAccent),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _newChat() {
    _engine?.newSession();
    setState(_items.clear);
  }

  Future<void> _openSession(String id) async {
    await _engine?.openSession(id);
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(_engine?.transcript ?? const []);
    });
    _scrollDown();
  }

  void _scrollDown() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: motion(context, Motion.slow),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _menu() async {
    final engine = _engine;
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: StatefulBuilder(
          builder: (sheet, setSheet) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
            children: [
              _MenuRow(
                LucideIcons.plus,
                l?.coachNewChat ?? 'New chat',
                onTap: () {
                  Navigator.of(sheet).pop();
                  _newChat();
                },
              ),
              // NO "AI settings" ROW. Choosing the model is a setting and
              // settings live in Profile — [CoachSetup] is pushed from there
              // now. Two doors onto one form is how a setting ends up with two
              // different states in a user's head, and this screen is where
              // you talk to the thing, not where you configure it. The only
              // way into the form from here is the not-set-up card in [_body],
              // which is a recovery state rather than a settings entry.
              _MenuRow(
                LucideIcons.fileText,
                l?.coachBriefingMenuTitle ?? 'Briefing, and what was sent',
                sub: l?.coachBriefingMenuSub ?? 'The exact snapshot that left this device',
                onTap: () {
                  Navigator.of(sheet).pop();
                  go(
                    context,
                    AiBriefingScreen(
                      period: currentBriefingPeriod(DateTime.now()),
                    ),
                  );
                },
              ),
              if (engine != null) ...[
                const SizedBox(height: S.x4),
                Text(
                  l?.coachPastChats ?? 'PAST CHATS',
                  style: F.over.copyWith(color: p.ink3),
                ),
                const SizedBox(height: S.x2),
                FutureBuilder<List<CoachSessionMeta>>(
                  future: engine.listSessions(),
                  builder: (_, snap) {
                    final list = snap.data ?? const <CoachSessionMeta>[];
                    if (list.isEmpty) {
                      return Text(
                        l?.coachNoChatsYet ??
                            'Nothing yet — this is your first conversation.',
                        style: F.cap.copyWith(color: p.ink3),
                      );
                    }
                    return Column(
                      children: [
                        for (final s in list.take(20))
                          _MenuRow(
                            LucideIcons.messageSquare,
                            s.title.isEmpty ? (l?.coachUntitledChat ?? 'Untitled chat') : s.title,
                            sub: s.preview,
                            onTap: () {
                              Navigator.of(sheet).pop();
                              _openSession(s.id);
                            },
                            onRemove: () async {
                              final wasOpen = s.id == engine.sessionId;
                              await engine.deleteSession(s.id);
                              setSheet(() {});
                              if (wasOpen && mounted) setState(_items.clear);
                            },
                          ),
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cfg = c.watch<CoachConfig>();
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(
                l?.coachNavTitle ?? 'Coach',
                sub: cfg.configured ? cfg.model : (l?.coachNotSetUp ?? 'Not set up'),
                trailing: Pressable(
                  semanticLabel: l?.coachMenuSemantic ?? 'Chats and AI settings',
                  onTap: _menu,
                  child: Icon(LucideIcons.ellipsis, size: 22, color: p.ink),
                ),
              ),
            ),
            Expanded(child: _body(c, p, cfg)),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(S.x5, S.x2, S.x5, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.on(kCoachAccent),
                      ),
                    ),
                    const SizedBox(width: S.x3),
                    Expanded(
                      child: Text(
                        _status ?? '',
                        style: F.cap.copyWith(color: p.ink3),
                      ),
                    ),
                  ],
                ),
              ),
            if (cfg.configured && _engine != null) _composer(c, p),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext c, P p, CoachConfig cfg) {
    final l = AppLocalizations.of(c);
    // The key IS saved, this process just could not read it. Showing the setup
    // wall here would tell the user their key is gone and invite them to paste
    // it again.
    if (cfg.keyUnreadable) {
      return ListView(
        padding: pad,
        children: [
          const SizedBox(height: S.x4),
          StatusCard(
            l?.coachKeyStillSavedTitle ?? 'Your key is still saved',
            l?.coachKeyStillSavedBody ??
                'It could not be read from the keychain this time, which happens '
                    'when the app is woken while the phone is locked.',
            fix: l?.coachTryAgainFix ?? 'Try again',
            icon: LucideIcons.lock,
            onFix: () async {
              await cfg.refreshKeyOnResume();
              if (mounted) setState(() {});
            },
          ),
        ],
      );
    }
    if (!cfg.configured) {
      return ListView(
        padding: pad,
        children: [
          const SizedBox(height: S.x4),
          StatusCard(
            l?.coachNotSetUpTitle ?? 'The coach is not set up',
            l?.coachNotSetUpBody ??
                'It runs on a model you choose — one on your own machine, or any '
                    'OpenAI-compatible provider with your own key. Nothing goes '
                    'through OpenStrap either way.',
            fix: l?.coachChooseModelFix ?? 'Choose a model',
            icon: LucideIcons.sparkles,
            onFix: () => go(c, const CoachSetup()),
          ),
        ],
      );
    }
    if (_engine == null) {
      return ListView(
        padding: pad,
        children: [
          const SizedBox(height: S.x4),
          StatusCard(
            l?.coachNoDataTitle ?? 'No data to read yet',
            l?.coachNoDataBody ??
                'The coach answers from your own derived days, and there are none '
                    'on this device yet.',
            icon: LucideIcons.database,
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        padding: pad,
        children: [
          const SizedBox(height: S.x2),
          Surface(
            color: p.wash(kCoachAccent),
            elevation: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.sparkles,
                      size: 17,
                      color: p.on(kCoachAccent),
                    ),
                    const SizedBox(width: S.x2),
                    Text(
                      l?.coachYourDataYourModel ?? 'YOUR DATA, YOUR MODEL',
                      style: F.over.copyWith(color: p.on(kCoachAccent)),
                    ),
                  ],
                ),
                const SizedBox(height: S.x3),
                Text(
                  l?.coachIntroBody ??
                      'Ask about anything the app measures, and it can log food, '
                          'water, workouts, doses and how you felt — always asking '
                          'first.',
                  style: F.body.copyWith(color: p.ink, height: 1.45),
                ),
              ],
            ),
          ),
          Section(
            l?.coachTryAsking ?? 'Try asking',
            Surface(
              pad: const EdgeInsets.symmetric(vertical: S.x1),
              child: Column(
                children: [
                  for (final s in _starters(c))
                    Pressable(
                      onTap: () => _send(s),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: S.x4,
                          vertical: S.x3,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                s,
                                style: F.body.copyWith(color: p.ink2),
                              ),
                            ),
                            Icon(
                              LucideIcons.chevronRight,
                              size: 16,
                              color: p.ink3,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
      itemCount: _items.length,
      itemBuilder: (_, i) => _Bubble(item: _items[i]),
    );
  }

  Widget _composer(BuildContext c, P p) {
    final l = AppLocalizations.of(c);
    return Padding(
    padding: EdgeInsets.fromLTRB(
      S.x4,
      S.x2,
      S.x4,
      S.x3 + MediaQuery.of(c).viewInsets.bottom,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: S.x4,
              vertical: S.x2,
            ),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: R.rXl,
              border: Border.all(color: p.line),
            ),
            child: Semantics(
              label: l?.coachAskLabel ?? 'Ask the coach',
              textField: true,
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                enabled: !_busy,
                style: F.body.copyWith(color: p.ink),
                cursorColor: p.on(kCoachAccent),
                textInputAction: TextInputAction.send,
                onSubmitted: _busy ? null : _send,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: l?.coachInputHint ?? 'Ask about your health…',
                  hintStyle: F.body.copyWith(color: p.ink3),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: S.x2),
        Pressable(
          semanticLabel: l?.coachSendLabel ?? 'Send',
          onTap: _busy ? null : () => _send(_input.text),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _busy ? p.card2 : p.fill(kCoachAccent),
            ),
            child: Icon(
              LucideIcons.arrowUp,
              size: 20,
              color: _busy ? p.ink3 : p.inkOnFill,
            ),
          ),
        ),
      ],
    ),
  );
  }
}

/// One transcript entry. The user's turn is a soft bubble; the answer is the
/// page (no card chrome — a card around every answer makes a chat read as a
/// feed); figures keep their own frame.
class _Bubble extends StatelessWidget {
  final CoachItem item;
  const _Bubble({required this.item});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    switch (item.kind) {
      case CoachItemKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: S.x3, left: S.x12),
            padding: const EdgeInsets.symmetric(
              horizontal: S.x4,
              vertical: S.x3,
            ),
            decoration: BoxDecoration(
              color: p.wash(kCoachAccent),
              borderRadius: R.rLg,
            ),
            child: Text(
              item.text ?? '',
              style: F.body.copyWith(color: p.ink, height: 1.4),
            ),
          ),
        );
      case CoachItemKind.assistant:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: GptMarkdown(
            item.text ?? '',
            style: F.body.copyWith(color: p.ink, height: 1.5),
          ),
        );
      case CoachItemKind.chart:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: CoachFigure(spec: item.chart!.toJson()),
        );
      case CoachItemKind.render:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: CoachFigure(spec: item.render!),
        );
      case CoachItemKind.error:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: StatusCard(
            AppLocalizations.of(c)?.coachErrorTitle ?? 'That did not go through',
            item.text ?? '',
            icon: LucideIcons.triangleAlert,
          ),
        );
    }
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  const _MenuRow(
    this.icon,
    this.title, {
    this.sub = '',
    this.onTap,
    this.onRemove,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Icon(icon, size: 17, color: p.ink3),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: F.body.copyWith(color: p.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      style: F.cap.copyWith(color: p.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (onRemove != null)
              Pressable(
                semanticLabel:
                    AppLocalizations.of(c)?.coachDeleteChat(title) ?? 'Delete $title',
                onTap: onRemove,
                child: Icon(LucideIcons.trash2, size: 16, color: p.ink3),
              ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════ setup ═══════════════════════

/// A provider preset. Local ones come first and carry no key, because a model
/// running on the user's own machine is the only configuration where the health
/// data never leaves their control.
class _Preset {
  final String label, sub, baseUrl;
  final bool local;
  const _Preset(this.label, this.sub, this.baseUrl, {this.local = false});
}

List<_Preset> _presets(BuildContext c) {
  final local = AppLocalizations.of(c)?.coachLocalSub ??
      'On this network. Nothing leaves your machine.';
  return <_Preset>[
    _Preset('Ollama', local, 'http://localhost:11434/v1', local: true),
    _Preset('LM Studio', local, 'http://localhost:1234/v1', local: true),
    _Preset('OpenAI', 'api.openai.com', 'https://api.openai.com/v1'),
    _Preset('Anthropic', 'api.anthropic.com', 'https://api.anthropic.com/v1'),
    _Preset('OpenRouter', 'openrouter.ai', 'https://openrouter.ai/api/v1'),
  ];
}

class CoachSetup extends StatefulWidget {
  const CoachSetup({super.key});

  @override
  State<CoachSetup> createState() => _CoachSetupState();
}

class _CoachSetupState extends State<CoachSetup> {
  late final TextEditingController _base;
  late final TextEditingController _key;
  late final TextEditingController _search;
  String _model = '';
  List<String> _models = const [];
  bool _loading = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<CoachConfig>();
    _base = TextEditingController(text: cfg.baseUrl);
    _key = TextEditingController(text: cfg.apiKey ?? '');
    _search = TextEditingController();
    _model = cfg.model;
    // The base URL decides which preset is lit and whether a key is needed, and
    // the search box filters the list — both are read during build, so both
    // have to rebuild it.
    void redraw() {
      if (mounted) setState(() {});
    }

    _base.addListener(redraw);
    _search.addListener(redraw);
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _search.dispose();
    super.dispose();
  }

  bool get _isLocal {
    final h = Uri.tryParse(_base.text.trim())?.host.toLowerCase() ?? '';
    return h == 'localhost' || h == '127.0.0.1' || h == '::1';
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _msg = null;
    });
    try {
      final ids = await CoachEngine.fetchModels(_base.text, _key.text);
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      setState(() {
        _models = ids;
        _msg = ids.isEmpty
            ? (l?.coachNoModelsListed ??
                'That endpoint listed no models. Type one below instead.')
            : (l?.coachModelsFound(ids.length) ?? '${ids.length} models. Tap one.');
      });
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      setState(
        () => _msg = e is CoachException
            ? e.message
            : (l?.coachEndpointUnreachable('$e') ?? 'Could not reach that endpoint: $e'),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final chosen = _model.isNotEmpty ? _model : _search.text.trim();
    final l = AppLocalizations.of(context);
    if (chosen.isEmpty) {
      setState(() => _msg = l?.coachPickModelFirst ?? 'Pick or type a model first.');
      return;
    }
    final cfg = context.read<CoachConfig>();
    final nav = Navigator.of(context);
    // An empty key field means "delete my key" ONLY when we could show the user
    // what they are deleting. A key that could not be read seeds the field empty
    // through no fault of theirs, and saving would delete it unseen.
    final blindClear = _key.text.trim().isEmpty && cfg.apiKey == null;
    try {
      await cfg.save(
        baseUrl: _base.text,
        apiKey: blindClear ? null : _key.text,
        model: chosen,
      );
    } catch (e) {
      if (mounted) {
        setState(() =>
            _msg = l?.coachKeychainRefused('$e') ?? 'The keychain refused the key: $e');
      }
      return;
    }
    if (mounted && nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final q = _search.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? _models
        : [
            for (final m in _models)
              if (m.toLowerCase().contains(q)) m,
          ];
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(l?.coachSetupNavTitle ?? 'AI settings',
                  sub: l?.coachSetupNavSub ?? 'Bring your own model'),
            ),
            Expanded(
              child: ListView(
                padding: pad,
                children: [
                  Section(
                    l?.coachWhereModelRuns ?? 'Where the model runs',
                    Column(
                      children: [
                        for (final preset in _presets(c))
                          Padding(
                            padding: const EdgeInsets.only(bottom: S.x2),
                            child: Surface(
                              elevation: 0,
                              color: _base.text.trim() == preset.baseUrl
                                  ? p.wash(
                                      preset.local ? C.green : kCoachAccent,
                                    )
                                  : p.card2,
                              onTap: () => setState(() {
                                _base.text = preset.baseUrl;
                                _models = const [];
                                _model = '';
                                _msg = null;
                              }),
                              child: Row(
                                children: [
                                  Icon(
                                    preset.local
                                        ? LucideIcons.house
                                        : LucideIcons.cloud,
                                    size: 17,
                                    color: p.on(
                                      preset.local ? C.green : kCoachAccent,
                                    ),
                                  ),
                                  const SizedBox(width: S.x3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          preset.label,
                                          style: F.body.copyWith(
                                            color: p.ink,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          preset.sub,
                                          style: F.cap.copyWith(color: p.ink3),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: S.x2),
                  OsTextField(
                    controller: _base,
                    label: l?.coachBaseUrlLabel ?? 'Base URL',
                    hint: 'http://localhost:11434/v1',
                  ),
                  const SizedBox(height: S.x4),
                  OsTextField(
                    controller: _key,
                    label: _isLocal
                        ? (l?.coachApiKeyLocalLabel ?? 'API key (not needed locally)')
                        : (l?.coachApiKeyLabel ?? 'API key'),
                    hint: 'sk-…',
                  ),
                  const SizedBox(height: S.x3),
                  // The one sentence that decides whether a cloud key is a
                  // reasonable choice. It is here, next to the field, and not
                  // in a settings page nobody opens.
                  Text(
                    _isLocal
                        ? (l?.coachLocalDataNote ??
                            'Your questions and the rows the coach reads stay on '
                                'your own machine.')
                        : (l?.coachCloudDataNote ??
                            'Your questions and the rows the coach reads are sent '
                                'to this endpoint. See exactly what that is on '
                                '"What was sent".'),
                    style: F.cap.copyWith(color: p.ink3, height: 1.5),
                  ),
                  const SizedBox(height: S.x4),
                  BigButton(
                    _loading ? (l?.coachAsking ?? 'Asking…') : (l?.coachListModels ?? 'List models'),
                    icon: LucideIcons.refreshCw,
                    color: kCoachAccent,
                    soft: true,
                    onTap: _loading ? null : _fetch,
                  ),
                  if (_msg != null) ...[
                    const SizedBox(height: S.x3),
                    Text(_msg!, style: F.cap.copyWith(color: p.ink3)),
                  ],
                  const SizedBox(height: S.x4),
                  OsTextField(
                    controller: _search,
                    label: l?.coachModelLabel ?? 'Model',
                    hint: l?.coachModelHint ?? 'search, or type an id',
                  ),
                  const SizedBox(height: S.x1),
                  Builder(
                    builder: (_) => Padding(
                      padding: const EdgeInsets.only(top: S.x2),
                      child: Column(
                        children: [
                          for (final m in shown.take(60))
                            Pressable(
                              onTap: () => setState(() => _model = m),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: S.x3,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      m == _model
                                          ? LucideIcons.circleCheck
                                          : LucideIcons.circle,
                                      size: 16,
                                      color: m == _model
                                          ? p.on(kCoachAccent)
                                          : p.ink3,
                                    ),
                                    const SizedBox(width: S.x3),
                                    Expanded(
                                      child: Text(
                                        m,
                                        style: F.cap.copyWith(color: p.ink),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: S.x4),
                  BigButton(
                    l?.actionSave ?? 'Save',
                    icon: LucideIcons.check,
                    color: kCoachAccent,
                    onTap: _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
