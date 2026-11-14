// The armed alarm epoch is stored with the band that holds it. The owner must
// be written BEFORE the epoch and every write checked: if the owner write
// fails the epoch must not be saved under the previous owner, where it would
// read back as the previous band's arm and as nothing for the band that took it.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart' show refreshAfterPair;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/failing_preferences_store.dart';

void main() {
  late SharedPreferencesStorePlatform original;

  setUp(() {
    original = SharedPreferencesStorePlatform.instance;
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = original);

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  group('saveArmedAlarmEpoch', () {
    test('a new band takes the arm: old epoch cleared, owner then epoch written',
        () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'A'});
      await saveArmedAlarmEpoch(prefs, 200, 'B');
      expect(prefs.getString(kAlarmRemoteId), 'B');
      expect(persistedAlarmEpoch(prefs, 'B'), 200);
      expect(persistedAlarmEpoch(prefs, 'A'), isNull);
    });

    test('the same band just refreshes its epoch', () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'A'});
      await saveArmedAlarmEpoch(prefs, 200, 'A');
      expect(persistedAlarmEpoch(prefs, 'A'), 200);
    });

    test('a failed owner write throws and never saves the epoch under the old owner',
        () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'A'});
      SharedPreferencesStorePlatform.instance = FailingPreferencesStore(
          SharedPreferencesStorePlatform.instance,
          key: kAlarmRemoteId,
          throws: false);
      await expectLater(saveArmedAlarmEpoch(prefs, 200, 'B'), throwsStateError);
      expect(prefs.getInt('alarm_epoch'), isNull,
          reason: 'neither the old nor the new epoch is left behind');
      expect(persistedAlarmEpoch(prefs, 'A'), isNull,
          reason: 'the previous band is not handed a different band\'s epoch');
    });

    test('a failed clear of the previous epoch throws before the owner changes',
        () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'A'});
      SharedPreferencesStorePlatform.instance = FailingPreferencesStore(
          SharedPreferencesStorePlatform.instance,
          key: 'alarm_epoch',
          throws: false);
      await expectLater(saveArmedAlarmEpoch(prefs, 200, 'B'), throwsStateError);
      expect(prefs.getString(kAlarmRemoteId), 'A',
          reason: 'the owner is only changed after the old epoch is gone');
    });

    test('a clear that lands during the owner change stops the older epoch', () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'A'});
      var current = true;
      SharedPreferencesStorePlatform.instance = _OnWrite(
          SharedPreferencesStorePlatform.instance,
          'flutter.$kAlarmRemoteId',
          () => current = false); // a clear/newer arm starts during the write
      final saved = await saveArmedAlarmEpoch(prefs, 200, 'B',
          stillCurrent: () => current);
      expect(saved, isFalse);
      expect(prefs.getInt('alarm_epoch'), isNull,
          reason: 'the superseded epoch must not be written after the clear');
    });

    test('superseded before anything is written: nothing is touched', () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'A'});
      final saved = await saveArmedAlarmEpoch(prefs, 200, 'B',
          stillCurrent: () => false);
      expect(saved, isFalse);
      expect(prefs.getInt('alarm_epoch'), 100);
      expect(prefs.getString(kAlarmRemoteId), 'A');
    });

    test('with no paired band the epoch is saved untagged, as before', () async {
      final prefs = await prefsWith({});
      await saveArmedAlarmEpoch(prefs, 200, null);
      expect(prefs.getInt('alarm_epoch'), 200);
      expect(prefs.getString(kAlarmRemoteId), isNull);
    });
  });

  group('bindAlarmEpochToBand', () {
    test('tags an untagged epoch with the band being left', () async {
      final prefs = await prefsWith({'alarm_epoch': 100});
      expect(await bindAlarmEpochToBand(prefs, 'A'), isTrue);
      expect(persistedAlarmEpoch(prefs, 'B'), isNull);
      expect(persistedAlarmEpoch(prefs, 'A'), 100);
    });

    test('leaves another band\'s tagged epoch alone', () async {
      final prefs = await prefsWith({'alarm_epoch': 100, kAlarmRemoteId: 'X'});
      expect(await bindAlarmEpochToBand(prefs, 'A'), isTrue);
      expect(prefs.getString(kAlarmRemoteId), 'X');
    });
  });

  group('refreshAfterPair', () {
    test('a failing refresh does not turn a saved pairing into a failure', () async {
      expect(await refreshAfterPair(() async => throw StateError('db busy')),
          isFalse);
    });

    test('a working refresh reports success', () async {
      var ran = false;
      expect(await refreshAfterPair(() async => ran = true), isTrue);
      expect(ran, isTrue);
    });
  });
}

// Runs [onWrite] when the matching key is written, then lets the write through.
class _OnWrite extends SharedPreferencesStorePlatform {
  _OnWrite(this.delegate, this.key, this.onWrite);
  final SharedPreferencesStorePlatform delegate;
  final String key;
  final void Function() onWrite;
  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();
  @override
  Future<bool> clear() => delegate.clear();
  @override
  Future<bool> remove(String key) => delegate.remove(key);
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (key == this.key) onWrite();
    return delegate.setValue(type, key, value);
  }
}
