// BP research window summary: pending never reads as "no band data".
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/bp_research.dart';

void main() {
  group('BpResearchScreen.windowSummary', () {
    test('pending with no rows shows the sync hint, not "No band data"', () {
      final s = BpResearchScreen.windowSummary(const {
        'quality_status': 'pending',
        'onehz_rows': null,
        'rr_beats': null,
        'hr_mean': null,
        'rmssd_ms': null,
      });
      expect(s, contains('Band data is still syncing'));
      expect(s, isNot(contains('No band data')));
    });

    test('pending with partial data shows the hint plus available metrics', () {
      final s = BpResearchScreen.windowSummary(const {
        'quality_status': 'pending',
        'onehz_rows': 120,
        'rr_beats': 80,
        'hr_mean': 62.0,
        'rmssd_ms': 41.0,
      });
      expect(s, contains('Band data is still syncing'));
      expect(s, contains('HR 62 bpm'));
      expect(s, contains('RMSSD 41 ms'));
      expect(s, contains('120 1 Hz rows, 80 beats so far'));
      expect(s, isNot(contains('No band data')));
    });

    test('final empty window keeps the honest no-data text', () {
      final s = BpResearchScreen.windowSummary(const {
        'quality_status': 'no_data',
        'onehz_rows': null,
        'rr_beats': null,
        'hr_mean': null,
        'rmssd_ms': null,
      });
      expect(s, 'No band data in the window — stored as-is.');
    });

    test('final empty window without status keeps the no-data text', () {
      final s = BpResearchScreen.windowSummary(const {
        'quality_status': null,
        'onehz_rows': null,
        'rr_beats': null,
        'hr_mean': null,
        'rmssd_ms': null,
      });
      expect(s, 'No band data in the window — stored as-is.');
    });

    test('ok window shows the existing summary without a status suffix', () {
      final s = BpResearchScreen.windowSummary(const {
        'quality_status': 'ok',
        'onehz_rows': 300,
        'rr_beats': 295,
        'hr_mean': 58.4,
        'rmssd_ms': 47.2,
      });
      expect(s, isNot(contains('syncing')));
      expect(s, contains('HR 58 bpm'));
      expect(s, contains('RMSSD 47 ms'));
      expect(s, contains('300 1 Hz rows, 295 beats'));
      expect(s, isNot(contains(' ok')));
    });

    test('gappy window appends its status to the existing summary', () {
      final s = BpResearchScreen.windowSummary(const {
        'quality_status': 'gappy',
        'onehz_rows': 210,
        'rr_beats': 180,
        'hr_mean': 61.0,
        'rmssd_ms': 38.0,
      });
      expect(s, contains('210 1 Hz rows, 180 beats'));
      expect(s.endsWith('gappy'), isTrue);
    });
  });
}
