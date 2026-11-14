import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/skeleton/guide_plot.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart';

void main() {
  // WHY: a correct rectangle plan is insufficient if the original chart still
  // paints beneath it. The guide replaces the plot's source paint, and retains
  // the independent background paint. No raster/frame harness is involved.
  // # catches: surface erasure after normal child paint, and plan-only sines.
  testWidgets('C: replace chart source paint and preserve its own background', (
    t,
  ) async {
    final controller = GuideDimController();
    addTearDown(controller.dispose);
    final plot = _Plot();
    final background = _Background();
    const root = ValueKey('root'), target = ValueKey('target');
    await t.pumpWidget(
      GuideDimScope(
        controller: controller,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: Column(
              key: root,
              children: [
                const Surface(child: Text('Target', key: target)),
                const Surface(child: Text('Neighbour')),
                Surface(
                  child: CustomPaint(
                    painter: background,
                    child: Column(
                      children: [
                        const Text('Chart title'),
                        SizedBox(
                          width: 280,
                          height: 60,
                          child: CustomPaint(painter: plot),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(
      plot.paints,
      greaterThan(0),
      reason: 'positive control: original plot paints with no guide',
    );
    final page = t.element(find.byKey(root));
    final found =
        GuideTarget.key(
              target,
            ).resolve(page, lookupAppLocalizations(const Locale('en')))
            as TargetFound;
    plot.paints = background.paints = 0;
    controller.setLooks(
      GuidePlan.from(
        page,
        planSkeleton(page, keep: [found.rect], dim: DimPolicy.of(page, found)),
      ),
    );
    await t.pump();
    expect(
      plot.paints,
      0,
      reason: 'no original chart, axes or labels paint under the sine',
    );
    expect(
      background.paints,
      greaterThan(0),
      reason: 'the existing decoration still supplies its background',
    );
    controller.clear();
    await t.pump();
    expect(
      plot.paints,
      greaterThan(0),
      reason: 'ending the guide restores original chart painting',
    );
  });
}

class _Plot extends CustomPainter implements GuidePlot {
  int paints = 0;
  @override
  Color get guideLineColor => C.blue;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawLine(
      Offset.zero,
      size.bottomRight(Offset.zero),
      Paint()..color = C.blue,
    );
  }

  @override
  bool shouldRepaint(_Plot oldDelegate) => true;
}

class _Background extends CustomPainter implements GuideDecoration {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = C.purple);
  }

  @override
  bool shouldRepaint(_Background oldDelegate) => true;
}
