import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/widget/widget_service.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 28, 12);

  test('never pushed + connected is due', () {
    expect(WidgetService.batteryHeartbeatDue(null, t0, connected: true), isTrue);
  });

  test('unchanged reading refreshes after the heartbeat while connected', () {
    final hb = WidgetService.batteryHeartbeat;
    expect(
      WidgetService.batteryHeartbeatDue(
          t0, t0.add(hb - const Duration(seconds: 1)),
          connected: true),
      isFalse,
    );
    expect(
      WidgetService.batteryHeartbeatDue(t0, t0.add(hb), connected: true),
      isTrue,
    );
  });

  test('never refreshes the stamp while disconnected', () {
    expect(
      WidgetService.batteryHeartbeatDue(
          t0, t0.add(const Duration(hours: 20)),
          connected: false),
      isFalse,
    );
    expect(WidgetService.batteryHeartbeatDue(null, t0, connected: false),
        isFalse);
  });

  test('heartbeat stays well inside the 18 h mute window', () {
    expect(WidgetService.batteryHeartbeat < const Duration(hours: 18), isTrue);
  });
}
