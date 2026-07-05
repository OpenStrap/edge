// JournalComposeScreen — the pre-sleep "log your day" entry point, deep-linked
// from the bedtime notification (and reachable from the Journal screen).
//
// TWO modes, one save path:
//   Quick log — tag chips + a short note, exactly the journal's data model.
//   AI chat   — tell the AI about your day (TEXT only); it proposes a
//               structured entry (tags + note) which is shown VERBATIM and
//               saved only when the user taps save.
// Both merge into the existing day row via repo.postJournal (tags union, note
// append) and set the once-per-night "done" flag so tonight's prompt stands
// down. No key → the chat tab shows an honest add-key wall; quick log always
// works (journaling never depends on the AI).

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart';
import '../../ai/journal_ai.dart';
import '../../coach/coach_config.dart';
import '../../state/app_state.dart';
import '../../data/day_label.dart';
import '../../theme/theme_switcher.dart';
import '../coach/coach_settings_screen.dart';
import '../design/design.dart';

class JournalComposeScreen extends StatefulWidget {
  /// Test seam — production builds the engine from the ambient CoachConfig.
  final JournalAiEngine? engineOverride;

  const JournalComposeScreen({super.key, this.engineOverride});

  @override
  State<JournalComposeScreen> createState() => _JournalComposeScreenState();
}

class _ChatMsg {
  final bool user;
  final String text;
  const _ChatMsg(this.user, this.text);
}

class _JournalComposeScreenState extends State<JournalComposeScreen> {
  int _mode = 0; // 0 = quick log, 1 = AI chat

  // ── quick log state (prefilled from today's existing row) ───────────────────
  final Set<String> _tags = <String>{};
  final _noteCtrl = TextEditingController();
  bool _saving = false;
  bool _loaded = false;
  List<String> _existingTags = const [];
  String _existingNote = '';

  // ── AI chat state ─────────────────────────────────────────────────────────────
  JournalAiEngine? _engine;
  final _chatCtrl = TextEditingController();
  final List<_ChatMsg> _msgs = [];
  bool _chatBusy = false;
  List<String> _proposedTags = const [];
  String _proposedNote = '';

  String get _today => todayLabel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefill());
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    final repo = context.read<AppState>().repo;
    if (repo == null) {
      setState(() => _loaded = true);
      return;
    }
    try {
      final rows = await repo.getJournal(range: '2d');
      final today = rows.where((r) => r['date'] == _today).toList();
      if (today.isNotEmpty) {
        _existingTags = [
          for (final t in (today.first['tags'] as List? ?? const []))
            t.toString(),
        ];
        _existingNote = (today.first['note'] as String?) ?? '';
        _tags.addAll(_existingTags);
        _noteCtrl.text = _existingNote;
      }
    } catch (_) {/* fresh editor */}
    if (mounted) setState(() => _loaded = true);
  }

  // ── the ONE save path (both modes) ───────────────────────────────────────────

  Future<void> _save(List<String> tags, String note) async {
    final app = context.read<AppState>();
    final repo = app.repo;
    if (repo == null || _saving) return;
    setState(() => _saving = true);
    try {
      final merged = mergeJournalEntry(
        existingTags: _existingTags,
        existingNote: _existingNote,
        newTags: tags,
        newNote: note,
      );
      await repo.postJournal(_today, merged.tags, merged.note);
      BriefingStore.markJournalDone(_today);
      await app.refreshAiReminders(); // tonight's prompt stands down
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logged for tonight — sleep well.')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    }
  }

  /// Quick log saves the editor VERBATIM (it already contains the existing
  /// row), so merge against empty-existing to avoid double-append.
  Future<void> _saveQuick() async {
    _existingTags = const [];
    _existingNote = '';
    await _save(_tags.toList(), _noteCtrl.text.trim());
  }

  // ── AI chat ──────────────────────────────────────────────────────────────────

  JournalAiEngine _ensureEngine() => _engine ??= widget.engineOverride ??
      JournalAiEngine(config: context.read<CoachConfig>());

  Future<void> _sendChat() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || _chatBusy) return;
    final engine = _ensureEngine();
    setState(() {
      _msgs.add(_ChatMsg(true, text));
      _chatCtrl.clear();
      _chatBusy = true;
    });
    try {
      final turn = await engine.send(text);
      if (!mounted) return;
      setState(() {
        _chatBusy = false;
        if (turn.reply.isNotEmpty) _msgs.add(_ChatMsg(false, turn.reply));
        if (turn.tags.isNotEmpty || turn.note.isNotEmpty) {
          _proposedTags = turn.tags;
          _proposedNote = turn.note;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _chatBusy = false;
        _msgs.add(_ChatMsg(
            false,
            'I couldn\'t reach your AI provider — your words above aren\'t '
            'lost. Try again, or switch to Quick log.'));
      });
    }
  }

  // ── build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final aiReady = widget.engineOverride != null ||
        context.watch<CoachConfig>().configured;
    return AppScaffold(
      title: 'Log your day',
      children: [
        if (BriefingStore.journalDoneToday())
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x3),
            child: const StatusChip('Logged for today',
                icon: null, tone: ChipTone.positive),
          ).dsEnter(),
        SegmentedControl(
          options: const ['Quick log', 'AI chat'],
          index: _mode,
          expanded: true,
          onChanged: (i) => setState(() => _mode = i),
        ).dsEnter(index: 1),
        const SizedBox(height: Sp.x4),
        ...(_mode == 0 ? _quickLog() : _aiChat(aiReady)),
        const SizedBox(height: Sp.x8),
      ],
    );
  }

  // ── quick log UI ─────────────────────────────────────────────────────────────

  List<Widget> _quickLog() => [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('HOW WAS TODAY?', style: AppText.overline),
              const SizedBox(height: Sp.x3),
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final t in kJournalPresetTags) _chip(t),
                ],
              ),
              const SizedBox(height: Sp.x4),
              TextField(
                controller: _noteCtrl,
                minLines: 2,
                maxLines: 5,
                enabled: _loaded,
                style: AppText.body,
                decoration: InputDecoration(
                  hintText: 'Anything notable — mood, energy, what happened…',
                  hintStyle:
                      AppText.bodySoft.copyWith(color: AppColors.inkMuted),
                  filled: true,
                  fillColor: AppColors.surfaceAlt,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(R.cardSm),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: Sp.x4),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _saveQuick,
                  child: Text(_saving ? 'Saving…' : 'Save to journal'),
                ),
              ),
            ],
          ),
        ).dsEnter(index: 2),
      ];

  Widget _chip(String tag) {
    final on = _tags.contains(tag);
    return Pressable(
      borderRadius: BorderRadius.circular(R.pill),
      onTap: () => setState(() => on ? _tags.remove(tag) : _tags.add(tag)),
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: on ? AppColors.accentSoft : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: on ? AppColors.onAccentSoft : AppColors.divider,
            width: on ? 1.2 : 1,
          ),
        ),
        child: Text(
          tag,
          style: AppText.label.copyWith(
            color: on ? AppColors.onAccentSoft : AppColors.inkSoft,
          ),
        ),
      ),
    );
  }

  // ── AI chat UI ───────────────────────────────────────────────────────────────

  List<Widget> _aiChat(bool aiReady) {
    if (!aiReady) {
      return [
        const SizedBox(height: Sp.x4),
        StateCard(
          icon: Ic.ai,
          osIcon: OsIcon.ai,
          title: 'Bring your own AI',
          message:
              'Add your AI key to talk through your day and have it logged '
              'for you. Quick log works without one.',
          actionLabel: 'Add your AI key',
          onAction: () => Navigator.of(context)
              .push(themedRoute((_) => const CoachSettingsScreen())),
        ).dsEnter(index: 2),
      ];
    }
    return [
      if (_msgs.isEmpty)
        SurfaceCard(
          level: 0,
          child: Text(
            'Tell me about your day — training, caffeine, stress, how you '
            'feel. I\'ll turn it into a journal entry you can review before '
            'it\'s saved.',
            style: AppText.bodySoft,
          ),
        ).dsEnter(index: 2),
      for (var i = 0; i < _msgs.length; i++) _bubble(_msgs[i], i),
      if (_chatBusy)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.x3),
          child: Row(children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.onAccentSoft),
            ),
            const SizedBox(width: Sp.x2),
            Text('Listening…', style: AppText.captionMuted),
          ]),
        ),
      if (_proposedTags.isNotEmpty || _proposedNote.isNotEmpty)
        _proposalCard(),
      const SizedBox(height: Sp.x3),
      _inputRow(),
    ];
  }

  Widget _bubble(_ChatMsg m, int i) =>
      JournalChatBubble(user: m.user, text: m.text);

  Widget _proposalCard() => JournalProposalCard(
        tags: _proposedTags,
        note: _proposedNote,
        saving: _saving,
        onSave: () => _save(_proposedTags, _proposedNote),
      );

  Widget _inputRow() => Row(children: [
        Expanded(
          child: TextField(
            controller: _chatCtrl,
            style: AppText.body,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendChat(),
            decoration: InputDecoration(
              hintText: 'How did today go?',
              hintStyle: AppText.bodySoft.copyWith(color: AppColors.inkMuted),
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
          Icons.arrow_upward_rounded,
          bg: AppColors.ink,
          fg: AppColors.surface,
          onTap: _chatBusy ? null : _sendChat,
        ),
      ]);
}

// ── pure presentation widgets (render-testable) ────────────────────────────────

/// One compose-chat message on the design tokens: soft-accent user bubble on
/// the right, bordered markdown assistant bubble on the left.
class JournalChatBubble extends StatelessWidget {
  final bool user;
  final String text;
  const JournalChatBubble({super.key, required this.user, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
            decoration: BoxDecoration(
              color: user ? AppColors.accentSoft : AppColors.surface,
              borderRadius: BorderRadius.circular(R.cardSm),
              border: user ? null : Border.all(color: AppColors.divider),
            ),
            child: user
                ? Text(text,
                    style: AppText.body.copyWith(color: AppColors.onAccentSoft))
                : GptMarkdown(text, style: AppText.body),
          ),
        ),
      ),
    );
  }
}

/// The verbatim entry the AI proposes — the user sees EXACTLY what will be
/// written before anything touches the journal.
class JournalProposalCard extends StatelessWidget {
  final List<String> tags;
  final String note;
  final bool saving;
  final VoidCallback? onSave;
  const JournalProposalCard({
    super.key,
    required this.tags,
    required this.note,
    this.saving = false,
    this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: SurfaceCard(
        level: 2,
        accentGlow: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WILL BE LOGGED', style: AppText.overline),
            const SizedBox(height: Sp.x3),
            if (tags.isNotEmpty)
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final t in tags) StatusChip(t, tone: ChipTone.accent),
                ],
              ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: Sp.x3),
              Text(note, style: AppText.body),
            ],
            const SizedBox(height: Sp.x4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: saving ? null : onSave,
                child: Text(saving ? 'Saving…' : 'Save to journal'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
