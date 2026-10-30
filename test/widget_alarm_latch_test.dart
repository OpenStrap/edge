// A Siri "enable tomorrow's alarm" request is latched by the widget process
// and consumed on resume. A clear that fails part-way must not erase the
// request it was about to return.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/widget/widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const home = MethodChannel('home_widget');
  final data = <String, Object?>{};
  var failLegacyClear = true;

  setUp(() {
    failLegacyClear = true;
    data
      ..clear()
      ..['enable_tomorrow_alarm_requested_at'] = 1792218600
      ..['enable_tomorrow_alarm_weekday'] = 3;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(home, (c) async {
      final a = c.arguments is Map ? (c.arguments as Map) : const {};
      if (c.method == 'getWidgetData') return data[a['id']] ?? a['defaultValue'];
      if (c.method == 'saveWidgetData') {
        if (failLegacyClear && a['id'] == 'enable_tomorrow_alarm_weekday') {
          throw PlatformException(code: 'io');
        }
        data[a['id'] as String] = a['data'];
        return true;
      }
      return null;
    });
  });

  test('a failed clear leaves the timestamped request on disk', () async {
    expect(await WidgetService.consumeEnableTomorrowAlarmRequest(), isNull);
    expect(data['enable_tomorrow_alarm_requested_at'], 1792218600);
  });

  test('a timestamped request is returned once and both latches cleared',
      () async {
    failLegacyClear = false;
    final r = await WidgetService.consumeEnableTomorrowAlarmRequest();
    expect(r?.requestedAt, 1792218600);
    expect(r?.weekday, isNull);
    expect(data['enable_tomorrow_alarm_requested_at'], -1);
    expect(data['enable_tomorrow_alarm_weekday'], -1);
    expect(await WidgetService.consumeEnableTomorrowAlarmRequest(), isNull);
  });

  test('a weekday latched by an older build still comes through', () async {
    failLegacyClear = false;
    data['enable_tomorrow_alarm_requested_at'] = -1;
    final r = await WidgetService.consumeEnableTomorrowAlarmRequest();
    expect(r?.requestedAt, isNull);
    expect(r?.weekday, 3);
    expect(data['enable_tomorrow_alarm_weekday'], -1);
  });
}
