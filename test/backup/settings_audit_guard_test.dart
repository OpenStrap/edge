// Source guards back up the export/import behavior tests. New preference keys
// travel by default; exclusions and secure stores must name a reason.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_extras.dart' show expectedPrefType;
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup_support.dart';

// Deliberately independent of kPrefsNotBackedUp. Changing production policy
// must not silently change the expected export. Add new settings here by hand.
const _mustTravel = {
  'theme_choice', 'locale_override', 'units_system', 'clock_format',
  'local_profile_json', 'onboarding_choice', 'onboard.completed',
  'onboard.skipped_pairing', 'onboard.saw_profile_setup',
  'backup.cadence', 'gesture_double_tap', 'band.strap_name',
  'health_sync', 'phone_steps', 'cycle_tracking_enabled', 'update_checks_enabled',
  'nutrition.barcode_lookup', 'share.map_tiles', 'dev.mode',
  // The user's opt-in, with when it was given. Restored imports are fenced by
  // alert_after_ts, so a restored timestamp cannot log old naps.
  'activity.nap_auto_log_since_sec',
  'coach_api', 'coach_model', 'coach_timeout_seconds',
  'coach_use_chatgpt',
  'ai_morning_enabled', 'ai_morning_min', 'ai_evening_enabled', 'ai_evening_min',
  'ai_journal_enabled', 'ai_journal_min',
  'workout.zone_alert_enabled', 'workout.zone_alert_target_zone', 'workout.rpe_skips',
  'notif_health', 'notif_recovery', 'notif_reminders', 'notif_device',
  'notif_quiet_enabled', 'notif_quiet_start', 'notif_quiet_end',
  'notif_critical_override', 'notif_water', 'notif_water_interval',
  'notif_auto_detect', 'notif_nap_detect', 'notif_movement', 'notif_meds',
  'notif_checkin', 'notif_battery_pct', 'notif_stepgoal', 'notif_winddown',
  'notif_alarm_latch_failed', 'notif_alarm_night_check',
  'notif_relay_enabled', 'notif_relay_packages',
  'ui.shell_tab.v2', 'ui.recap_range', 'ui.workouts_range',
  'ui.wearable_show_estimates', 'ui.wearable_side_by_side',
  'rough_night.ask', 'rough_night.dismissed',
  // Existing history/dedupe state travels to avoid repeated alerts/imports.
  'ai.journal_done_day', 'last_recovery_notif_day', 'last_stepgoal_day',
  'last_inactivity_ms', 'last_staleness_notified_ms', 'notif_relay_seen',
  'health_auto_import_last_ms', 'health_auto_import_workouts',
  'health_import_profile_at', 'health_import_workouts_at',
  'health_workout_import_deleted', 'phone_steps_healthstore_purged',
  'whoop_import_deleted_workouts', 'issue_reports_sent',
  'device_alerts.last_charge_event_ts', 'device_alerts.last_charge_wall_sec',
  'device_alerts.charge_shown_day',
  // One concrete member of each dynamic family below.
  'notif_fired:2026-09-21:low_read',
  'notif_osid:health:2026-09-21:low_read', 'notif_osslot:health:0',
  'notif_osnext:health', 'ui.metric_tab.sleep',
  'nudge.discord.dismissed', 'nudge.discord.last_shown_ms',
  'ai.briefing.morning',
  // Serial-scoped ECG safety guards must survive so reconnect still cleans up
  // a possibly active publisher. These are separate from alarm arm receipts.
  'ecg.guard.MG123', 'ecg.wrist.MG123', 'ecg.maverick.MG123',
  // Weighing export state: the Health store usually survives a restore, so
  // the marks must too, or every weighing is written again as a duplicate.
  'health_weight_exported:d1', 'health_weight_attempts:d1',
  'health_weight_maybe_landed:d1', 'health_weight_trimmed:d1',
  'future.setting',
};

const _mustStay = {
  'device_alerts.low_armed',
  'install_device_id', 'paired_remote_id', 'paired_serial', 'paired_generation',
  'paired_worn_on', 'ble.ask_add_pending',
  'consent_telemetry', 'consent_health_data', 'consent_chosen',
  'coach_api_key_present', 'coach_chatgpt_present', 'coach_chatgpt_client_id',
  'coach_chatgpt_host_id', 'coach_chatgpt_welcomed', 'coach_base_url', 'companion_url',
  'backup.folder', 'backup.last_run_ms', 'backup.last_error', 'health_upload_last_ts',
  'alarm_schedule_cleared', 'alarm_epoch', 'alarm_epoch_confirmed', 'alarm_set_at_ms',
  'alarm_pending_until', 'alarm_latch_alert', 'alarm_probe_pending', 'alarm_fired_at',
  'live.session_draft', 'live_session_checkpoint', 'telemetry_outbox',
  // Permission and grant are per install.
  'health_weight_perm_asked', 'health_weight_grant_seen',
};

// Interpolated keys, including ones hidden behind key-building helpers.
// Notification dedupe/allocation survives to avoid replaying alerts; UI choices
// and community-ask dismissal/cooldown are user preferences. metricTab has no
// current writer, but its public key builder is covered for future callers.
const _dynamicExamples = {
  r'ai.briefing.${p.id}': 'ai.briefing.morning',
  r'ecg.guard.$serial': 'ecg.guard.MG123',
  r'ecg.wrist.$serial': 'ecg.wrist.MG123',
  r'ecg.maverick.$serial': 'ecg.maverick.MG123',
  r'$_prefix$dedupeKey': 'notif_fired:2026-09-21:low_read',
  r'$_prefix$k': 'notif_fired:2026-09-21:low_read',
  r'$_kSlot$cat:${e.dedupeKey}': 'notif_osid:health:2026-09-21:low_read',
  r'$_kOwner$cat:$slot': 'notif_osslot:health:0',
  r'$_kNext$cat': 'notif_osnext:health',
  r'ui.metric_tab.$metric': 'ui.metric_tab.sleep',
  r'nudge.${a.name}.dismissed': 'nudge.discord.dismissed',
  r'nudge.${a.name}.last_shown_ms': 'nudge.discord.last_shown_ms',
};

// Runtime arguments and aliased constants the literal scanner cannot resolve.
// Empty lists are delegating writers, audited at their owning call sites.
const _indirectKeys = <String, List<String>>{
  'lib/ai/briefing.dart:_slotKey(b.period)': ['ai.briefing.morning'],
  'lib/ecg/ecg_guard_store.dart:guardKey(serial)': ['ecg.guard.MG123'],
  'lib/ecg/ecg_guard_store.dart:wristKey(serial)': ['ecg.wrist.MG123'],
  'lib/ecg/ecg_guard_store.dart:maverickKey(serial)': ['ecg.maverick.MG123'],
  'lib/data/backup_extras.dart:key': [], // generic restore of backup_prefs
  'lib/state/prefs.dart:key': [], // generic SharedPreferences facade
  'lib/notify/device_alerts.dart:key': [
    'device_alerts.last_charge_event_ts', 'device_alerts.last_charge_wall_sec',
    'device_alerts.charge_shown_day', 'device_alerts.low_armed'],
  'lib/notify/notification_center.dart:prefsKey': [
    'last_recovery_notif_day', 'last_stepgoal_day'],
  'lib/health/health_import_state.dart:what.key': [
    'health_import_profile_at', 'health_import_workouts_at'],
  'lib/notify/notification_prefs.dart:_kBatteryPct': ['notif_battery_pct'],
  'lib/state/app_state.dart:_kHealthSync': ['health_sync'],
  'lib/sync/paired_device.dart:_kWornOn': ['paired_worn_on'],
  'lib/sync/paired_device.dart:key': [
    'paired_remote_id', 'paired_serial', 'paired_generation'],
  'lib/ui2/onboarding/pairing.dart:key': [
    'onboard.skipped_pairing', 'onboard.saw_profile_setup'],
  'lib/ui2/nudges.dart:_lastShownKey(a)': ['nudge.discord.last_shown_ms'],
  'lib/ui2/nudges.dart:_dismissedKey(a)': ['nudge.discord.dismissed'],
  'lib/health/health_export.dart:kHealthWeightPermAskedPref': [
    'health_weight_perm_asked'],
  'lib/health/health_weight_export.dart:healthWeightExportedKey(id)': [
    'health_weight_exported:d1'],
  'lib/health/health_weight_export.dart:healthWeightAttemptsKey(id)': [
    'health_weight_attempts:d1'],
  'lib/health/health_weight_export.dart:healthWeightMaybeLandedKey(id)': [
    'health_weight_maybe_landed:d1'],
  'lib/health/health_weight_export.dart:healthWeightTrimmedKey(id)': [
    'health_weight_trimmed:d1'],
};

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
  final writes = RegExp(r'''\.(setString|setStringList|setBool|setBoolAcked|setInt|setDouble)\(\s*('[^']*'|"[^"]*"|[\w.]+(?:\([^()]*\))?)\s*,''');
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_audit_test.db'));
  tearDownAll(() async => env.dispose());

  test('every written key has an independent policy, including dynamic families', () {
    final keys = <String>{};
    final indirect = <String>{};
    for (final f in lib) {
      final text = f.readAsStringSync();
      for (final m in writes.allMatches(text)) {
        final key = _key(m.group(2)!, text);
        if (key == null) {
          final owner = '${f.path}:${m.group(2)}';
          expect(_indirectKeys, contains(owner), reason: 'unresolved writer $owner');
          indirect.add(owner);
          keys.addAll(_indirectKeys[owner]!);
        } else if (key.contains(r'$')) {
          expect(_dynamicExamples, contains(key), reason: 'uncovered key family $key');
          keys.add(_dynamicExamples[key]!);
        } else {
          keys.add(key);
        }
      }
    }
    expect(indirect, _indirectKeys.keys.toSet(), reason: 'stale indirect-key audit');
    expect(keys, containsAll(['theme_choice', 'backup.cadence', 'coach_model',
      'local_profile_json', 'consent_chosen', 'nudge.discord.dismissed']),
        reason: 'scanner positive control');
    expect(keys.difference({..._mustTravel, ..._mustStay}), isEmpty,
        reason: 'new preference needs a policy decision in this test');
    final all = lib.map((f) => f.readAsStringSync()).join('\n');
    for (final e in _dynamicExamples.entries) {
      expect(all, contains(e.key), reason: 'stale dynamic family ${e.key}');
      expect(_mustTravel, contains(e.value), reason: e.key);
    }
  });

  test('required user settings and dynamic keys actually travel', () async {
    await env.wipe();
    await setPrefs({for (final key in {..._mustTravel, ..._mustStay}) key: 'audit value'});
    final prefs = (await exportedPrefs(await LocalDb.exportCopy()))!;
    for (final key in _mustTravel) {
      expect(prefs[key], ('string', 'audit value'), reason: '$key must travel');
    }
  });

  test('device and transient keys never travel, including foreign backups', () async {
    await env.wipe();
    // Typed as the app reads them: restore refuses a row of another type.
    await setPrefs({
      for (final key in {..._mustTravel, ..._mustStay}) key: switch (expectedPrefType(key)) {
        'bool' => true,
        'int' => 1,
        'double' => 1.5,
        'stringList' => <String>['audit value'],
        _ => 'audit value',
      },
    });
    final path = await LocalDb.exportCopy();
    final prefs = (await exportedPrefs(path))!;
    for (final key in _mustStay) {
      expect(prefs, isNot(contains(key)), reason: '$key stays on the phone');
    }
    // Even an old or foreign export that carries blocked state cannot inject it.
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    for (final key in _mustStay) {
      await copy.insert('backup_prefs',
          {'key': key, 'type': 'string', 'value': 'foreign state'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await copy.close();
    await env.wipe();
    final restored = await LocalDb.importFromDbFile(path);
    expect(restored.keysWritten, _mustTravel);
    expect((await allPrefs()).keys.toSet(), _mustTravel);
  });

  test('denylisted keys are real and each has a reason', () {
    final all = lib.where((f) => f.path != 'lib/data/backup_extras.dart')
        .map((f) => f.readAsStringSync()).join('\n');
    final denied = policyMap('kPrefsNotBackedUp');
    expect(denied.keys.toSet(), _mustStay, reason: 'exclusions need an explicit test policy');
    expect(denied.keys, containsAll(['install_device_id', 'consent_chosen',
      'consent_telemetry', 'consent_health_data', 'coach_api_key_present']));
    for (final e in denied.entries) {
      expect(e.value.length, greaterThan(10), reason: e.key);
      // This legacy probe is explicitly blocked on foreign/older backups too.
      if (e.key != 'alarm_probe_pending') {
        expect(all, contains("'${e.key}'"), reason: '${e.key} is a stale exclusion');
      }
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
