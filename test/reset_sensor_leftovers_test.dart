// What a "delete everything" can leave behind on the secondary-sensor side:
// a scale session the reset itself ended still firing its session-done hook
// (which adopts a weighing back into the profile), a pairing key orphaned by
// a crash mid-pair (no `device` row, so the row ids never find it), and a
// keychain delete that throws being reported as a clean wipe.

import 'dart:collection';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/ble/oura_link.dart';
import 'package:openstrap_edge/ble/session_link.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

/// A key store whose deletes throw, like a locked keychain.
class _UndeletableMap extends MapBase<String, String> {
  final Map<String, String> _m;
  _UndeletableMap(this._m);
  @override
  String? operator [](Object? key) => _m[key];
  @override
  void operator []=(String key, String value) => _m[key] = value;
  @override
  void clear() => throw StateError('keychain locked');
  @override
  Iterable<String> get keys => _m.keys;
  @override
  String? remove(Object? key) => throw StateError('keychain locked');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(ResetGate.resetForTest);

  group('session-done hook', () {
    tearDown(() => SessionLink.onSessionDone = null);

    test('does not run for a session a reset ended', () async {
      var calls = 0;
      SessionLink.onSessionDone = () async => calls++;
      final gen = ResetGate.generation;
      ResetGate.enter();
      ResetGate.leave();
      expect(SessionLink.runSessionDone(gen), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
    });

    test('still runs when no reset happened', () async {
      var calls = 0;
      SessionLink.onSessionDone = () async => calls++;
      expect(SessionLink.runSessionDone(ResetGate.generation), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    });

    test('adoptWeighing re-checks the reset before every write', () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      final start = src.indexOf('Future<void> adoptWeighing() async');
      final body = src.substring(start, src.indexOf('\n  }\n', start));
      for (final write in [
        'if (reverted != null) {\n      await updateProfile(reverted, '
            'resetGeneration: resetGen);',
        'if (next != null) await updateProfile(next, resetGeneration: resetGen);',
        'await rederiveDays(',
      ]) {
        final at = body.indexOf(write);
        expect(at, greaterThan(0), reason: '$write not found');
        final before = body.substring(0, at).trimRight();
        expect(
          before.endsWith('if (reset()) return;'),
          isTrue,
          reason: '$write is not preceded by a reset check',
        );
      }
    });

    test('updateProfile does not write over a reset that ran while it waited',
        () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      final start = src.indexOf('Future<Map<String, dynamic>> updateProfile(');
      final body = src.substring(start, src.indexOf('\n  }\n', start));
      final gen = body.indexOf('final resetGen = resetGeneration ?? '
          'ResetGate.generation;');
      final wait = body.indexOf('await SharedPreferences.getInstance();');
      final check =
          body.indexOf('if (ResetGate.changedSince(resetGen)) return {...?user};');
      final write = body.indexOf('await prefs.setString(_kProfile');
      expect(gen, greaterThan(0));
      expect(gen, lessThan(wait));
      expect(check, greaterThan(wait));
      expect(write, greaterThan(check));
    });
  });

  group('pairing keys on reset', () {
    test('an orphaned key with no device row is dropped too', () async {
      final store = <String, String>{
        'oura_pairing_key:known': 'aa',
        'oura_pairing_key:orphan': 'bb',
        'miband234_pairing_key:orphan': 'cc',
        'unrelated': 'dd',
      };
      FlutterSecureStorage.setMockInitialValues(store);
      expect(await OuraLink.dropStoredKeys(['known']), isTrue);
      expect(
        store.keys,
        unorderedEquals(['miband234_pairing_key:orphan', 'unrelated']),
      );
      expect(await MiBand234Link.dropStoredKeys(const []), isTrue);
      expect(store.keys, ['unrelated']);
    });

    test('a delete that throws is reported, not swallowed', () async {
      FlutterSecureStorage.setMockInitialValues(
        _UndeletableMap({'oura_pairing_key:known': 'aa'}),
      );
      expect(await OuraLink.dropStoredKeys(['known']), isFalse);
      expect(await MiBand234Link.dropStoredKeys(['known']), isFalse);
    });

    test('settings tells the user when a key may remain', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      expect(src.contains('if (app.resetLeftPairingKeys'), isTrue);
      expect(src.contains('l?.settingsResetPairingKeyWarning ??'), isTrue,
          reason: 'the warning must follow the app language');
    });
  });
}
