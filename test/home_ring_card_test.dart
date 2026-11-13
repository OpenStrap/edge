// RED (Home + labels, phase 0). WHY: the Home ring card should explain the
// readings that need explaining INSIDE the card, so the user does not open
// three detail screens to learn why a ring is low. Today the card ends in a
// loose "Why? HRV · Resting heart rate · Breathing rate" footer, every absent
// ring's reason as its own divider row, and the recovery update as bare grey
// text. The upgrade replaces them with up to TWO inset rows in one fixed slot
// at the bottom of the card:
//
//   1. a "why" panel for each of the (at most two) most pressing rings,
//   2. then the recovery update note ("Updated 08:12 · 62 → 58"),
//   3. then an absent ring's reason (its title over the pipeline's reason).
//
// Pressing means: recovery under 37 (severity 3 under 26, 2 for 26-36), sleep
// under 85% of need (3 under 70%), strain above the top of today's target. A
// ring with no value, a provisional or in-progress recovery is NEVER pressing
// (never fabricate). The recovery why copy is the plain score: no driver list
// belongs to the composite ring, so none is blamed.
//
// Ported/adapted from the fork's ui2_home_card_test, ui2_home_card_fix_test,
// ui2_home_card_r3_test, ui2_home_update_note_test and home_help_strip_why_test.
// OUT of this file on purpose: the "since hh:mm" overlay and hold semantics
// (need dayRecordingsThrough / staleHold), the older-calculation row, the
// observation row and the review prompt (other PRs).
//
// Fixtures are plain constants: no clock, no timezone, no sqflite. The update
// note's time is formatted by the same formatter the app uses, from an epoch
// built with a LOCAL DateTime, so it reads the same on any host zone.
//
// Keys pinned (ValueKey<String>):
//   home-why:<recovery|sleep|strain>        the panel (tappable, opens that ring)
//   home-why-icon:<kind>                    32 pt circle with the RING'S own icon
//   home-why-title:<kind> / home-why-body:<kind>
//   home-update-note / home-update-note-icon
//   home-note:gap:<kind>                    an absent ring's reason row

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/clock_format.dart' show formatClockOf;
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Metric _m(num v) => Metric(value: v, confidence: .8, tier: MetricTier.high);

const _target = {'value': 10, 'low': 8, 'high': 12};

HomeData _data({
  num? recovery = 80,
  num? sleep = 450, // minutes
  num? need = 480,
  num? strain = 5.0,
  Map<String, dynamic>? target,
  String? recoveryState,
  Map<String, dynamic>? update,
}) =>
    HomeData(
      dayId: '2026-10-04',
      recoveryState: recoveryState,
      readiness: recovery == null ? Metric.empty : _m(recovery),
      sleepMin: sleep == null ? Metric.empty : _m(sleep),
      sleepNeedMin: need == null ? Metric.empty : _m(need),
      strain: strain == null ? Metric.empty : _m(strain),
      strainTarget: target,
      readinessUpdate: update,
    );

// 10 -> recovery severity 3; 30 -> severity 2; 66% of 528 min is sleep sev 3.
HomeData get _healthy => _data();
HomeData get _lowRecovery => _data(recovery: 10);
HomeData get _recAndSleep => _data(recovery: 10, sleep: 350, need: 528);
HomeData get _rec2Sleep3 => _data(recovery: 30, sleep: 350, need: 528);
HomeData get _allThree =>
    _data(recovery: 10, sleep: 350, need: 528, strain: 15, target: _target);

final _updateAt = DateTime(2026, 10, 4, 8, 12).millisecondsSinceEpoch;
Map<String, dynamic> get _update => {'from': 62, 'to': 58, 'at': _updateAt};
String get _updateLine =>
    'Updated ${formatClockOf(DateTime.fromMillisecondsSinceEpoch(_updateAt))} · 62 → 58';

void _surface(WidgetTester t, double w, {double scale = 1.0}) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(w, 3200);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Family of the verified Thai face once the caption group has loaded it.
String? _thaiFamily;

ThemeData _themeWithThai() {
  final th = buildTheme(Brightness.light);
  final fam = _thaiFamily;
  if (fam == null) return th;
  return th.copyWith(
      textTheme: th.textTheme.apply(fontFamilyFallback: [fam]));
}

Future<void> _rings(WidgetTester t, HomeData d,
    {void Function(HomeRingKind)? onOpen,
    double w = 390,
    double scale = 1.0,
    Locale? locale}) async {
  _surface(t, w, scale: scale);
  await t.pumpWidget(MaterialApp(
    locale: locale,
    theme: _themeWithThai(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(d: d, onOpen: onOpen))),
  ));
  await t.pump();
}

Finder _why(String k) => find.byKey(ValueKey('home-why:$k'));
final _anyWhy = find.byWidgetPredicate((w) =>
    w.key is ValueKey<String> &&
    (w.key as ValueKey<String>).value.startsWith('home-why:'));
final _note = find.byKey(const ValueKey('home-update-note'));
Finder _gap(String k) => find.byKey(ValueKey('home-note:gap:$k'));
Finder _body(String k) => find.byKey(ValueKey('home-why-body:$k'));

/// The text in [f], failing as an assertion (not a StateError) when absent.
String? _txt(WidgetTester t, Finder f) {
  expect(f, findsOneWidget);
  return t.widget<Text>(f).data;
}

List<String> _whyOrder(WidgetTester t) {
  final all = t.widgetList(_anyWhy).map((w) => (w.key as ValueKey<String>).value);
  return [for (final k in all) k.substring('home-why:'.length)]..sort((a, b) =>
      t.getTopLeft(_why(a)).dy.compareTo(t.getTopLeft(_why(b)).dy));
}

/// The top-left of each ring's label. The rings must not move when rows come
/// and go in the bottom slot (no layout shift above the slot).
Map<String, Offset> _ringPos(WidgetTester t) => {
      for (final l in ['RECOVERY', 'STRAIN', 'SLEEP'])
        l: t.getTopLeft(find.text(l).first),
    };

Map<String, dynamic> _drv(String label, double c, String detail) =>
    {'label': label, 'contribution': c, 'detail': detail};
const _drag = 'dragging your score down';
const _lift = 'lifting your score';

class _Repo extends LocalRepository {
  _Repo(this.drivers, {this.score = 22.0, this.rollupDay});
  final List<Map<String, dynamic>> drivers;
  final double score;
  final String? rollupDay;
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 22, 'confidence': .8, 'tier': 'HIGH'},
        },
        'status': {'today_day': '2026-10-04', 'overnight_state': 'ready'},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => {
        'rollup_day': rollupDay,
        'readiness_glassbox': {
          'score': score,
          'breakdown': const [],
          'drivers': drivers,
          'narrative': '',
          'inputs_used': 3,
        },
      };
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
}

const _thaiFontEnv = 'EDGE_TEST_THAI_FONT';

/// Runs a fontconfig tool against the system configuration: `flutter test`
/// points FONTCONFIG_FILE at its own font-less one, which lists nothing.
ProcessResult _fc(String tool, List<String> args) => Process.runSync(
    tool, args,
    environment: File('/etc/fonts/fonts.conf').existsSync()
        ? {'FONTCONFIG_FILE': '/etc/fonts/fonts.conf'}
        : null);

/// True when [path] has every Thai letter, vowel and digit (U+0E01-0E3A,
/// U+0E3F-0E5B) in its character map, as fontconfig reports it. A face that
/// is merely installed or listed is not enough: FreeSans has no Thai.
bool _coversThai(String path) {
  try {
    final r = _fc('fc-query', ['-f', '%{charset}', path]);
    if (r.exitCode != 0) return false;
    final ranges = <(int, int)>[];
    for (final tok in (r.stdout as String).trim().split(RegExp(r'\s+'))) {
      final p = tok.split('-');
      final lo = int.tryParse(p.first, radix: 16);
      final hi = int.tryParse(p.last, radix: 16);
      if (lo != null && hi != null) ranges.add((lo, hi));
    }
    bool has(int lo, int hi) => ranges.any((e) => e.$1 <= lo && e.$2 >= hi);
    return has(0x0E01, 0x0E3A) && has(0x0E3F, 0x0E5B);
  } on ProcessException {
    return false; // no fontconfig: cannot verify, so do not trust it
  }
}

/// A Thai-capable TrueType face for measuring Thai text, or null. The repo
/// ships none (Manrope has no Thai) and no binary is added. Candidates are the
/// explicit override and what fontconfig lists for Thai; each must pass
/// [_coversThai] before it is used.
File? _thaiFontFile() {
  final candidates = <String>[
    ?Platform.environment[_thaiFontEnv],
  ];
  try {
    final r = _fc('fc-list', [':lang=th', 'file']);
    if (r.exitCode == 0) {
      for (final line in (r.stdout as String).split('\n')) {
        final f = line.split(':').first.trim();
        if (RegExp(r'\.(ttf|otf)$', caseSensitive: false).hasMatch(f)) {
          candidates.add(f);
        }
      }
    }
  } on ProcessException {
    // no fontconfig
  }
  // Prefer a sans face: the app's text is sans.
  candidates.sort((a, b) =>
      (b.contains('Sans') ? 1 : 0) - (a.contains('Sans') ? 1 : 0));
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync() && _coversThai(c)) return f;
  }
  return null;
}

void main() {
  // ── 0. what "pressing" means (pure) ───────────────────────────────────────
  group('pressingRings', () {
    test('WHY: a healthy day explains nothing', () {
      expect(pressingRings(_healthy), isEmpty);
    });

    test('WHY: recovery is pressing below 37; 36 yes, 37 no', () {
      expect(pressingRings(_data(recovery: 10)),
          [HomeRingKind.recovery]);
      expect(pressingRings(_data(recovery: 36)),
          [HomeRingKind.recovery]);
      expect(pressingRings(_data(recovery: 37)), isEmpty);
    });

    test('WHY: sleep is pressing under 85% of need; 84% yes, 86% no', () {
      expect(pressingRings(_data(sleep: 403, need: 480)),
          [HomeRingKind.sleep]);
      expect(pressingRings(_data(sleep: 413, need: 480)), isEmpty);
    });

    test('WHY: strain is pressing only above the top of the target range', () {
      expect(pressingRings(_data(strain: 15, target: _target)),
          [HomeRingKind.strain]);
      expect(pressingRings(_data(strain: 11, target: _target)),
          isEmpty);
      // Low strain is not pressing, and with no target there is no range.
      expect(pressingRings(_data(strain: 0.0, target: _target)),
          isEmpty);
      expect(pressingRings(_data(strain: 20)), isEmpty);
    });

    test('WHY: severity decides the order, ties go recovery then sleep', () {
      expect(pressingRings(_rec2Sleep3),
          [HomeRingKind.sleep, HomeRingKind.recovery]);
      expect(pressingRings(_recAndSleep),
          [HomeRingKind.recovery, HomeRingKind.sleep]);
    });

    test('WHY: at most two; the least pressing is dropped', () {
      expect(pressingRings(_allThree),
          [HomeRingKind.recovery, HomeRingKind.sleep]);
    });

    test('WHY: an absent, provisional or in-progress value is never pressing',
        () {
      expect(pressingRings(_data(recovery: null, sleep: null)),
          isEmpty);
      expect(
          pressingRings(_data(recovery: 10, recoveryState: 'provisional')),
          isEmpty);
      expect(
          pressingRings(
              _data(recovery: null, recoveryState: 'night_in_progress')),
          isEmpty);
    });
  });

  // ── 1. the why panels ─────────────────────────────────────────────────────
  group('why panels', () {
    testWidgets('WHY: the loose "Why?" footer is gone, on any day',
        (t) async {
      await _rings(t, _data());
      expect(find.textContaining('Why?'), findsNothing);
      expect(find.byIcon(LucideIcons.info), findsNothing);
    });

    testWidgets('WHY: nothing pressing means no panel at all', (t) async {
      await _rings(t, _healthy);
      expect(_anyWhy, findsNothing);
    });

    testWidgets('WHY: one pressing ring gets exactly its own panel', (t) async {
      await _rings(t, _lowRecovery);
      expect(_anyWhy, findsOneWidget);
      expect(_why('recovery'), findsOneWidget);
      expect(find.text('Recovery is low'), findsOneWidget);
    });

    testWidgets('WHY: two pressing show recovery then sleep, capped at two',
        (t) async {
      await _rings(t, _allThree);
      expect(_whyOrder(t), ['recovery', 'sleep']);
      expect(_why('strain'), findsNothing);
      expect(find.text('Sleep is short of need'), findsOneWidget);
      // Derived from the data: 5h 50m asleep against an 8h 48m need.
      expect(find.text('5h 50m asleep, 2h 58m under your 8h 48m need.'),
          findsOneWidget);
    });

    testWidgets(
        'WHY: a night with no stored need is never measured against one',
        (t) async {
      // A past night the crossday pass never wrote a need for: the ring has
      // nothing to be short of, so it neither ranks nor claims a shortfall.
      await _rings(t, _data(recovery: 80, sleep: 300, need: null));
      expect(_why('sleep'), findsNothing);
      expect(find.textContaining('under your'), findsNothing);
    });

    testWidgets('WHY: the strain and its target range share one decimal '
        'separator (de)', (t) async {
      final c = LocaleController.seed('de')..useForPresentation();
      addTearDown(c.dispose);
      await _rings(
          t,
          _data(
              strain: 15.2,
              target: const {'value': 12, 'low': 10.5, 'high': 14.5}),
          locale: const Locale('de'));
      final body = _txt(t, _body('strain'));
      expect(body, contains('15,2'));
      expect(body, contains('10,5–14,5'));
    });

    testWidgets('WHY: panels order by how pressing, not by ring order',
        (t) async {
      await _rings(t, _rec2Sleep3);
      expect(_whyOrder(t), ['sleep', 'recovery']);
    });

    testWidgets('WHY: a pressing strain gets the strain panel', (t) async {
      await _rings(t, _data(strain: 15.2, target: _target));
      expect(_whyOrder(t), ['strain']);
      expect(find.text('Strain is above target'), findsOneWidget);
      expect(_txt(t, _body('strain')),
          'Strain 15.2, above today’s target of 8–12.');
    });

    testWidgets("WHY: the icon is the ring's own in a circle, never an (i)",
        (t) async {
      await _rings(t, _allThree);
      expect(_anyWhy, findsNWidgets(2));
      Finder iconIn(String k) => find.descendant(
          of: find.byKey(ValueKey('home-why-icon:$k')),
          matching: find.byType(Icon));
      expect(t.widget<Icon>(iconIn('recovery')).icon,
          LucideIcons.batteryCharging);
      expect(t.widget<Icon>(iconIn('sleep')).icon, LucideIcons.moon);
      final circle = t.widget<Container>(
          find.byKey(const ValueKey('home-why-icon:recovery')));
      expect((circle.decoration! as BoxDecoration).shape, BoxShape.circle);

      await _rings(t, _data(strain: 15, target: _target));
      expect(iconIn('strain'), findsOneWidget);
      expect(t.widget<Icon>(iconIn('strain')).icon, LucideIcons.zap);
    });

    testWidgets('WHY: a panel opens its own ring', (t) async {
      final opened = <HomeRingKind>[];
      await _rings(t, _recAndSleep, onOpen: opened.add);
      expect(_anyWhy, findsNWidgets(2));
      await t.tap(_why('sleep'));
      await t.tap(_why('recovery'));
      expect(opened, [HomeRingKind.sleep, HomeRingKind.recovery]);
    });

    testWidgets(
        'WHY (a11y): a panel is ONE tappable node that says its ring, title '
        'and reason, and is at least 48 dp tall', (t) async {
      final h = t.ensureSemantics();
      await _rings(t, _data(recovery: 10), onOpen: (_) {});
      expect(_why('recovery'), findsOneWidget);
      final node = t.getSemantics(_why('recovery'));
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.label, contains('Recovery is low'));
      expect(data.label, contains('Recovery 10 of 100'));
      // Context, not just the reason: which ring this is about.
      expect(data.label.toLowerCase(), contains('recovery'));
      expect(t.getSize(_why('recovery')).height, greaterThanOrEqualTo(48));
      // Title and body are not announced a second time by separate nodes.
      expect(find.bySemanticsLabel(RegExp('Recovery is low')), findsOneWidget);
      h.dispose();
    });
  });

  // ── 2. recovery copy: evidence of THIS ring, or the plain score ───────────
  group('recovery why copy', () {
    testWidgets('WHY: the plain score, with no driver claims', (t) async {
      await _rings(t, _data(recovery: 22));
      expect(_txt(t, _body('recovery')), 'Recovery 22 of 100');
      expect(find.textContaining('usual'), findsNothing);
    });

    testWidgets(
        'WHY: HomeData.load ignores readiness_glassbox, a different score from '
        'the composite ring, whatever its drivers or rollup age', (t) async {
      final withBox = await t.runAsync(() => HomeData.load(_Repo([
            _drv('hrv', -6.2, _drag),
            _drv('rhr', 3.1, _lift),
          ], score: 80.0, rollupDay: '2026-09-29')));
      final without = await t.runAsync(() => HomeData.load(_Repo(const [])));
      expect(withBox!.readiness.value, 22);
      expect(withBox.readiness.value, without!.readiness.value);
      expect(withBox.strain.value, without.strain.value);
      expect(withBox.sleepMin.value, without.sleepMin.value);
      await _rings(t, withBox);
      expect(_txt(t, _body('recovery')), 'Recovery 22 of 100');
    });
  });

  // ── 3. the bottom slot: update note, gap reasons, two rows at most ────────
  group('bottom slot', () {
    testWidgets('WHY: the recovery update is a tappable row, said once',
        (t) async {
      final opened = <HomeRingKind>[];
      await _rings(t, _data(update: _update), onOpen: opened.add);
      expect(_note, findsOneWidget);
      expect(find.text(_updateLine), findsOneWidget);
      await t.tap(_note);
      expect(opened, [HomeRingKind.recovery]);
    });

    testWidgets('WHY: no update, no row', (t) async {
      await _rings(t, _data());
      expect(_note, findsNothing);
      expect(find.textContaining('Updated'), findsNothing);
    });

    testWidgets(
        'WHY: the note is a neutral inset row (refresh icon, chevron, '
        'centred), not a ring-coloured panel', (t) async {
      await _rings(t, _data(update: _update));
      expect(_note, findsOneWidget);
      final p = P.of(t.element(_note));
      expect(
          find.descendant(
              of: _note, matching: find.byIcon(LucideIcons.refreshCw)),
          findsOneWidget);
      expect(
          find.descendant(
              of: _note, matching: find.byIcon(LucideIcons.chevronRight)),
          findsOneWidget);
      final circle = t.widget<Container>(
          find.byKey(const ValueKey('home-update-note-icon')));
      expect((circle.decoration! as BoxDecoration).color,
          p.ink3.withValues(alpha: .16));
      final insets = t
          .widgetList<Container>(
              find.descendant(of: _note, matching: find.byType(Container)))
          .where((c) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.color == p.card2 &&
            d.borderRadius == R.rMd;
      });
      expect(insets, isNotEmpty);
    });

    testWidgets('WHY: an absent ring gets a row: its name over its reason',
        (t) async {
      await _rings(t, _data(strain: null));
      expect(_gap('strain'), findsOneWidget);
      expect(find.descendant(of: _gap('strain'), matching: find.text('Strain')),
          findsOneWidget);
    });

    testWidgets('WHY: order is why, then the update note, then a gap reason',
        (t) async {
      // One pressing ring (recovery 10), an update, and an absent strain: room
      // for two, so the note follows the why and the gap reason has no slot.
      await _rings(t, _data(recovery: 10, strain: null, update: _update));
      expect(_why('recovery'), findsOneWidget);
      expect(_note, findsOneWidget);
      expect(_gap('strain'), findsNothing);
      expect(t.getTopLeft(_why('recovery')).dy,
          lessThan(t.getTopLeft(_note).dy));
    });

    testWidgets(
        'WHY: the update note does not hide an absent ring\'s reason when '
        'there is room', (t) async {
      await _rings(t, _data(strain: null, update: _update));
      expect(_note, findsOneWidget);
      expect(_gap('strain'), findsOneWidget);
      expect(t.getTopLeft(_note).dy, lessThan(t.getTopLeft(_gap('strain')).dy));
    });

    testWidgets('WHY: the slot holds two rows at most; two whys leave no note',
        (t) async {
      await _rings(t, _data(recovery: 10, sleep: 350, need: 528, update: _update));
      expect(_whyOrder(t), ['recovery', 'sleep']);
      expect(_note, findsNothing);
    });

    testWidgets('WHY: a healthy card with an absent ring and an update shows '
        'both, never a third', (t) async {
      await _rings(t, _data(strain: null, sleep: null, update: _update));
      final rows = [
        _note,
        _gap('strain'),
        _gap('sleep'),
      ].where((f) => f.evaluate().isNotEmpty).length;
      expect(rows, 2);
    });
  });

  // ── 4. layout: nothing above the slot ever moves ──────────────────────────
  group('layout', () {
    for (final w in [320.0, 390.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets(
            'WHY: the rings sit at the same place with 0, 1 or 2 rows '
            '@${w.toInt()} pt x$scale, and no row overflows', (t) async {
          await _rings(t, _healthy, w: w, scale: scale);
          final rest = _ringPos(t);
          final restHeight = t.getSize(find.byType(RingTrio)).height;
          await _rings(t, _lowRecovery, w: w, scale: scale);
          expect(_ringPos(t), rest, reason: 'one row');
          final one = t.getSize(find.byType(RingTrio)).height;
          await _rings(t, _recAndSleep, w: w, scale: scale);
          expect(_ringPos(t), rest, reason: 'two rows');
          final two = t.getSize(find.byType(RingTrio)).height;
          expect(t.takeException(), isNull);
          // Each row costs its own height; zero rows reserve nothing.
          expect(one, greaterThan(restHeight));
          expect(two, greaterThan(one));
          for (final k in ['recovery', 'sleep']) {
            final body = t.renderObject(_body(k)) as RenderParagraph;
            final fs = body.text.style?.fontSize ?? 12;
            expect((body.size.height / (fs * scale * 1.6)).round(),
                lessThanOrEqualTo(2),
                reason: '$k body stays within two lines');
          }
        });
      }
    }
  });

  // ── 5. the sleep caption in every language ────────────────────────────────
  group('sleep caption', () {
    // The default test font is a block face one em wide per glyph, which no
    // wording could fit into three lines of a 100 pt column. Measure with the
    // fonts the app ships.
    setUpAll(() async {
      final fonts = Directory('assets/fonts/Manrope')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.ttf'));
      for (final family in ['Manrope', '.SF Pro Text']) {
        final loader = FontLoader(family);
        for (final file in fonts) {
          loader.addFont(file.readAsBytes().then(
              (bytes) => ByteData.sublistView(Uint8List.fromList(bytes))));
        }
        await loader.load();
      }
      // Manrope has no Thai glyphs. Without a Thai face every Thai word is an
      // unbreakable one-em block and the line bound below means nothing.
      final thai = _thaiFontFile();
      if (thai != null) {
        final loader = FontLoader('ThaiTestFace')
          ..addFont(thai.readAsBytes().then(
              (bytes) => ByteData.sublistView(Uint8List.fromList(bytes))));
        await loader.load();
        _thaiFamily = 'ThaiTestFace';
      }
    });
    tearDownAll(() => _thaiFamily = null);

    // A scored night against the 8 h default: 442 of 480 min is 92%.
    HomeData slept() => HomeData(
          dayId: '2026-10-04',
          readiness: _m(80),
          strain: _m(5),
          sleepMin: _m(442),
          sleepStages: const SleepStageMin(deep: 70, rem: 95, light: 277, awake: 30),
        );

    for (final lang in ['de', 'en', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
      testWidgets(
          'WHY: $lang at 320 pt x1.3 prints the 92% caption whole, within '
          'the three reserved lines', (t) async {
        await _rings(t, slept(), w: 320, scale: 1.3, locale: Locale(lang));
        expect(t.takeException(), isNull);
        final caption = find.byWidgetPredicate((w) =>
            w is Text && (w.data ?? '').contains('92') && !(w.data ?? '').contains(':'));
        expect(caption, findsOneWidget, reason: 'one caption carrying the 92%');
        final para = t.renderObject<RenderParagraph>(caption);
        expect(para.didExceedMaxLines, isFalse,
            reason: '$lang caption is cut by its line limit');
        // Three lines is the reserved caption height; more would shift the card.
        if (lang == 'th' && _thaiFontFile() == null) {
          markTestSkipped('no Thai-capable font found (set $_thaiFontEnv, or '
              'install FreeFont/Noto Sans Thai): the Thai three-line bound is '
              'NOT measured on this machine');
          return;
        }
        final fs = para.text.style?.fontSize ?? 12;
        if (lang == 'th') {
          // Proof the Thai face is in use: a real face gives the combining
          // marks no advance, so the run is narrower than one em per code
          // unit (the block face's width).
          final text = para.text.toPlainText();
          final tp = TextPainter(
              text: TextSpan(text: text, style: para.text.style),
              textDirection: TextDirection.ltr)
            ..layout();
          expect(tp.width, lessThan(text.length * fs * 0.9),
              reason: 'Thai measured with a face that has no Thai glyphs');
        }
        expect(para.size.height / (fs * 1.3 * 1.5), lessThanOrEqualTo(3.01));
      });
    }
  });
}
