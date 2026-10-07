import 'coach_text.dart';
// THE DATA BOUNDARY — the daily briefing, and exactly what left the device to
// produce it.
//
// `Briefing.inputs` is the compact metric snapshot the prompt was built from,
// stored beside every briefing since the engine was written. Nothing ever read
// it. That map IS the payload — `buildBriefingUserPrompt` writes one `key: value`
// line per entry and adds nothing — so this screen can state, exactly and
// without hedging, what a third party received.
//
// For an app whose whole argument is that the data stays on the phone, this is
// not a nicety. It is the thing that makes choosing a cloud key a decision
// rather than a leap, and it is why the local presets come first in setup.

import '../../l10n/display_text.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart';
import '../../ai/briefing_engine.dart';
import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart' show CoachException;
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'coach.dart' show CoachSetup, kCoachAccent;
import 'home_screen.dart' show go, pad, repoOf;

class AiBriefingScreen extends StatefulWidget {
  final BriefingPeriod period;
  const AiBriefingScreen({super.key, required this.period});

  @override
  State<AiBriefingScreen> createState() => _AiBriefingScreenState();
}

class _AiBriefingScreenState extends State<AiBriefingScreen> {
  Briefing? _b;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _b = BriefingStore.read(widget.period);
  }

  Future<void> _generate() async {
    final repo = repoOf(context);
    if (repo == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final b = await BriefingEngine(
        config: context.read<CoachConfig>(),
        repo: repo,
      ).generate(widget.period);
      if (mounted) setState(() => _b = b);
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        setState(
          () => _error = e is CoachException
              ? coachPresentationText(l, e.message)
              : (l?.aiBriefingFailedGeneric('$e') ?? 'It failed: $e'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cfg = c.watch<CoachConfig>();
    final b = _b;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(
                uiText(c, widget.period.title),
                sub: b == null
                    ? ''
                    : (l?.aiBriefingForDay(b.day) ?? 'FOR ${b.day}'),
              ),
            ),
            Expanded(
              child: ListView(
                padding: pad,
                children: [
                  const SizedBox(height: S.x2),
                  if (!cfg.configured)
                    StatusCard(
                      l?.aiBriefingNoModelTitle ?? 'No model is set up',
                      l?.aiBriefingNoModelBody ??
                          'A briefing is written by a model you choose. Until you '
                              'pick one there is nothing to generate and nothing '
                              'has been sent anywhere.',
                      fix: l?.aiBriefingChooseModel ?? 'Choose a model',
                      icon: LucideIcons.sparkles,
                      onFix: () => go(c, const CoachSetup()),
                    )
                  else if (b == null)
                    StatusCard(
                      l?.aiBriefingNothingTitle ?? 'Nothing written for today',
                      l?.aiBriefingNothingBody ??
                          'Briefings are generated on a schedule, or on demand '
                              'here.',
                      fix: _busy
                          ? (l?.aiBriefingWriting ?? 'Writing…')
                          : (l?.aiBriefingWriteNow ?? 'Write one now'),
                      icon: LucideIcons.sun,
                      onFix: _busy ? null : _generate,
                    )
                  else ...[
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.oneLiner == 'Nothing stood out tonight.'
                                ? uiText(c, b.oneLiner)
                                : b.oneLiner,
                            style: F.body.copyWith(color: p.ink, height: 1.5),
                          ),
                          if (b.breakdownMd.isNotEmpty) ...[
                            const SizedBox(height: S.x3),
                            Text(
                              b.breakdownMd,
                              style: F.cap.copyWith(color: p.ink2, height: 1.6),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: S.x3),
                    BigButton(
                      _busy
                          ? (l?.aiBriefingWriting ?? 'Writing…')
                          : (l?.aiBriefingWriteAgain ?? 'Write it again'),
                      icon: LucideIcons.refreshCw,
                      color: kCoachAccent,
                      soft: true,
                      onTap: _busy ? null : _generate,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: S.x3),
                    StatusCard(
                      l?.aiBriefingFailedTitle ?? 'That did not go through',
                      _error!,
                      icon: LucideIcons.triangleAlert,
                    ),
                  ],
                  if (b != null)
                    SentPayload(
                      inputs: b.inputs,
                      config: cfg,
                      asked: b.calledModel,
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

/// What was sent, in full. Not a summary of it — the same map, every key.
///
/// A screen that showed "12 metrics" would be worse than nothing: it asks to be
/// trusted about the exact question it exists to answer.
class SentPayload extends StatelessWidget {
  final Map<String, dynamic> inputs;
  final CoachConfig config;

  /// Whether a model was called at all — [Briefing.calledModel]. False for a
  /// nightly sweep that found nothing: there was no request, so the banner may
  /// not describe one.
  final bool asked;

  const SentPayload({
    super.key,
    required this.inputs,
    required this.config,
    this.asked = true,
  });

  /// True when the endpoint is on this machine, in which case nothing left it.
  static bool isLocal(String base) {
    final h = Uri.tryParse(base)?.host.toLowerCase() ?? '';
    return h == 'localhost' || h == '127.0.0.1' || h == '::1';
  }

  static String _label(String key) {
    final s = key.replaceAll('_', ' ');
    return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
  }

  /// Verbatim, because this is a preview of a payload and not a metric card.
  /// [buildBriefingUserPrompt] writes `$v` for every entry, so a null reaches
  /// the model as the word `null` and this has to say the same — an em dash
  /// here would read as "withheld" for a value that was in fact sent, empty.
  /// (`_put` drops absent metrics before they get this far, so this is the
  /// belt and not the trousers.)
  static String _value(dynamic v) => v is List ? v.join(', ') : '$v';

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final host = Uri.tryParse(config.apiBase)?.host ?? config.apiBase;
    final local = isLocal(config.apiBase);
    final keys = inputs.keys.toList()..sort();
    // An empty payload is not "we sent an empty payload". The nightly sweep
    // calls no model at all on a day with no finding, so the banner must not go
    // on describing a request that never happened.
    final none = !asked;
    return Section(
      none || !local
          ? (l?.aiBriefingSentSection ?? 'What was sent')
          : (l?.aiBriefingReadSection ?? 'What was read'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Surface(
            elevation: 0,
            color: p.wash(none || local ? C.green : C.orange),
            child: Row(
              children: [
                Icon(
                  none || local
                      ? LucideIcons.house
                      : LucideIcons.cloudUpload,
                  size: 17,
                  color: p.on(none || local ? C.green : C.orange),
                ),
                const SizedBox(width: S.x3),
                Expanded(
                  child: Text(
                    none
                        ? (l?.aiBriefingNoneBody ??
                            'Nothing. There was no request — the note above was '
                                'written on this phone.')
                        : local
                            ? (l?.aiBriefingLocalBody(host) ??
                                'These numbers went to $host, on this machine. '
                                    'Nothing left it.')
                            : (l?.aiBriefingCloudBody(host, config.model) ??
                                'These numbers, and nothing else, were sent to '
                                    '$host as ${config.model}. No raw '
                                    'recordings, no name, no identifier.'),
                    style: F.cap.copyWith(color: p.ink, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: S.x3),
          if (none)
            StatusCard(
              l?.aiBriefingNoneCardTitle ?? 'Nothing stood out, so nothing was asked',
              l?.aiBriefingNoneCardBody ??
                  'The sweep runs on this phone. It only calls a model when it has '
                      'a finding to hand it, and today it had none.',
              icon: LucideIcons.circleSlash,
            )
          else if (keys.isEmpty)
            StatusCard(
              l?.aiBriefingEmptyCardTitle ?? 'Nothing was available to send',
              l?.aiBriefingEmptyCardBody ??
                  'No metric had a value when this was written, so the prompt '
                      'carried none.',
              icon: LucideIcons.circleSlash,
            )
          else
            Surface(
              pad: const EdgeInsets.symmetric(
                horizontal: S.x4,
                vertical: S.x2,
              ),
              child: Column(
                children: [
                  for (final k in keys)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: S.x2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              uiText(c, _label(k)),
                              style: F.cap.copyWith(color: p.ink3),
                            ),
                          ),
                          const SizedBox(width: S.x3),
                          Flexible(
                            child: Text(
                              _value(inputs[k]),
                              textAlign: TextAlign.right,
                              style: F.cap.copyWith(color: p.ink),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
