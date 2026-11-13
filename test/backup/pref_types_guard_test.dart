// Every backed-up preference the app reads with a typed getter has its stored
// type in kPrefTypes (or a family in kPrefTypeFamilies). Restore refuses a row
// of another type; without an entry here that check silently does not apply
// and a mistyped row would make the getter throw on every later launch.
//
// Scans lib/ for `.getString/getBool/getInt/getDouble/getStringList(<key>)`.
// A key is a literal or a `const` name (aliases followed). A key built at run
// time must be listed in _dynamicReads with sample keys it can take.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/backup_extras.dart';

/// "file|expression|type" -> keys the call can read. The table must give each
/// one that exact type. `*` as the file skips the file check.
const _dynamicReads = <String, List<String>>{
  'briefing.dart|_slotKey(period|string': ['ai.briefing.morning'],
  'ecg_guard_store.dart|guardKey(serial|bool': ['ecg.guard.S1'],
  'ecg_guard_store.dart|wristKey(serial|string': ['ecg.wrist.S1'],
  'ecg_guard_store.dart|maverickKey(serial|bool': ['ecg.maverick.S1'],
  'health_import_state.dart|what.key|int': [
    'health_import_profile_at', 'health_import_workouts_at',
  ],
  'device_alerts.dart|key|int': [
    'device_alerts.last_charge_event_ts', 'device_alerts.last_charge_wall_sec',
    'device_alerts.charge_shown_day', 'notif_battery_pct',
  ],
  "fired_keys.dart|'\$_prefix\$dedupeKey'|bool": ['notif_fired:2026-09-21:x'],
  'notification_center.dart|prefsKey|string': [
    'last_recovery_notif_day', 'last_stepgoal_day',
  ],
  'notification_ids.dart|nextKey|int': ['notif_osnext:health'],
  'notification_ids.dart|slotKey|int': ['notif_osid:health:2026-09-21:x'],
  'notification_ids.dart|ownerKey|string': ['notif_osslot:health:3'],
  'notification_ids.dart|k|int': ['notif_osid:health:2026-09-21:x'],
  'health_weight_export.dart|healthWeightExportedKey(id|string': [
    'health_weight_exported:d1',
  ],
  'health_weight_export.dart|healthWeightAttemptsKey(id|string': [
    'health_weight_attempts:d1',
  ],
  'health_weight_export.dart|healthWeightMaybeLandedKey(id|string': [
    'health_weight_maybe_landed:d1',
  ],
  'health_weight_export.dart|healthWeightTrimmedKey(id|string': [
    'health_weight_trimmed:d1',
  ],
  'nudges.dart|_dismissedKey(a|bool': ['nudge.pairing.dismissed'],
  'nudges.dart|_lastShownKey(a|int': ['nudge.pairing.last_shown_ms'],
  // The typed wrappers; each caller passes a literal or a const that is
  // scanned like any other read.
  'prefs.dart|key|int': [],
  'prefs.dart|key|string': [],
  'prefs.dart|key|bool': [],
};

/// A key read with two types is a bug in the app; none is excused today.
const _readWithTwoTypes = <String, String>{};

final _constRe = RegExp(
    r'''(?:static\s+)?const\s+(?:String\s+)?(\w+)\s*=\s*(?:'([^'$]*)'|"([^"$]*)")\s*;''');
final _aliasRe = RegExp(
    r'(?:static\s+)?const\s+(?:String\s+)?(\w+)\s*=\s*([A-Za-z_]\w*(?:\.\w+)?)\s*;');
final _readRe = RegExp(
    r'\.(getString|getBool|getInt|getDouble|getStringList)\(\s*([^,)]+?)\s*[,)]');

const _typeOf = {
  'getString': 'string', 'getBool': 'bool', 'getInt': 'int',
  'getDouble': 'double', 'getStringList': 'stringList',
};

String _base(String path) => path.split('/').last;

void main() {
  final files = Directory('lib').listSync(recursive: true)
      .whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
  final text = {for (final f in files) f.path: f.readAsStringSync()};

  // name -> value, per file and across lib (the latter only when unambiguous).
  final local = <String, Map<String, String>>{};
  final global = <String, Set<String>>{};
  void add(String file, String name, String value) {
    (local[file] ??= {})[name] = value;
    (global[name] ??= {}).add(value);
  }

  for (final e in text.entries) {
    for (final m in _constRe.allMatches(e.value)) {
      add(e.key, m.group(1)!, m.group(2) ?? m.group(3)!);
    }
  }
  // Aliases (`const _k = otherConst;`), a few rounds deep.
  for (var round = 0; round < 3; round++) {
    for (final e in text.entries) {
      for (final m in _aliasRe.allMatches(e.value)) {
        final name = m.group(1)!;
        if (local[e.key]?.containsKey(name) ?? false) continue;
        final target = m.group(2)!.split('.').last;
        final v = local[e.key]?[target] ??
            (global[target]?.length == 1 ? global[target]!.single : null);
        if (v != null) add(e.key, name, v);
      }
    }
  }

  String? resolve(String file, String expr) {
    if ((expr.startsWith("'") && expr.endsWith("'")) ||
        (expr.startsWith('"') && expr.endsWith('"'))) {
      return expr.contains(r'$') ? null : expr.substring(1, expr.length - 1);
    }
    final name = expr.split('.').last;
    return local[file]?[name] ??
        (global[name]?.length == 1 ? global[name]!.single : null);
  }

  final reads = <String, Map<String, Set<String>>>{}; // key -> type -> sites
  final dynamicSeen = <String>{};
  final unlisted = <String>[];
  for (final e in text.entries) {
    for (final m in _readRe.allMatches(e.value)) {
      final type = _typeOf[m.group(1)]!;
      final expr = m.group(2)!;
      final line = e.value.substring(0, m.start).split('\n').length;
      final key = resolve(e.key, expr);
      if (key != null) {
        ((reads[key] ??= {})[type] ??= {}).add('${e.key}:$line');
        continue;
      }
      final id = '${_base(e.key)}|$expr|$type';
      if (_dynamicReads.containsKey(id)) {
        dynamicSeen.add(id);
      } else {
        unlisted.add('${e.key}:$line  $expr  ($type)');
      }
    }
  }

  test('the scan finds the reads it is meant to guard', () {
    expect(reads.length, greaterThan(70));
    expect(reads['local_profile_json']!.keys, {'string'});
    expect(reads['notif_water_interval']!.keys, {'int'});
    expect(reads['notif_relay_packages']!.keys, {'stringList'});
  });

  test('a key read at run time is listed with the keys it can take', () {
    expect(unlisted, isEmpty,
        reason: 'add each to _dynamicReads with sample keys, or use a const');
    expect(_dynamicReads.keys.toSet().difference(dynamicSeen), isEmpty,
        reason: 'stale _dynamicReads entries');
  });

  test('no key is read with two different types', () {
    final two = {
      for (final e in reads.entries)
        if (e.value.length > 1) e.key: e.value,
    };
    expect(two.keys.toSet().difference(_readWithTwoTypes.keys.toSet()), isEmpty,
        reason: '$two');
  });

  test('every backed-up key that is read has its type in the table', () {
    final wrong = <String>[];
    void check(String key, String type, String where) {
      if (kPrefsNotBackedUp.containsKey(key)) return;
      final want = expectedPrefType(key);
      if (want != type) wrong.add('$key read as $type at $where; table: $want');
    }

    for (final e in reads.entries) {
      for (final t in e.value.entries) {
        check(e.key, t.key, t.value.first);
      }
    }
    for (final e in _dynamicReads.entries) {
      final type = e.key.split('|').last;
      for (final k in e.value) {
        check(k, type, e.key);
      }
    }
    expect(wrong, isEmpty);
  });

  test('the table has no entry nothing reads, and none that is denylisted', () {
    final read = {
      ...reads.keys,
      for (final v in _dynamicReads.values) ...v,
    };
    expect(kPrefTypes.keys.where((k) => !read.contains(k)), isEmpty,
        reason: 'stale kPrefTypes entries');
    expect(kPrefTypes.keys.where(kPrefsNotBackedUp.containsKey), isEmpty,
        reason: 'a denylisted key never reaches restore');
    for (final t in kPrefTypes.values) {
      expect(const {'string', 'bool', 'int', 'double', 'stringList'}, contains(t));
    }
    for (final (prefix, suffix, type) in kPrefTypeFamilies) {
      expect(prefix, isNotEmpty);
      expect(suffix, isA<String>());
      expect(const {'string', 'bool', 'int', 'double', 'stringList'}, contains(type));
    }
  });
}
