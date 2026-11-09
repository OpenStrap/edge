// RED-PHASE STUB (phase 0, Home + labels). Shapes only, no behaviour. The
// green phase ports fork origin/integrate/next:lib/ui2/spiral_ring.dart.
import 'package:flutter/widgets.dart';

const double kSpiralSeparator = 0;

double spiralSeparatorWidth(double stroke) => 0;

class SpiralPiece {
  final int seg, lap;
  final double from, to;
  final bool capEnd, capStart;
  const SpiralPiece(this.seg, this.lap, this.from, this.to,
      {this.capEnd = false, this.capStart = false});
}

class SpiralGeometry {
  final double stroke, ramp, insetPerStroke;
  const SpiralGeometry(this.stroke, {this.ramp = 0, this.insetPerStroke = 0});

  double inset(double s) => 0;
  double radiusAt(double s, double r0) => r0;
  int saturationLaps(double r0) => 0;
  static int lapsFor(double fraction) => 0;
  List<SpiralPiece> pieces(List<double> fractions) => const [];
  double? separatorFrom(int lap) => null;
  static double gradientAt(double s, double total) => 0;
}

void paintSpiral(Canvas canvas, Size size,
    {required double stroke,
    required Color track,
    required List<Color> colors,
    required List<double> fractions,
    required double t,
    bool solid = true,
    Color? background}) {}

double gradientAt(double s, double total) => 0;
