import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';

void main() {
  Map<String, dynamic> rowForWake(DateTime wake) => {
    'window_json': '{"value":{"offset_ms":${wake.millisecondsSinceEpoch}}}',
  };

  test('enables inside the 90 minute wake window from habitual wake', () {
    final rows = [
      rowForWake(DateTime(2026, 6, 28, 7, 30)),
      rowForWake(DateTime(2026, 6, 27, 7, 28)),
      rowForWake(DateTime(2026, 6, 26, 7, 31)),
    ];
    final now = DateTime(2026, 6, 29, 6, 45);
    final plan = HighFreqWakeWindow.planFromRows(rows, now);
    expect(plan.shouldEnable, isTrue);
    expect(plan.source, 'habitual_wake');
    expect(plan.targetWake, DateTime(2026, 6, 29, 7, 30));
  });

  test('disables outside the wake window', () {
    final rows = [
      rowForWake(DateTime(2026, 6, 28, 7, 30)),
      rowForWake(DateTime(2026, 6, 27, 7, 29)),
      rowForWake(DateTime(2026, 6, 26, 7, 31)),
    ];
    final now = DateTime(2026, 6, 29, 4, 0);
    final plan = HighFreqWakeWindow.planFromRows(rows, now);
    expect(plan.shouldEnable, isFalse);
    expect(plan.targetWake, DateTime(2026, 6, 29, 7, 30));
  });

  test('requires enough sleep history', () {
    final rows = [
      rowForWake(DateTime(2026, 6, 28, 7, 30)),
      rowForWake(DateTime(2026, 6, 27, 7, 29)),
    ];
    final plan = HighFreqWakeWindow.planFromRows(
      rows,
      DateTime(2026, 6, 29, 6, 45),
    );
    expect(plan.shouldEnable, isFalse);
    expect(plan.targetWake, isNull);
    expect(plan.source, 'insufficient_sleep_history');
  });
}
