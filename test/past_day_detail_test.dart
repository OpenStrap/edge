// Home's day switcher can step back to a past day, and the rings it draws are
// that day's. Tapping one has to open that day too: the recovery and strain
// detail screens used to read today unconditionally, so a past day's 41
// opened a screen saying 78.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';

class _Repo extends LocalRepository {
  final asked = <String>[];

  @override
  Future<Map<String, dynamic>> getToday() async =>
      throw StateError('a past day must not read today');

  @override
  Future<Map<String, dynamic>> getInsights() async =>
      throw StateError('a past day must not read today\'s insights');

  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async {
    asked.add('overview:$date');
    return {
      'readiness': {'value': date == '2026-05-19' ? 41 : 78, 'confidence': 0.8},
    };
  }

  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    asked.add('strain:$date');
    return {'curve': const [], 'strain': date == '2026-05-19' ? 15.2 : 3.0};
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};
}

void main() {
  test('recovery for a past day is that day\'s stored score', () async {
    final r = _Repo();
    final d = await ReadinessData.loadForDay(r, '2026-05-19');
    expect(d.readiness.value, 41);
    expect(d.day, '2026-05-19');
    expect(d.breakdown, isEmpty,
        reason: 'today\'s percentile ranking is not this day\'s');
    expect(r.asked, ['overview:2026-05-19']);
  });

  test('strain for a past day asks for that day', () async {
    final r = _Repo();
    final d = await DayStrainData.load(r, forDay: '2026-05-19');
    expect(d.strain, 15.2);
    expect(r.asked, contains('strain:2026-05-19'));
  });
}
