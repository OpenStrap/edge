// A refused keychain write must not leave the old key bound to a new endpoint:
// save() used to commit the base URL before the key, so a throw left
// apiBase = B with apiKey = A's key.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final keychain = <String, String>{};
  var refuse = false;

  setUp(() {
    keychain.clear();
    refuse = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (refuse && (call.method == 'write' || call.method == 'delete')) {
        throw PlatformException(code: 'refused');
      }
      switch (call.method) {
        case 'read':
          return keychain[args['key']];
        case 'write':
          keychain[args['key'] as String] = args['value'] as String;
        case 'delete':
          keychain.remove(args['key']);
        case 'containsKey':
          return keychain.containsKey(args['key']);
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  for (final newKey in ['sk-b', '']) {
    test('refused key ${newKey.isEmpty ? 'delete' : 'write'} keeps the old endpoint',
        () async {
      final cfg = CoachConfig();
      await cfg.save(baseUrl: 'https://a.example.com/v1', apiKey: 'sk-a');
      refuse = true;
      await expectLater(
        cfg.save(baseUrl: 'https://b.example.com/v1', apiKey: newKey),
        throwsA(isA<PlatformException>()),
      );
      expect(cfg.apiBase, contains('a.example.com'));
      expect(cfg.apiKey, 'sk-a');
    });
  }
}
