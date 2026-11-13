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
  'companion_url': 'a server address a restored file must not be able to set; '
      'it redirects announcements, updates and uploads',
  'backup.folder': 'storage-access URI permission belongs to this phone',
  'backup.last_run_ms': 'status of this install\'s automatic backup',
  'backup.last_error': 'status of this install\'s automatic backup',
  'ble.ask_add_pending': 'transient pairing prompt pending on this phone',
  'live.session_draft': 'unfinished workout entries, including private sessions, stay local',
  'live_session_checkpoint': 'write-ahead step recovery for this phone; replay could duplicate steps',
  'telemetry_outbox': 'queued diagnostics belong to this install and its consent',
  'device_alerts.low_armed': 'low-battery latch belongs to the old band; '
      'the new band must establish its own battery state',
  'alarm_schedule_cleared': 'records that Cancel-all ran on this phone, so an '
      'import cannot bring a cancelled alarm back',
  'alarm_epoch': 'arm belongs to the old band; the restored schedule must arm again',
  'alarm_epoch_confirmed': 'confirmation belongs to an arm on the old band',
  'alarm_set_at_ms': 'confirmation replay floor for the old band arm',
  'alarm_pending_until': 'pending confirmation window for the old band arm',
  'alarm_latch_alert': 'pending latch alert for the old band arm',
  'alarm_probe_pending': 'legacy pending hardware probe; never resume on another band',
  'alarm_fired_at': 'last fire event from the old band, not the chosen schedule',
  'health_upload_last_ts': 'upload cursor for this installation',
  'health_weight_perm_asked': 'WEIGHT write access is asked per install; '
      'the new install has not asked yet',
  'health_weight_grant_seen': 'the WEIGHT grant is per install; the new '
      'install observes its own',
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
    this.refusedPrefs = const [],
  });

  final Set<String> keysWritten;
  final List<String> needsReentry;
  /// Read failed or timed out; absence is unknown. A later import retries it.
  final List<String> unreadableSecrets;
  /// Rows in the backup that could not be read; skipped, the rest restored.
  final List<String> refusedPrefs;
}

/// The stored type of each backed-up key the app reads with a typed getter.
/// A row of another type is refused, not written: the getter throws on a cast
/// mismatch (int vs double included), on every launch after the restore. A
/// backed-up key missing here is written as-is; the guard test keeps this
/// table complete. Keys in [kPrefsNotBackedUp] need no entry.
const Map<String, String> kPrefTypes = {
  'activity.nap_auto_log_since_sec': 'int',
  'ai.journal_done_day': 'string',
  'ai_evening_enabled': 'bool',
  'ai_evening_min': 'int',
  'ai_journal_enabled': 'bool',
  'ai_journal_min': 'int',
  'ai_morning_enabled': 'bool',
  'ai_morning_min': 'int',
  'backup.cadence': 'string',
  'band.strap_name': 'string',
  'clock_format': 'string',
  'coach_api': 'string',
  'coach_model': 'string',
  'coach_timeout_seconds': 'int',
  'coach_use_chatgpt': 'bool',
  'cycle_tracking_enabled': 'bool',
  'dev.mode': 'bool',
  'device_alerts.charge_shown_day': 'int',
  'device_alerts.last_charge_event_ts': 'int',
  'device_alerts.last_charge_wall_sec': 'int',
  'gesture_double_tap': 'string',
  'health_auto_import_last_ms': 'int',
  'health_auto_import_workouts': 'bool',
  'health_import_profile_at': 'int',
  'health_import_workouts_at': 'int',
  'health_sync': 'bool',
  'health_workout_import_deleted': 'stringList',
  'issue_reports_sent': 'string',
  'last_inactivity_ms': 'int',
  'last_recovery_notif_day': 'string',
  'last_staleness_notified_ms': 'int',
  'last_stepgoal_day': 'string',
  'local_profile_json': 'string',
  'locale_override': 'string',
  'notif_alarm_latch_failed': 'bool',
  'notif_alarm_night_check': 'bool',
  'notif_auto_detect': 'bool',
  'notif_battery_pct': 'int',
  'notif_checkin': 'bool',
  'notif_critical_override': 'bool',
  'notif_device': 'bool',
  'notif_fired_keys': 'stringList',
  'notif_health': 'bool',
  'notif_meds': 'bool',
  'notif_movement': 'bool',
  'notif_nap_detect': 'bool',
  'notif_quiet_enabled': 'bool',
  'notif_quiet_end': 'int',
  'notif_quiet_start': 'int',
  'notif_recovery': 'bool',
  'notif_relay_enabled': 'bool',
  'notif_relay_packages': 'stringList',
  'notif_relay_seen': 'stringList',
  'notif_reminders': 'bool',
  'notif_stepgoal': 'bool',
  'notif_water': 'bool',
  'notif_water_interval': 'int',
  'notif_winddown': 'bool',
  'nutrition.barcode_lookup': 'bool',
  'onboard.completed': 'bool',
  'onboard.saw_profile_setup': 'bool',
  'onboard.skipped_pairing': 'bool',
  'onboarding_choice': 'string',
  'phone_steps': 'bool',
  'phone_steps_healthstore_purged': 'bool',
  'rough_night.ask': 'string',
  'rough_night.dismissed': 'string',
  'share.map_tiles': 'bool',
  'theme_choice': 'string',
  'ui.shell_tab': 'int',
  'ui.shell_tab.v2': 'int',
  'ui.wearable_show_estimates': 'bool',
  'ui.wearable_side_by_side': 'bool',
  'units_system': 'string',
  'update_checks_enabled': 'bool',
  'whoop_import_deleted_workouts': 'stringList',
  'workout.rpe_skips': 'int',
  'workout.zone_alert_enabled': 'bool',
  'workout.zone_alert_target_zone': 'int',
};

/// Dated or per-item key families: (prefix, suffix, stored type).
const List<(String, String, String)> kPrefTypeFamilies = [
  ('ai.briefing.', '', 'string'),
  ('ecg.guard.', '', 'bool'),
  ('ecg.wrist.', '', 'string'),
  ('ecg.maverick.', '', 'bool'),
  ('notif_fired:', '', 'bool'),
  ('notif_osid:', '', 'int'),
  ('notif_osslot:', '', 'string'),
  ('notif_osnext:', '', 'int'),
  ('nudge.', '.dismissed', 'bool'),
  ('nudge.', '.last_shown_ms', 'int'),
  // Per-scale weighing export state. Travels: the Health store usually
  // survives a restore, and re-sending every weighing would stack duplicates.
  ('health_weight_exported:', '', 'string'),
  ('health_weight_attempts:', '', 'string'),
  ('health_weight_maybe_landed:', '', 'string'),
  ('health_weight_trimmed:', '', 'string'),
];

/// The stored type the app reads [key] with, or null when it is not known.
String? expectedPrefType(String key) {
  final exact = kPrefTypes[key];
  if (exact != null) return exact;
  for (final (prefix, suffix, type) in kPrefTypeFamilies) {
    if (key.startsWith(prefix) && key.endsWith(suffix)) return type;
  }
  return null;
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
      if (prefs.get('coach_chatgpt_present') == true) {
        await tx.insert('backup_secrets', {'key': 'coach_chatgpt'});
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
      final d = double.parse(value);
      if (!d.isFinite) throw const FormatException('invalid preference number');
      return prefs.setDouble(key, d);
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

/// This phone has no server of its own: unset, blank, or the default saved
/// explicitly. Either way the user would silently stay on the default.
bool _needsServerReentry(String? saved) {
  final v = saved?.trim() ?? '';
  return v.isEmpty || v == CoachConfig.defaultBaseUrl;
}

Future<ImportSummary> restoreBackupPrefs(String path, Map<String, int> counts, {
  required bool freshInstall,
}) async {
  final src = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    final written = <String>{};
    final refused = <String>[];
    if (await _hasTable(src, 'backup_prefs')) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final row in await src.query('backup_prefs')) {
        final key = row['key'] as String;
        if (!_backedUp(key) || (!freshInstall && prefs.containsKey(key))) {
          continue;
        }
        // A malformed row is skipped and reported, so one bad value cannot
        // block every setting after it. Storage refusing a write is a real
        // failure and must not be reported as a successful restore.
        final want = expectedPrefType(key);
        if (want != null && row['type'] != want) {
          refused.add(key);
          continue;
        }
        final bool ok;
        try {
          ok = await _write(prefs, key, '${row['type']}', '${row['value']}');
        } on FormatException {
          refused.add(key);
          continue;
        }
        if (!ok) throw StateError('Could not restore preference $key');
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
        _needsServerReentry((await SharedPreferences.getInstance())
            .getString('coach_base_url'))) {
      needs.add('coach_base_url');
    }
    if (await _hasTable(src, 'backup_secrets') &&
        (await src.query('backup_secrets', where: 'key = ?',
            whereArgs: ['coach_chatgpt'])).isNotEmpty &&
        (await SharedPreferences.getInstance()).get('coach_chatgpt_present') != true) {
      needs.add('coach_chatgpt');
    }
    return ImportSummary(counts,
        keysWritten: Set.unmodifiable(written), needsReentry: List.unmodifiable(needs),
        unreadableSecrets: List.unmodifiable(unreadable),
        refusedPrefs: List.unmodifiable(refused));
  } finally {
    await src.close();
  }
}
