// The health-exception push, decided without the database.
//
// The overnight detectors (illness CUSUM, multivariate anomaly, skin
// temperature) publish the newest SETTLED night's entry, dated with that
// night. A finding is dated by its own entry — never by the newest row of the
// rollup — and may only buzz about today or yesterday, judged by CALENDAR
// label so a DST transition cannot gate out a current night.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';

void main() {
  Map<String, dynamic> cdWith({
    String illnessDate = '2024-01-29',
    String recentLast = '2024-01-30',
  }) =>
      {
        'illness': {'date': illnessDate, 'state': 'red'},
        'anomaly': {'date': illnessDate, 'flagged': false},
        'temp_illness': {'date': illnessDate, 'flag': 'normal'},
        'recent': [
          {'date': recentLast, 'unsettled': true},
        ],
      };

  test('a red night yesterday fires while today is still settling', () {
    final notices = dueExceptionNotices(crossDayAlertFindings(cdWith()),
        today: '2024-01-30');
    expect(notices, hasLength(1));
    final n = notices.single;
    expect(n.date, '2024-01-29');
    expect(n.dedupeKey, '2024-01-29:exception:medical');
    expect(n.findings, [const Finding(FindingKind.illness, '2024-01-29')]);
  });

  // Each detector family is read and dated on its OWN entry. The three dates
  // here differ on purpose: a branch dropped, or dated with another family's
  // entry, lands on the wrong day and fails.
  test('anomaly and temperature are read and dated on their own entries', () {
    final cd = {
      'illness': {'date': '2024-01-29', 'state': 'red'},
      'anomaly': {'date': '2024-01-30', 'flagged': true},
      'temp_illness': {'date': '2024-01-28', 'flag': 'elevated'},
    };
    expect(crossDayAlertFindings(cd), const [
      Finding(FindingKind.illness, '2024-01-29'),
      Finding(FindingKind.anomaly, '2024-01-30'),
      Finding(FindingKind.tempElevated, '2024-01-28'),
    ]);
    // Two days back is history: the temperature finding is dropped.
    final notices =
        dueExceptionNotices(crossDayAlertFindings(cd), today: '2024-01-30');
    expect([for (final n in notices) n.dedupeKey],
        ['2024-01-30:exception:medical', '2024-01-29:exception:medical']);
    expect(notices.first.findings,
        const [Finding(FindingKind.anomaly, '2024-01-30')]);
    expect(notices.last.findings,
        const [Finding(FindingKind.illness, '2024-01-29')]);
  });

  test('an elevated temperature fires on its own date', () {
    final cd = {
      'illness': {'date': '2024-01-30', 'state': 'green'},
      'anomaly': {'date': '2024-01-30', 'flagged': false},
      'temp_illness': {'date': '2024-01-29', 'flag': 'elevated'},
    };
    final n = dueExceptionNotices(crossDayAlertFindings(cd),
            today: '2024-01-30')
        .single;
    expect(n.date, '2024-01-29');
    expect(n.dedupeKey, '2024-01-29:exception:medical');
    expect(n.findings, const [Finding(FindingKind.tempElevated, '2024-01-29')]);
  });

  test('a red night two days back is history', () {
    expect(
        dueExceptionNotices(crossDayAlertFindings(cdWith()),
            today: '2024-01-31'),
        isEmpty);
  });

  test('the gate is calendar, not 24 h', () {
    // 2026-03-08 is the US spring-forward day; 2026-11-01 is fall-back.
    expect(isRecentFindingDate('2026-03-08', today: '2026-03-09'), isTrue);
    expect(isRecentFindingDate('2026-03-07', today: '2026-03-09'), isFalse);
    expect(isRecentFindingDate('2026-11-01', today: '2026-11-02'), isTrue);
  });

  test('the finding is dated by its entry, not by recent.last', () {
    final cd = cdWith(illnessDate: '2024-01-28', recentLast: '2024-01-30');
    expect(dueExceptionNotices(crossDayAlertFindings(cd), today: '2024-01-30'),
        isEmpty);
  });

  test('one notice per day, newest first', () {
    final notices = dueExceptionNotices(const [
      Finding(FindingKind.illness, '2024-01-29'),
      Finding(FindingKind.lowReadiness, '2024-01-30'),
    ], today: '2024-01-30');
    expect([for (final n in notices) n.date], ['2024-01-30', '2024-01-29']);
    expect([for (final n in notices) n.dedupeKey],
        ['2024-01-30:exception', '2024-01-29:exception:medical']);
  });

  test('title and body aggregate exactly as before', () {
    final n = ExceptionNotice('2024-01-30', const [
      Finding(FindingKind.illness, '2024-01-30'),
      Finding(FindingKind.anomaly, '2024-01-30'),
    ]);
    expect(n.title, '2 things to look at');
    expect('• '.allMatches(n.body), hasLength(2));
    expect(n.body.split('\n'), hasLength(2));

    const one = Finding(FindingKind.anomaly, '2024-01-30');
    final single = ExceptionNotice('2024-01-30', const [one]);
    expect(single.title, one.title);
    expect(single.body, one.detail);
  });

  test('exceptionAnchor needs a dated newest row', () {
    expect(exceptionAnchor({}), isNull);
    expect(exceptionAnchor({'recent': []}), isNull);
    expect(exceptionAnchor({'recent': ['x']}), isNull);
    final a = exceptionAnchor({
      'recent': [
        {'date': '2024-01-30', 'unsettled': true},
      ],
    });
    expect(a?.date, '2024-01-30');
    expect(a?.unsettled, isTrue);
  });

  test('a low-readiness notice carries the score in its body', () {
    final n = ExceptionNotice(
        '2026-10-02', [lowReadinessFinding('2026-10-02', 22)!]);
    expect(n.body, contains('22'));
    expect(n.dedupeKey, '2026-10-02:exception');
  });
}
