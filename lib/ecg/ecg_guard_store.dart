// The durable per-band ECG facts, keyed by band serial:
//
//  • the MAY-BE-ACTIVE GUARD — set (and acknowledged) before every Labrador
//    ON/START write, cleared only after all three cleanup responses
//    succeeded. Physical MG firmware keeps generation, raw-save and the live
//    filtered publisher running through process death and disconnect until a
//    client sends the cleanup triplet, so this must survive the process.
//  • the wrist the user wears this band on;
//  • whether this serial was ever positively identified as a WHOOP MG.
//
// SharedPreferences through the awaited API (not the fire-and-forget Prefs
// façade): a guard write that did not land must be reported, because the
// caller refuses to enable the band on a guard it cannot trust.

import 'package:shared_preferences/shared_preferences.dart';

import 'ecg_models.dart';

abstract class EcgGuardStore {
  Future<bool> isActive(String serial);

  /// Returns whether the write was acknowledged durable.
  Future<bool> setActive(String serial);
  Future<bool> clear(String serial);

  Future<EcgWrist?> wrist(String serial);
  Future<void> setWrist(String serial, EcgWrist wrist);

  Future<bool> isRememberedMaverick(String serial);
  Future<void> rememberMaverick(String serial);
}

class PrefsEcgGuardStore implements EcgGuardStore {
  static String guardKey(String serial) => 'ecg.guard.$serial';
  static String wristKey(String serial) => 'ecg.wrist.$serial';
  static String maverickKey(String serial) => 'ecg.maverick.$serial';

  Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  @override
  Future<bool> isActive(String serial) async =>
      (await _p).getBool(guardKey(serial)) ?? false;

  @override
  Future<bool> setActive(String serial) async {
    try {
      return await (await _p).setBool(guardKey(serial), true);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> clear(String serial) async {
    try {
      return await (await _p).setBool(guardKey(serial), false);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<EcgWrist?> wrist(String serial) async =>
      EcgWrist.parse((await _p).getString(wristKey(serial)));

  @override
  Future<void> setWrist(String serial, EcgWrist wrist) async =>
      (await _p).setString(wristKey(serial), wrist.name);

  @override
  Future<bool> isRememberedMaverick(String serial) async =>
      (await _p).getBool(maverickKey(serial)) ?? false;

  @override
  Future<void> rememberMaverick(String serial) async =>
      (await _p).setBool(maverickKey(serial), true);
}

/// In-memory store for tests. [failWrites] makes every guard write report
/// not-acknowledged.
class MemoryEcgGuardStore implements EcgGuardStore {
  final Set<String> active = {};
  final Map<String, EcgWrist> wrists = {};
  final Set<String> maverick = {};
  bool failWrites = false;
  final List<String> log = [];

  @override
  Future<bool> isActive(String serial) async => active.contains(serial);

  @override
  Future<bool> setActive(String serial) async {
    log.add('set:$serial');
    if (failWrites) return false;
    active.add(serial);
    return true;
  }

  @override
  Future<bool> clear(String serial) async {
    log.add('clear:$serial');
    if (failWrites) return false;
    active.remove(serial);
    return true;
  }

  @override
  Future<EcgWrist?> wrist(String serial) async => wrists[serial];

  @override
  Future<void> setWrist(String serial, EcgWrist wrist) async =>
      wrists[serial] = wrist;

  @override
  Future<bool> isRememberedMaverick(String serial) async =>
      maverick.contains(serial);

  @override
  Future<void> rememberMaverick(String serial) async => maverick.add(serial);
}
