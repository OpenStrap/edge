// Settings carried by full exports. These tables exist only in the copy;
// the live schema and database restore table list never include them.
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../coach/coach_config.dart' show CoachConfig;

const Map<String, String> kPrefsNotBackedUp = {
  'install_device_id': 'identifies this install; a restore must not clone it',
  'paired_remote_id': 'BLE address bonded to this phone; pair again',
  'paired_serial': 'identity mirror of the band paired to this phone',
  'paired_generation': 'hardware generation of the band paired to this phone',
  'paired_worn_on': 'wearing mirror includes a BLE handle; the device-row merge restores the choice',
  'consent_telemetry': 'consent is asked again on each install',
  'consent_health_data': 'consent is asked again on each install',
  'consent_chosen': 'the consent question is asked again as a whole',
  'coach_api_key_present': 'the keychain payload does not travel; this marker '
      'would claim a key the new phone does not hold',
  'coach_chatgpt_present': 'the secure sign-in session does not travel; '
      'sign in to ChatGPT again on this phone',
  'coach_chatgpt_client_id': 'OAuth client registered for this installation; '
      'a new sign-in registers its own client',
  'coach_chatgpt_host_id': 'identifies this phone to the sign-in service',
  'coach_chatgpt_welcomed': 'the new sign-in must show its welcome on this phone',
  'coach_base_url': 'a custom server address can carry an access key; '
      'a non-default one is reported for re-entry',
  'backup.folder': 'storage-access URI permission belongs to this phone',
  'backup.last_run_ms': 'status of this install\'s automatic backup',
  'backup.last_error': 'status of this install\'s automatic backup',
  'ble.ask_add_pending': 'transient pairing prompt pending on this phone',
  'live.session_draft': 'unfinished workout entries, including private sessions, stay local',
  'live_session_checkpoint': 'write-ahead step recovery for this phone; replay could duplicate steps',
  'telemetry_outbox': 'queued diagnostics belong to this install and its consent',
  'alarm_epoch': 'arm belongs to the old band; the restored schedule must arm again',
  'alarm_epoch_confirmed': 'confirmation belongs to an arm on the old band',
  'alarm_set_at_ms': 'confirmation replay floor for the old band arm',
  'alarm_pending_until': 'pending confirmation window for the old band arm',
  'alarm_latch_alert': 'pending latch alert for the old band arm',
  'alarm_probe_pending': 'legacy pending hardware probe; never resume on another band',
  'alarm_fired_at': 'last fire event from the old band, not the chosen schedule',
  'health_upload_last_ts': 'upload cursor for this installation',
};

const Map<String, String> kSecretsNotBackedUp = {
  'lib/coach/coach_config.dart': 'coach API key is a credential in secure '
      'storage; a missing key is reported for re-entry after import',
  'lib/coach/coach_chatgpt.dart': 'ChatGPT access and refresh tokens stay in '
      'secure storage; sign in again on the new phone',
  'lib/ble/miband_link.dart': 'Mi Band pairing key is a credential; '
      'pair the band again on this phone',
  'lib/ble/oura_link.dart': 'Oura pairing key is a credential; '
      'pair the ring again on this phone',
};

/// The app root reloads presentation controllers after AppState adopts prefs.
final settingsRestoredSignal = ValueNotifier<int>(0);

/// Keeps the existing row-count API while reporting settings and lost secrets.
class ImportSummary extends MapView<String, int> {
  ImportSummary(super.map, {
    this.keysWritten = const {},
    this.needsReentry = const [],
    this.unreadableSecrets = const [],
  });

  final Set<String> keysWritten;
  final List<String> needsReentry;
  /// Read failed or timed out; absence is unknown. A later import retries it.
  final List<String> unreadableSecrets;
}

bool _backedUp(String key) => !kPrefsNotBackedUp.containsKey(key);

(String, String)? _encode(Object? value) => switch (value) {
  bool b => ('bool', '$b'),
  int i => ('int', '$i'),
  double d => ('double', '$d'),
  String s => ('string', s),
  List l => ('stringList', jsonEncode(l.cast<String>())),
  _ => null,
};

Future<void> writeBackupPrefs(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final copy = await openDatabase(path, singleInstance: false);
  try {
    await copy.transaction((tx) async {
      await tx.execute('CREATE TABLE backup_prefs '
          '(key TEXT PRIMARY KEY, type TEXT NOT NULL, value TEXT NOT NULL)');
      for (final key in prefs.getKeys()) {
        if (!_backedUp(key)) continue;
        final value = _encode(prefs.get(key));
        if (value == null) continue;
        await tx.insert('backup_prefs', {
          'key': key, 'type': value.$1, 'value': value.$2,
        });
      }
      // Presence only, never the credential or its denylisted preference.
      // Do not access the keychain during export (it may be locked).
      await tx.execute('CREATE TABLE backup_secrets (key TEXT PRIMARY KEY)');
      if (prefs.get('coach_api_key_present') == true) {
        await tx.insert('backup_secrets', {'key': 'coach_api_key'});
      }
      final server = prefs.get('coach_base_url');
      if (server is String && server.isNotEmpty && server != CoachConfig.defaultBaseUrl) {
        await tx.insert('backup_secrets', {'key': 'coach_base_url'});
      }
    });
  } finally {
    await copy.close();
  }
}

Future<bool> _hasTable(Database db, String table) async =>
    (await db.rawQuery('SELECT 1 FROM sqlite_master '
        "WHERE type = 'table' AND name = ?", [table])).isNotEmpty;

Future<bool> _write(SharedPreferences prefs, String key,
    String type, String value) async {
  switch (type) {
    case 'bool':
      if (value != 'true' && value != 'false') {
        throw const FormatException('invalid preference boolean');
      }
      return prefs.setBool(key, value == 'true');
    case 'int':
      return prefs.setInt(key, int.parse(value));
    case 'double':
      return prefs.setDouble(key, double.parse(value));
    case 'string':
      return prefs.setString(key, value);
    case 'stringList':
      final list = jsonDecode(value);
      if (list is! List || list.any((v) => v is! String)) {
        throw const FormatException('invalid preference list');
      }
      return prefs.setStringList(key, list.cast<String>());
    default:
      throw FormatException('unknown preference type $type');
  }
}

Future<ImportSummary> restoreBackupPrefs(String path, Map<String, int> counts, {
  required bool freshInstall,
}) async {
  final src = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    final written = <String>{};
    if (await _hasTable(src, 'backup_prefs')) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final row in await src.query('backup_prefs')) {
        final key = row['key'] as String;
        if (!_backedUp(key) || (!freshInstall && prefs.containsKey(key))) {
          continue;
        }
        // Bad rows fail visibly; storage refusing a write must not be
        // reported as a successful settings restore.
        if (!await _write(prefs, key, '${row['type']}', '${row['value']}')) {
          throw StateError('Could not restore preference $key');
        }
        written.add(key);
      }
    }
    final needs = <String>[];
    final unreadable = <String>[];
    if (await _hasTable(src, 'backup_secrets') &&
        (await src.query('backup_secrets', where: 'key = ?',
            whereArgs: ['coach_api_key'])).isNotEmpty) {
      try {
        final key = await const FlutterSecureStorage().read(key: 'coach_api_key')
            .timeout(const Duration(seconds: 6));
        if (key == null || key.isEmpty) needs.add('coach_api_key');
      } catch (_) {
        unreadable.add('coach_api_key');
      }
    }
    if (await _hasTable(src, 'backup_secrets') &&
        (await src.query('backup_secrets', where: 'key = ?',
            whereArgs: ['coach_base_url'])).isNotEmpty &&
        !(await SharedPreferences.getInstance()).containsKey('coach_base_url')) {
      needs.add('coach_base_url');
    }
    return ImportSummary(counts,
        keysWritten: Set.unmodifiable(written), needsReentry: List.unmodifiable(needs),
        unreadableSecrets: List.unmodifiable(unreadable));
  } finally {
    await src.close();
  }
}
