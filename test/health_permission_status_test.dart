import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import 'package:openstrap_edge/health/health_permission_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('healthWriteAuthFromNative', () {
    test('maps the HealthKit status names', () {
      expect(healthWriteAuthFromNative('authorized'), HealthWriteAuth.authorized);
      expect(healthWriteAuthFromNative('sharingAuthorized'),
          HealthWriteAuth.authorized);
      expect(healthWriteAuthFromNative('denied'), HealthWriteAuth.denied);
      expect(healthWriteAuthFromNative('sharingDenied'), HealthWriteAuth.denied);
      expect(healthWriteAuthFromNative('notDetermined'),
          HealthWriteAuth.notDetermined);
    });

    test('never fabricates: missing or unknown input stays unknown', () {
      expect(healthWriteAuthFromNative(null), HealthWriteAuth.unknown);
      expect(healthWriteAuthFromNative(''), HealthWriteAuth.unknown);
      expect(healthWriteAuthFromNative('granted'), HealthWriteAuth.unknown);
      expect(healthWriteAuthFromNative('error'), HealthWriteAuth.unknown);
    });
  });

  group('healthPermTypeOf', () {
    test('collapses every sleep type into one row', () {
      for (final t in [
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.SLEEP_SESSION,
        HealthDataType.SLEEP_IN_BED,
      ]) {
        expect(healthPermTypeOf(t), HealthPermType.sleep);
      }
    });

    test('maps the whole export scope', () {
      expect(healthPermTypeOf(HealthDataType.RESTING_HEART_RATE),
          HealthPermType.restingHr);
      expect(healthPermTypeOf(HealthDataType.HEART_RATE_VARIABILITY_SDNN),
          HealthPermType.hrv);
      expect(healthPermTypeOf(HealthDataType.HEART_RATE_VARIABILITY_RMSSD),
          HealthPermType.hrv);
      expect(healthPermTypeOf(HealthDataType.RESPIRATORY_RATE),
          HealthPermType.respRate);
      expect(healthPermTypeOf(HealthDataType.HEART_RATE),
          HealthPermType.heartRate);
      expect(healthPermTypeOf(HealthDataType.ACTIVE_ENERGY_BURNED),
          HealthPermType.activeEnergy);
      expect(healthPermTypeOf(HealthDataType.BASAL_ENERGY_BURNED),
          HealthPermType.basalEnergy);
      expect(healthPermTypeOf(HealthDataType.STEPS), HealthPermType.steps);
      expect(healthPermTypeOf(HealthDataType.WORKOUT), HealthPermType.workout);
      expect(healthPermTypeOf(HealthDataType.WEIGHT), HealthPermType.weight);
    });

    test('types outside the scope map to null', () {
      expect(healthPermTypeOf(HealthDataType.BLOOD_GLUCOSE), isNull);
      expect(healthPermTypeOf(HealthDataType.BLOOD_OXYGEN), isNull);
    });
  });

  group('healthPermTypesFor', () {
    test('unique rows in first-seen order, sleep collapsed', () {
      final rows = healthPermTypesFor([
        HealthDataType.SLEEP_DEEP,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.SLEEP_REM,
        HealthDataType.STEPS,
        HealthDataType.SLEEP_IN_BED,
      ]);
      expect(rows, [
        HealthPermType.sleep,
        HealthPermType.restingHr,
        HealthPermType.steps,
      ]);
    });

    test('empty scope yields no rows', () {
      expect(healthPermTypesFor(const []), isEmpty);
    });
  });

  group('HealthPermissionSummary', () {
    test('counts each state and flags denial', () {
      final s = HealthPermissionSummary({
        'a': HealthWriteAuth.authorized,
        'b': HealthWriteAuth.denied,
        'c': HealthWriteAuth.notDetermined,
        'd': HealthWriteAuth.unknown,
      });
      expect(s.total, 4);
      expect(s.authorized, 1);
      expect(s.denied, 1);
      expect(s.notDetermined, 1);
      expect(s.unknown, 1);
      expect(s.anyDenied, isTrue);
      expect(s.allAuthorized, isFalse);
    });

    test('an empty read is not "all authorized"', () {
      final s = HealthPermissionSummary(const {});
      expect(s.total, 0);
      expect(s.allAuthorized, isFalse);
      expect(s.anyDenied, isFalse);
    });

    test('all authorized only when every read row is authorized', () {
      final s = HealthPermissionSummary({
        'a': HealthWriteAuth.authorized,
        'b': HealthWriteAuth.authorized,
      });
      expect(s.allAuthorized, isTrue);
      expect(s.anyDenied, isFalse);
    });

    test('one unknown among grants is not "all authorized"', () {
      final s = HealthPermissionSummary({
        'a': HealthWriteAuth.authorized,
        'b': HealthWriteAuth.unknown,
      });
      expect(s.allAuthorized, isFalse);
    });
  });

  group('MethodChannelHealthAuthReader', () {
    const channel = MethodChannel('openstrap/health_auth');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('parses the native reply; keys missing from it stay unknown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'writeStatus');
        expect(call.arguments, {
          'types': ['sleep', 'steps', 'hrv']
        });
        return <Object?>[
          {'type': 'sleep', 'status': 'sharingAuthorized'},
          {'type': 'steps', 'status': 'sharingDenied'},
          {'type': 'bogus', 'status': 'denied'},
        ];
      });
      final reader = MethodChannelHealthAuthReader(channel: channel);
      final m = await reader.read(['sleep', 'steps', 'hrv']);
      expect(m['sleep'], HealthWriteAuth.authorized);
      expect(m['steps'], HealthWriteAuth.denied);
      expect(m['hrv'], HealthWriteAuth.unknown);
      expect(m.containsKey('bogus'), isFalse);
    });

    test('a throwing channel yields all-unknown and never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable');
      });
      final reader = MethodChannelHealthAuthReader(channel: channel);
      final m = await reader.read(['sleep', 'weight']);
      expect(m, {
        'sleep': HealthWriteAuth.unknown,
        'weight': HealthWriteAuth.unknown,
      });
    });

    test('a null reply yields all-unknown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final reader = MethodChannelHealthAuthReader(channel: channel);
      final m = await reader.read(['sleep']);
      expect(m['sleep'], HealthWriteAuth.unknown);
    });

    test('an empty key list never calls the platform', () async {
      var called = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        called = true;
        return <Object?>[];
      });
      final reader = MethodChannelHealthAuthReader(channel: channel);
      expect(await reader.read(const []), isEmpty);
      expect(called, isFalse);
    });
  });
}
