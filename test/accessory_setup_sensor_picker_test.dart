// The Dart half of the sensor picker (#371/#372): what goes over the
// `openstrap/accessory_setup` channel for a `kAskPickerSensors` entry.
//
// The native side tells a SENSOR picker from the band picker by the argument's
// shape alone — a `{"services": [...]}` map versus a Bool / null — and matches
// the services against Info.plist's uppercased `OSAskSensorServices`. So both
// the shape and the case are the contract, and the band call must keep
// sending exactly what it sent before.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/accessory_setup.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('openstrap/accessory_setup');
  final calls = <MethodCall>[];
  Object? reply = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';

  setUp(() {
    calls.clear();
    reply = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the ring asks for a picker filtered to its own uppercased service',
      () async {
    final id = await AccessorySetup.showSensorPicker([kOura.service]);
    expect(id, 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE');
    expect(calls.single.method, 'showPicker');
    expect(calls.single.arguments, {
      'services': [kOura.service.toUpperCase()],
    });
  });

  test('the band picker still sends no argument', () async {
    await AccessorySetup.showPicker();
    expect(calls.single.arguments, isNull);
  });

  test('an empty reply is a cancellation, not an id', () async {
    reply = null;
    await expectLater(
      AccessorySetup.showSensorPicker([kOura.service]),
      throwsA(isA<Exception>()),
    );
  });
}
