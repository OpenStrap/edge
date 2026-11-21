// record() before load() must not overwrite last session's persisted outbox.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/telemetry/telemetry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('early record keeps the previous crash, older first', () async {
    SharedPreferences.setMockInitialValues({
      'telemetry_outbox': jsonEncode([
        {'kind': 'crash', 'message': 'last session', 'ts': 1},
      ]),
    });
    final t = TelemetryService.instance..debugResetOutbox();

    t.record(kind: 'error', message: 'early');
    await Future<void>.delayed(Duration.zero);
    await t.load();

    expect(t.outboxSnapshot.map((e) => e['message']), ['last session', 'early']);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('telemetry_outbox')!) as List;
    expect(saved.map((e) => e['message']), ['last session', 'early']);
  });
}
