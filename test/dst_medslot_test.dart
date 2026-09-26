import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';

void main() {
  test('medSlotInstant resolves correct wall-clock time across spring-forward DST', () {
    // 2026-03-08 is the real US spring-forward date (2am -> 3am).
    const def = MedDef(key: 'x', label: 'x');
    final s = MedSlot(
      def: def,
      date: '2026-03-08',
      slotMin: 14 * 60,
      state: DoseState.upcoming,
    );
    final at = NotificationCenter.medSlotInstant(s);
    expect(at, isNotNull);
    expect(at!.hour, 14);
    expect(at.minute, 0);
  });
}
