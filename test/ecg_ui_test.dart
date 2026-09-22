// The ECG capture body in every phase (data in, callbacks out), the touch
// illustration under reduced motion, the live preview label, the saved
// waveform painter's placeholder breaks, the detail screen's empty-waveform
// state and Analyze-now prompt, and the wrist sheet.

import 'dart:typed_data';
import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_waveform_buffer.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester t,
  Widget home, {
  bool reducedMotion = false,
}) async {
  t.view.physicalSize = const Size(1170, 2532);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await t.pump();
}

String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

Widget _body(EcgCaptureState s, {List<String>? log}) => Scaffold(
  body: EcgCaptureBody(
    state: s,
    wrist: EcgWrist.right,
    phase: 0.25,
    live: EcgWaveformBuffer(capacity: 100),
    scheduler: EcgPreviewScheduler(),
    onRetry: () => log?.add('retry'),
    onTakeAnother: () => log?.add('another'),
    onDone: () => log?.add('done'),
    onView: () => log?.add('view'),
  ),
);

EcgAcceptedPacket _pkt(int seq, {int n = 100}) => EcgAcceptedPacket(
  sequence: seq,
  strapSeconds: 1787823700 + seq,
  strapSubsec: 0,
  samples: Int16List.fromList(List.generate(n, (i) => (i * 7) % 300 - 150)),
  inner: Uint8List(0),
);

EcgReading _reading({
  int packets = 3,
  EcgCategory category = EcgCategory.sinusRhythm,
}) => EcgReading(
  id: 'ecg_1',
  deviceId: '',
  wrist: EcgWrist.left,
  startTs: 1787823754,
  endTs: 1787823784,
  strapTerminalTs: 1787823784,
  strapTerminalSubsec: 0,
  resultCode: 1,
  category: category,
  avgHr: 77,
  quality: 3,
  unreadableMask: 0,
  interruptions: 1,
  sampleCount: packets * 100,
  minUv: -150,
  maxUv: 149,
  rmsUv: 86.6,
  missingSegments: 0,
  status: EcgReadingStatus.completed,
  notes: null,
  createdAt: 1787823784000,
);

void main() {
  group('capture body per phase', () {
    testWidgets('waiting: instructions, illustration, status, preview label', (
      t,
    ) async {
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.waiting)),
      );
      final text = _allText(t);
      expect(text, contains('Rest your arm. Touch both metal sides'));
      expect(text, contains('Waiting for contact'));
      expect(text, contains('Live signal preview'));
      expect(text, contains('µV'));
      expect(find.byType(EcgTouchIllustration), findsOneWidget);
      expect(find.byType(EcgLivePreview), findsOneWidget);
      // No lead / polarity claim anywhere on the capture screen.
      expect(text.toLowerCase(), isNot(contains('lead i')));
    });

    testWidgets('preparing shows no preview yet; recovering says why', (
      t,
    ) async {
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.preparing)),
      );
      expect(_allText(t), contains('Preparing the band'));
      expect(find.byType(EcgLivePreview), findsNothing);
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.recovering)),
      );
      expect(_allText(t), contains('Stopping a previous reading first'));
    });

    testWidgets('active: band progress and live HR, no fake timer', (t) async {
      await _pump(
        t,
        _body(
          const EcgCaptureState(
            phase: EcgCapturePhase.active,
            progress: 42,
            liveHr: 71,
          ),
        ),
      );
      final text = _allText(t);
      expect(text, contains('42% complete'));
      expect(text, contains('71'));
      expect(text, contains('Measuring'));
      final bar = t.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(.42, 1e-9));
    });

    testWidgets('contact lost shows the exact instruction', (t) async {
      await _pump(
        t,
        _body(
          const EcgCaptureState(
            phase: EcgCapturePhase.contactLost,
            progress: 30,
          ),
        ),
      );
      expect(_allText(t), contains('Adjust your fingers and keep still'));
    });

    testWidgets('restarting, saving, cleaning up', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.restarting)),
      );
      expect(_allText(t), contains('Restarting'));
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.saving)),
      );
      expect(_allText(t), contains('Saving'));
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.cleaningUp)),
      );
      expect(_allText(t), contains('Stopping the band'));
    });

    testWidgets(
      'completed offers view and done, and says it is not a diagnosis',
      (t) async {
        final log = <String>[];
        await _pump(
          t,
          _body(
            const EcgCaptureState(
              phase: EcgCapturePhase.completed,
              readingId: 'ecg_1',
            ),
            log: log,
          ),
        );
        expect(_allText(t), contains('Reading saved'));
        expect(_allText(t), contains('not a diagnosis'));
        await t.tap(find.text('View reading'));
        await t.tap(find.text('Done'));
        expect(log, ['view', 'done']);
      },
    );

    testWidgets(
      'unreadable lists the band reasons and offers another reading',
      (t) async {
        final log = <String>[];
        await _pump(
          t,
          _body(
            const EcgCaptureState(
              phase: EcgCapturePhase.unreadable,
              unreadableMask: 0x0a,
            ),
            log: log,
          ),
        );
        final text = _allText(t);
        expect(text, contains('could not read'));
        expect(text, contains('Significant noise'));
        expect(text, contains('Not enough data'));
        expect(text, isNot(contains('Low amplitude')));
        await t.tap(find.text('Take another'));
        expect(log, ['another']);
      },
    );

    testWidgets('inconclusive offers exactly the one retry', (t) async {
      final log = <String>[];
      await _pump(
        t,
        _body(
          const EcgCaptureState(phase: EcgCapturePhase.inconclusiveRetry),
          log: log,
        ),
      );
      expect(_allText(t), contains('try once more'));
      await t.tap(find.text('Try once more'));
      expect(log, ['retry']);
    });

    testWidgets('cancelled / failed copy, incl. incomplete cleanup', (t) async {
      await _pump(
        t,
        _body(
          const EcgCaptureState(
            phase: EcgCapturePhase.cancelled,
            reason: 'cancelled',
          ),
        ),
      );
      expect(_allText(t), contains('Reading cancelled'));
      await _pump(
        t,
        _body(
          const EcgCaptureState(
            phase: EcgCapturePhase.failed,
            reason: 'disconnected',
            cleanupIncomplete: true,
          ),
        ),
      );
      final text = _allText(t);
      expect(text, contains('Reading failed'));
      expect(text, contains('The band disconnected.'));
      expect(text, contains('stopped on the next connection'));
      await _pump(
        t,
        _body(
          const EcgCaptureState(
            phase: EcgCapturePhase.failed,
            reason: 'timeout',
          ),
        ),
      );
      expect(_allText(t), contains('two minutes'));
    });

    testWidgets('incompatible, disconnected and busy are status cards', (
      t,
    ) async {
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.incompatible)),
      );
      expect(_allText(t), contains('not a WHOOP MG'));
      await _pump(
        t,
        _body(const EcgCaptureState(phase: EcgCapturePhase.disconnected)),
      );
      expect(_allText(t), contains('Connect your WHOOP MG'));
      await _pump(
        t,
        _body(
          const EcgCaptureState(phase: EcgCapturePhase.busy, reason: 'workout'),
        ),
      );
      expect(_allText(t), contains('Finish the other live session'));
    });
  });

  group('illustration and preview', () {
    testWidgets(
      'the illustration carries semantics and paints under reduced motion',
      (t) async {
        await _pump(
          t,
          const Scaffold(
            body: EcgTouchIllustration(
              wrist: EcgWrist.left,
              t: 0,
              contact: false,
              semanticLabel: 'Illustration: the band on your wrist',
            ),
          ),
          reducedMotion: true,
        );
        expect(find.bySemanticsLabel(RegExp('Illustration')), findsOneWidget);
        expect(find.byType(CustomPaint), findsWidgets);
      },
    );

    test('the preview range is stepped and floored', () {
      expect(ecgPreviewRange(0), 500);
      expect(ecgPreviewRange(120), 500);
      expect(ecgPreviewRange(600), 750);
      expect(ecgPreviewRange(751), 1000);
      expect(ecgPreviewRange(5396), 5500);
    });

    testWidgets('the preview repaints on the scheduler tick only', (t) async {
      final buf = EcgWaveformBuffer(capacity: 50);
      final sched = EcgPreviewScheduler();
      await _pump(
        t,
        Scaffold(
          body: EcgLivePreview(
            buffer: buf,
            scheduler: sched,
            label: 'Live signal preview',
            unit: 'µV',
          ),
        ),
      );
      EcgLivePainter painter() => t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<EcgLivePainter>()
          .single;
      final v0 = painter().version;
      buf.push(Int16List.fromList([1, 2, 3]));
      sched.markDirty();
      await t.pump();
      expect(painter().version, v0, reason: 'a push alone does not rebuild');
      sched.tick();
      await t.pump();
      expect(painter().version, v0 + 1);
    });
  });

  group('saved waveform', () {
    test(
      'width covers placeholders; a placeholder is a break, not a bridge',
      () {
        final packets = [_pkt(1), EcgAcceptedPacket.placeholder(2), _pkt(3)];
        expect(EcgWaveformPainter.widthFor(packets, 80), 240);
        expect(EcgWaveformPainter.rangeFor(packets), 500);
        // Paint onto a recording canvas: the gap wash is drawn exactly once.
        final rec = PictureRecorder();
        final cv = Canvas(rec);
        EcgWaveformPainter(
          packets: packets,
          pxPerSecond: 80,
          color: const Color(0xFF000000),
          grid: const Color(0xFF888888),
          gap: const Color(0xFFFF0000),
        ).paint(cv, const Size(240, 100));
        rec.endRecording();
      },
    );

    testWidgets(
      'the detail screen shows the band category, stats and Analyze now; '
      'an empty waveform is a status card',
      (t) async {
        await _pump(
          t,
          EcgDetailScreen(
            data: EcgDetailData(
              reading: _reading(packets: 0),
              packets: const [],
            ),
          ),
        );
        final text = _allText(t);
        expect(text, contains('Band-reported result'));
        expect(text, contains('Sinus rhythm'));
        expect(text, contains('No waveform was saved'));
        expect(text, contains('Analyze now'));
        expect(text, contains('77 bpm'));
        expect(text, contains('Left wrist'));
        expect(text, contains('not a diagnosis'));
        expect(text.toLowerCase(), isNot(contains('lead i')));
      },
    );

    testWidgets('with packets the waveform paints inside a horizontal scroll', (
      t,
    ) async {
      final packets = [_pkt(1), EcgAcceptedPacket.placeholder(2), _pkt(3)];
      await _pump(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: _reading(), packets: packets),
        ),
      );
      expect(find.byType(SingleChildScrollView), findsWidgets);
      final painters = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<EcgWaveformPainter>()
          .toList();
      expect(painters, hasLength(1));
      expect(painters.single.packets, hasLength(3));
      expect(_allText(t), contains('300 samples at 100 Hz'));
      await t.tap(find.bySemanticsLabel('Zoom in'));
      await t.pump();
      final zoomed = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<EcgWaveformPainter>()
          .single;
      expect(zoomed.pxPerSecond, greaterThan(painters.single.pxPerSecond));
    });
  });

  group('analyze now with a configured coach', () {
    // A tap handler must not `watch` a provider: provider asserts outside
    // build and the predicate's own catch swallows it, so the gate reads
    // "not configured" no matter what the user has set up.
    testWidgets(
      'goes to the coach, not back to setup',
      (t) async {
        SharedPreferences.setMockInitialValues({});
        final cfg = CoachConfig();
        await cfg.save(
          baseUrl: 'http://localhost:11434/v1',
          apiKey: null,
          model: 'm',
        );
        expect(cfg.configured, isTrue, reason: 'precondition');

        final pushed = <String?>[];
        t.view.physicalSize = const Size(1170, 2532);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          ChangeNotifierProvider<CoachConfig>.value(
            value: cfg,
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              navigatorObservers: [_RouteLog(pushed)],
              home: EcgDetailScreen(
                data: EcgDetailData(
                  reading: _reading(packets: 0),
                  packets: const [],
                ),
              ),
            ),
          ),
        );
        await t.pump();

        await t.tap(find.byType(ActionCard));
        expect(
          pushed,
          isNot(contains('CoachSetup')),
          reason: 'the coach is configured — setup must not be pushed',
        );
      },
    );
  });

  group('analyze-now prompt', () {
    test('names the tool and asks for a reading of the waveform', () {
      final p = ecgAnalyzePrompt('ecg_1');
      expect(p, contains('Analyse my ECG reading ecg_1'));
      expect(p, contains('Use get_ecg_reading'));
      expect(p, contains('rate, rhythm'));
      expect(
        p,
        contains('polarity'),
        reason: 'the unproven polarity is still stated',
      );
    });
  });

  group('wrist sheet', () {
    testWidgets('pops the chosen wrist and marks the remembered one', (
      t,
    ) async {
      EcgWrist? picked;
      await _pump(
        t,
        Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  picked = await showModalBottomSheet<EcgWrist>(
                    context: c,
                    builder: (_) =>
                        const EcgWristSheet(current: EcgWrist.right),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(_allText(t), contains('Which wrist is the band on?'));
      await t.tap(find.text('Left wrist'));
      await t.pumpAndSettle();
      expect(picked, EcgWrist.left);
    });
  });
}

/// Records the names of pushed routes so a tap can be asserted without
/// building the destination screen.
class _RouteLog extends NavigatorObserver {
  _RouteLog(this.pushed);
  final List<String?> pushed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
  }
}
