// Workouts header actions — the ⊕ Add / ▶ Start pair, and the layout budget
// they have to live inside.
//
// WHY THIS FILE EXISTS. "Log a past workout" first shipped as a fourth child
// of the start bottom sheet, where it was invisible and untappable: the sheet
// defaults to `isScrollControlled: false`, capping it at 9/16 of the screen
// (~475 pt at 390x844), and nine type tiles already wrapped to three rows.
// The row fell off the bottom edge. In release there are no overflow stripes,
// so nothing announced it — it just silently did not work.
//
// The type vocabulary has since outgrown that cap outright, so the sheet is
// scroll-controlled and the grid scrolls inside it. That changes what has to
// be guarded, not why: the failure mode is still "content past the edge is
// silently unhittable", and the defence is now that the grid is genuinely
// inside a Scrollable and every tile can be reached.
//
// Three lessons, all pinned here:
//   1. Two pills plus the title must fit the header row at real phone widths.
//   2. A layout overflow must FAIL a test rather than ship as dead pixels.
//   3. Every workout type must be reachable, however long the list grows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui/design/design.dart';
import 'package:openstrap_edge/ui/workouts/workout_types.dart';

/// The narrowest phone we target, and the one the header budget is tightest on.
const Size _iphoneSe = Size(375, 667);
const Size _iphone14 = Size(390, 844);

Widget _harness(Widget child, ThemeData theme) =>
    MaterialApp(theme: theme, home: child);

void main() {
  for (final palette in [kLightPalette, kDarkPalette]) {
    final mode = palette == kLightPalette ? 'light' : 'dark';

    testWidgets('header fits title + Add + Start without overflow ($mode)',
        (t) async {
      for (final size in [_iphoneSe, _iphone14]) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        AppColors.active = palette;

        await t.pumpWidget(_harness(
          AppScaffold(
            title: 'Workouts',
            actions: [
              // Stand-ins with the exact geometry of the real pills — the
              // private widgets can't be imported, and what is under test is
              // the header's width budget, not their internals.
              _pill(Icons.add_rounded, 'Add'),
              _pill(Icons.play_arrow_rounded, 'Start'),
            ],
            children: const [SizedBox(height: 200)],
          ),
          buildOpenStrapTheme(palette),
        ));
        await t.pump();

        expect(t.takeException(), isNull,
            reason: 'header overflowed at ${size.width}x${size.height}');
        expect(find.text('Add'), findsOneWidget);
        expect(find.text('Start'), findsOneWidget);
        // The title must survive intact — if the actions eat the row, the
        // Expanded title ellipsizes to "Workout…" instead of failing loudly.
        final title = t.widget<Text>(find.text('Workouts'));
        expect(title.overflow, TextOverflow.ellipsis);
        final titleBox = t.getSize(find.text('Workouts'));
        expect(titleBox.width, greaterThan(0));
      }
    });
  }

  testWidgets(
    'every workout type in the start sheet is reachable — the regression '
    'that made "Log a past workout" untappable',
    (t) async {
      t.view.physicalSize = _iphone14;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      AppColors.active = kLightPalette;

      // The sheet body exactly as startWorkoutFlow builds it, under the same
      // ceiling showModalBottomSheet imposes with isScrollControlled: true.
      await t.pumpWidget(_harness(
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: KeyedSubtree(
              key: const Key('sheet-body'),
              child: Builder(
                builder: (ctx) => workoutTypeSheet(ctx, 'Start a workout'),
              ),
            ),
          ),
        ),
        buildOpenStrapTheme(kLightPalette),
      ));
      await t.pump();

      expect(t.takeException(), isNull,
          reason: 'the start sheet must not overflow — anything past the edge '
              'is silently unhittable in release');

      // The sheet stays inside its own ceiling rather than growing to fit.
      final used = t.getSize(find.byKey(const Key('sheet-body'))).height;
      expect(used, lessThanOrEqualTo(_iphone14.height * 0.75 + 0.5),
          reason: 'sheet grew past the height it constrains itself to');

      // THE load-bearing assertion: the grid is inside a Scrollable. Without
      // it the overflowing tiles are drawn nowhere and cannot be tapped, which
      // is the original bug with more tiles.
      expect(
        find.ancestor(
          of: find.text(kWorkoutTypes.first.$2),
          matching: find.byType(Scrollable),
        ),
        findsWidgets,
        reason: 'the type grid must scroll — the list is taller than the sheet',
      );

      // Every tile exists, has real size, and can be brought fully on screen.
      final scrollable = find
          .descendant(
            of: find.byKey(const Key('sheet-body')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final e in kWorkoutTypes) {
        final tile = find.text(e.$2);
        expect(tile, findsOneWidget, reason: '${e.$2} tile missing');
        await t.scrollUntilVisible(tile, 120, scrollable: scrollable);
        final r = t.getRect(tile);
        expect(r.height, greaterThan(0), reason: '${e.$2} collapsed to zero');
        expect(r.bottom, lessThanOrEqualTo(_iphone14.height),
            reason: '${e.$2} could not be scrolled onto the screen');
      }
    },
  );
}

/// A pill with the same padding/icon/label geometry as _AddButton/_StartButton.
Widget _pill(IconData icon, String label) => Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: Sp.x1),
          Text(label, style: AppText.label.copyWith(color: Colors.white)),
        ],
      ),
    );
