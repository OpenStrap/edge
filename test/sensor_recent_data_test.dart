import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart'
    show sensorRowHasRecentData;

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000);
  const t = 1000000000;
  test('never synced, stale and fresh rows', () {
    expect(sensorRowHasRecentData({'first_seen': t - 100, 'last_seen': t - 100}, now: now), isFalse);
    expect(sensorRowHasRecentData({'first_seen': 1, 'last_seen': t - 90 * 86400}, now: now), isFalse);
    expect(sensorRowHasRecentData({'first_seen': 1, 'last_seen': t - 3600}, now: now), isTrue);
  });
}
