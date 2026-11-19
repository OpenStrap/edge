// The layout shift scorer. See docs/LAYOUT_SHIFT.md "Scoring".

import 'shift_model.dart';
import 'shift_policy.dart';

enum ShiftSeverity { none, warning, error }

class ShiftFinding {
  final String rule;
  final String elementId;
  final int atMs;
  final double score;
  final ShiftSeverity severity;
  const ShiftFinding({
    required this.rule,
    required this.elementId,
    required this.atMs,
    required this.score,
    required this.severity,
  });
}

class ShiftReport {
  final List<ShiftFinding> findings;
  const ShiftReport(this.findings);

  double get total => throw UnimplementedError();
  List<ShiftFinding> get errors => throw UnimplementedError();
  List<ShiftFinding> get warnings => throw UnimplementedError();
}

/// Scores every consecutive frame pair of [s] under [p]. Pure and
/// deterministic: same input, same report.
ShiftReport score(Scenario s, ShiftPolicy p) => throw UnimplementedError();
