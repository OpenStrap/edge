// Source guards back up the export/import behavior tests. New preference keys
// travel by default; exclusions and secure stores must name a reason.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

Map<String, String> _constants(String text) => {
  for (final m in RegExp(r'''(?:const|final)\s+(?:String\s+)?(\w+)\s*=\s*['"]([^'"\n]+)['"]''').allMatches(text))
    m.group(1)!: m.group(2)!,
};

String? _key(String expr, String text) {
  final literal = RegExp(r'''^['"]([^'"]+)['"]$''').firstMatch(expr);
  if (literal != null) return literal.group(1);
  if (expr.startsWith('Prefs.')) {
    return _constants(File('lib/state/prefs.dart').readAsStringSync())[
        expr.substring('Prefs.'.length)];
  }
  return _constants(text)[expr];
}

void main() {
  final lib = Directory('lib').listSync(recursive: true).whereType<File>()
      .where((f) => f.path.endsWith('.dart')).toList();
  final writes = RegExp(r'''\.(setString|setStringList|setBool|setBoolAcked|setInt|setDouble)\(\s*('[^']*'|"[^"]*"|[\w.]+)\s*,''');
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_audit_test.db'));
  tearDownAll(() async => env.dispose());

  test('every written preference is carried or excluded with a reason', () async {
    final keys = <String>{};
    for (final f in lib) {
      final text = f.readAsStringSync();
      for (final m in writes.allMatches(text)) {
        final key = _key(m.group(2)!, text);
        if (key != null && !key.contains(r'$')) keys.add(key);
      }
    }
    expect(keys, containsAll(['theme_choice', 'backup.cadence', 'coach_model',
      'local_profile_json', 'consent_chosen']), reason: 'scanner positive control');
    final denied = policyMap('kPrefsNotBackedUp');
    await env.wipe();
    await setPrefs({for (final key in keys) key: 'audit value'});
    final path = await LocalDb.exportCopy();
    final prefs = await exportedPrefs(path);
    expect(prefs, isNotNull);
    expect(prefs!.keys.toSet(), keys.difference(denied.keys.toSet()));
  });

  test('denylisted keys are real and each has a reason', () {
    final all = lib.where((f) => f.path != 'lib/data/backup_extras.dart')
        .map((f) => f.readAsStringSync()).join('\n');
    final denied = policyMap('kPrefsNotBackedUp');
    expect(denied.keys, containsAll(['install_device_id', 'consent_chosen',
      'consent_telemetry', 'consent_health_data', 'coach_api_key_present']));
    for (final e in denied.entries) {
      expect(e.value.length, greaterThan(10), reason: e.key);
      expect(all, contains("'${e.key}'"), reason: '${e.key} is a stale exclusion');
    }
  });

  test('a credential never sits in plain preferences', () {
    final credential = RegExp(r'api_key|secret|password|auth_token');
    expect(credential.hasMatch('coach_api_key'), isTrue);
    final bad = <String>[];
    for (final f in lib) {
      final text = f.readAsStringSync();
      for (final m in writes.allMatches(text)) {
        final key = _key(m.group(2)!, text);
        if (key != null && credential.hasMatch(key) &&
            !key.endsWith('_present')) {
          bad.add('${f.path}: $key');
        }
      }
    }
    expect(bad, isEmpty);
  });

  test('every secure-storage owner is listed with a reason', () {
    final owners = {
      for (final f in lib)
        if (f.path != 'lib/data/backup_extras.dart' &&
            f.readAsStringSync().contains('FlutterSecureStorage')) f.path,
    };
    expect(owners, contains('lib/coach/coach_config.dart'));
    final secrets = policyMap('kSecretsNotBackedUp');
    expect(secrets.keys.toSet(), owners);
    for (final e in secrets.entries) {
      expect(e.value.length, greaterThan(10), reason: e.key);
    }
  });
}
