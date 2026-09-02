// Settings, and editing the profile.
//
// Two deliberate departures from the reference design:
//
//   · "Log out" is "Reset all data". Logging out of an app with no server is
//     theatre — it clears a session that does not exist while leaving every
//     byte on disk. The destructive action here is the honest one, and it says
//     what it destroys.
//   · Email, username, bio, location and date of birth are gone from the edit
//     form. None of them feed a metric, and a field that changes nothing is a
//     field that implies an account.

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/auto_backup.dart';
import '../../data/off_lookup.dart';
import '../../health/health_export.dart' show HealthLinkState;
import '../../health/health_import_state.dart';
import '../../health/health_profile_import.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/tasker_bridge.dart';
import '../../notify/notification_prefs.dart';
import '../../notify/notification_service.dart';
import '../../platform/app_icon.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../../state/units_controller.dart';
import '../../telemetry/health_uploader.dart';
import '../../theme/theme_controller.dart';
import '../ui2.dart';
import 'alarm.dart';
import 'band_notifications.dart';
import 'data.dart';
import 'gallery.dart';
import 'gestures.dart';
import 'profile.dart';

/// Unwind the profile stack back to the gate.
///
/// `_Gate` is `MaterialApp.home` — the BOTTOM of the navigator stack — so an
/// action that changes `AppState.route` swaps what is under everything without
/// popping any of it. Resetting all data, forgetting the band and asking to
/// pair again are all route changes taken from a pushed screen, and all three
/// used to leave the user staring at the screen they tapped from, describing a
/// state that no longer existed.
void backToRoot(BuildContext c) =>
    Navigator.of(c).popUntil((r) => r.isFirst);

// ══════════════════ MORE SETTINGS ══════════════════

/// Taps on the version row that reveal the developer group. The conventional
/// gesture, for the conventional reason: it is discoverable by anyone who
/// already knows it and invisible to everyone else.
const kDevTaps = 7;

class MoreSettings extends StatefulWidget {
  const MoreSettings({super.key});

  @override
  State<MoreSettings> createState() => _MoreSettingsState();
}

class _MoreSettingsState extends State<MoreSettings> {
  bool _dev = Prefs.getBool(Prefs.devMode, false);

  /// Whether a food barcode may be looked up online. Not on AppState: it is a
  /// screen-local preference like the map basemap's, read straight off Prefs.
  bool _barcode = offLookupAllowed;
  String _version = '';
  int _taps = 0;

  /// The home-screen icon, asked of the OS rather than stored — see
  /// lib/platform/app_icon.dart. Null until the answer arrives, and the row is
  /// not drawn at all where the OS cannot change it.
  AppIconChoice? _icon;

  @override
  void initState() {
    super.initState();
    _readVersion();
    _readIcon();
  }

  Future<void> _readIcon() async {
    if (!await AppIcon.available()) return;
    final now = await AppIcon.current();
    if (mounted) setState(() => _icon = now);
  }

  /// iOS puts up its own confirmation alert, so there is nothing to confirm
  /// here — but it can also be refused, and a refused change must not be drawn
  /// as if it happened. The row re-reads the OS either way.
  Future<void> _pickIcon(AppIconChoice choice) async {
    if (choice == _icon) return;
    await AppIcon.set(choice);
    final now = await AppIcon.current();
    if (mounted) setState(() => _icon = now);
  }

  Future<void> _readVersion() async {
    try {
      final i = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${i.version} (${i.buildNumber})');
    } catch (_) {/* no version, no row — and no way in */}
  }

  void _tapVersion() {
    if (_dev || ++_taps < kDevTaps) return;
    _setDev(true);
  }

  /// The one preference here that is awaited. A revocation that never reached
  /// storage is back ON at the next launch, so it does not get to fail quietly
  /// — the switch still moves (in-session it really is off, nothing is sent),
  /// and the person is told it did not stick.
  Future<void> _toggleBarcode(BuildContext c) async {
    final want = !_barcode;
    final messenger = ScaffoldMessenger.of(c);
    final saved = await setOffLookupAllowed(want);
    if (!mounted) return;
    setState(() => _barcode = want);
    if (!saved) {
      final l = AppLocalizations.of(context);
      messenger.showSnackBar(SnackBar(
        content: Text(l?.settingsBarcodeSaveFailed ??
            'That could not be saved — it may be back next time you '
                'open the app.'),
      ));
    }
  }

  void _setDev(bool on) {
    Prefs.setBool(Prefs.devMode, on);
    setState(() {
      _dev = on;
      _taps = 0;
    });
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final units = c.watch<UnitsController>();
    final theme = c.watch<ThemeController>();
    return MoreSettingsView(
      version: _version,
      devMode: _dev,
      onVersionTap: _tapVersion,
      onToggleDev: () => _setDev(false),
      onGallery: () => goto(c, const GalleryScreen()),
      units: units.system.label,
      appearance: theme.choice.label,
      cycleTracking: app.cycleTrackingEnabled,
      appIcon: _icon,
      onPickIcon: _pickIcon,
      phoneSteps: app.phoneStepsEnabled,
      telemetry: app.telemetryConsent,
      barcodeLookup: _barcode,
      // Shown when the build has the feature OR when this install already
      // consented under an older build. A consent that cannot be withdrawn is
      // not consent, and the old `lib/ui` toggle died with that package while
      // the pref — and the daily whole-database upload it authorises — did not.
      showHealthShare: kHealthDataContributionEnabled || app.healthShareConsent,
      healthShare: app.healthShareConsent,
      healthStore: app.healthStoreName,
      healthSync: app.healthSyncEnabled,
      healthState: app.healthState,
      showUpdateChecks: app.updateChecksAvailable,
      updateChecks: app.updateChecksEnabled,
      updateAvailable: app.updateAvailable,
      updateMandatory: app.updateMandatory,
      onEditProfile: () => goto(c, const EditProfile()),
      onAlarm: () => goto(c, const AlarmScreen()),
      onNotifications: () => goto(c, const NotificationSettings()),
      onData: () => goto(c, const DataScreen()),
      onAutomation: () => goto(c, const AutomationSettings()),
      onCycleUnits: () => units.setSystem(units.isImperial
          ? UnitSystem.metric
          : UnitSystem.imperial),
      onCycleAppearance: () => theme.setChoice(AppThemeChoice.values[
          (theme.choice.index + 1) % AppThemeChoice.values.length]),
      onToggleCycleTracking: () =>
          app.setCycleTrackingEnabled(!app.cycleTrackingEnabled),
      onTogglePhoneSteps: () => app.phoneStepsEnabled
          ? app.disablePhoneSteps()
          : app.requestPhoneSteps(),
      onToggleTelemetry: () => app.setTelemetryConsent(!app.telemetryConsent),
      onToggleBarcodeLookup: () => _toggleBarcode(c),
      onToggleHealthShare: () => _toggleHealthShare(c, app),
      onToggleHealthSync: () => _toggleHealthSync(app),
      onToggleUpdateChecks: () =>
          app.setUpdateChecksEnabled(!app.updateChecksEnabled),
      onReset: () => _confirmReset(c, app),
    );
  }
}

/// Pick the home-screen icon, with both options drawn so the choice is made by
/// looking rather than by reading a word.
///
/// Not a [SetRow]: a cycling value row would flip the icon on every tap, and
/// each flip on iOS is a system confirmation alert. Two targets, one tap, no
/// wrong taps to undo.
class _IconRow extends StatelessWidget {
  final AppIconChoice chosen;
  final ValueChanged<AppIconChoice>? onPick;

  const _IconRow({required this.chosen, this.onPick});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: p.wash(C.indigo), borderRadius: R.rSm),
          child: Icon(LucideIcons.image, size: 16, color: p.on(C.indigo)),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l?.settingsIconRowTitle ?? 'Icon',
                style: F.body.copyWith(color: p.ink)),
            // The cost, stated where the choice is made. iOS shows its own
            // alert on every change and there is no way to turn that off.
            Text(l?.settingsIconRowConfirmHint ?? 'iPhone will ask you to confirm',
                style: F.over.copyWith(color: p.ink3)),
          ]),
        ),
        const SizedBox(width: S.x2),
        for (final choice in AppIconChoice.values) ...[
          if (choice != AppIconChoice.values.first) const SizedBox(width: S.x2),
          _IconChoice(
            choice: choice,
            selected: choice == chosen,
            onTap: onPick == null ? null : () => onPick!(choice),
          ),
        ],
      ]),
    );
  }
}

class _IconChoice extends StatelessWidget {
  final AppIconChoice choice;
  final bool selected;
  final VoidCallback? onTap;

  const _IconChoice(
      {required this.choice, required this.selected, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    // Decoded at the size it is drawn at: the source is the 1024 px launcher
    // master, and decoding that in full to paint a 36 pt thumbnail is 4 MB of
    // bitmap per option.
    final px = (36 * MediaQuery.devicePixelRatioOf(c)).round();
    return Pressable(
      onTap: onTap,
      semanticLabel:
          '${l?.settingsIconChoiceLabel(choice.label) ?? '${choice.label} icon.'}'
          '${selected ? (l?.settingsSelectedSuffix ?? ' Selected.') : ''}',
      child: Container(
        padding: const EdgeInsets.all(S.x1 / 2),
        decoration: BoxDecoration(
          borderRadius: R.rMd,
          border: Border.all(
              color: selected ? p.on(C.indigo) : p.line, width: selected ? 2 : 1),
        ),
        child: ClipRRect(
          borderRadius: R.rSm,
          child: Image.asset(choice.asset,
              width: 36, height: 36, cacheWidth: px, cacheHeight: px),
        ),
      ),
    );
  }
}

/// Turn the Apple Health / Health Connect EXPORT on or off.
///
/// `setHealthSync` already requests the OS permission and kicks a first sync;
/// this row is the only thing that was ever missing. Until it existed the app
/// shipped a write entitlement, a usage string and ten Android WRITE_*
/// permissions for a code path that could not run — see
/// docs/internal/UNREACHABLE.md P1.
///
/// Health Connect has two failure modes that are not refusals and must not be
/// reported as one: it may not be installed, or it may be too old. Both are
/// answered with the action that fixes them rather than an error.
Future<void> _toggleHealthSync(AppState app) async {
  if (app.healthSyncEnabled) {
    await app.setHealthSync(false);
    return;
  }
  await app.setHealthSync(true);
  switch (app.healthState) {
    case HealthLinkState.notInstalled:
    case HealthLinkState.needsUpdate:
      await app.installHealthConnect();
    case HealthLinkState.needsPermission:
      // Android only sends the user to Health Connect's own screen; on iOS
      // there is nothing to open, and `openSettings` is a no-op there.
      await app.openHealthConnect();
    case HealthLinkState.ready:
    case HealthLinkState.unsupported:
    case HealthLinkState.unknown:
      break;
  }
}

/// One line saying what the export is actually doing right now.
String healthSyncSub(
    BuildContext c, bool on, HealthLinkState state, String store) {
  final l = AppLocalizations.of(c);
  if (!on) {
    return l?.settingsHealthSyncOff(store) ?? 'Off. Nothing is written to $store';
  }
  return switch (state) {
    HealthLinkState.ready => l?.settingsHealthSyncReady(store) ??
        'Writes each day’s sleep, resting heart rate, '
            'HRV, respiratory rate, energy and workouts to $store once it is final',
    HealthLinkState.needsPermission =>
      l?.settingsHealthSyncNeedsPermission(store) ??
          '$store has not granted write access. Tap to open it',
    HealthLinkState.notInstalled => l?.settingsHealthSyncNotInstalled ??
        'Health Connect is not installed. Tap to '
            'get it',
    HealthLinkState.needsUpdate => l?.settingsHealthSyncNeedsUpdate ??
        'Health Connect is too old to write to. Tap to update it',
    HealthLinkState.unsupported => l?.settingsHealthSyncUnsupported ??
        'This device has no health store to write to',
    HealthLinkState.unknown =>
      l?.settingsHealthSyncChecking(store) ?? 'Checking $store…',
  };
}

/// Grant or withdraw the whole-database health contribution.
///
/// Asymmetric on purpose. Granting is confirmed first — it authorises a daily
/// upload of the ENTIRE database, raw signal included, which is the largest
/// thing this app can ever send anywhere. Withdrawing takes effect
/// IMMEDIATELY, with no dialog in the way, and only then says what had already
/// been sent: a revocation you have to confirm is a revocation that can be
/// mis-tapped into staying on.
Future<void> _toggleHealthShare(BuildContext c, AppState app) async {
  if (app.healthShareConsent) {
    await app.setHealthShareConsent(false);
    final last = await HealthUploader.instance.lastUploadAt();
    if (!c.mounted) return;
    final l = AppLocalizations.of(c);
    await showDialog<void>(
      context: c,
      builder: (d) => AlertDialog(
        title: Text(l?.settingsHealthShareOffTitle ?? 'Contribution off'),
        content: Text(
          last == null
              ? (l?.settingsHealthShareOffNeverUploaded ??
                  'Nothing was ever uploaded. Nothing will be.')
              // What we KNOW, not what we hope: the revocation is posted
              // once, unawaited, with no retry queue, so offline it never
              // arrives and nothing here can tell.
              : (l?.settingsHealthShareOffDetail(
                      last.toLocal().toString().split('.').first) ??
                  'Nothing further will be uploaded.\n\n'
                      'One copy of your database was uploaded on '
                      '${last.toLocal().toString().split('.').first}. The server '
                      'keeps only the most recent copy per device. We tried to '
                      'tell it your consent is withdrawn — that message is sent '
                      'once and is not retried, so if this phone is offline it '
                      'will not have arrived, and we cannot show you that the copy '
                      'is gone either.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(d).pop(),
              child: Text(l?.settingsOk ?? 'OK')),
        ],
      ),
    );
    return;
  }
  final l = AppLocalizations.of(c);
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(
          l?.settingsHealthShareOnTitle ?? 'Contribute your health data?'),
      content: Text(
        l?.settingsHealthShareOnBody ??
            'Once a day, on Wi-Fi and while charging, a compressed copy of your '
                'ENTIRE database is uploaded — every derived day and every raw sensor '
                'row the band has sent. It is used to improve the algorithms.\n\n'
                'It is not anonymous in any meaningful sense: it is your whole health '
                'history. You can switch this off at any time, and nothing further '
                'is sent from that moment.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.settingsNo ?? 'No')),
        TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l?.settingsContribute ?? 'Contribute')),
      ],
    ),
  );
  if (ok == true) await app.setHealthShareConsent(true);
}

Future<void> _confirmReset(BuildContext c, AppState app) async {
  final l = AppLocalizations.of(c);
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(l?.settingsResetTitle ?? 'Delete everything?'),
      // Enumerated, because the previous wording ("every measured day, session
      // and profile field") was false in about twenty places: it deleted the
      // derived days and left the labs, the meals, the doses, the breathing
      // sessions, the logged sets, the baselines, the consent flags, the
      // install id, the stored API key and the home-screen widget standing.
      // It now removes all of that, so it can say so.
      content: Text(
        l?.settingsResetBody ??
            'This deletes, permanently and with no copy anywhere else:\n\n'
                '· every measured day, sleep, workout and route\n'
                '· every lab result, meal, medication dose, habit, breathing session '
                'and logged set\n'
                '· your journal, cycle log and rolling baselines\n'
                '· your profile, every preference and any stored AI key\n'
                '· the home-screen widget and every scheduled reminder\n\n'
                'The band is unpaired, and it cannot re-send history it has already '
                'handed over. Export from Your data first if you want a copy.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.settingsResetKeepData ?? 'Keep my data')),
        TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l?.settingsResetDeleteEverything ?? 'Delete everything')),
      ],
    ),
  );
  if (ok != true) return;
  await app.resetAllData();
  // "with no copy anywhere else" was false while automatic backup was on:
  // `wipeAll` deletes rows and cannot touch files, so up to [kBackupsKept]
  // gzipped whole-database copies survived in a folder the user can browse and
  // Import a file can read straight back.
  try {
    await pruneBackups(await backupDirectory(), keep: 0);
  } catch (_) {
    // No backup folder is the normal case — nothing to delete.
  }
  // resetAllData swaps the gate to Welcome, which is UNDER this screen —
  // without this the user stays on Settings, reading a profile that has been
  // deleted.
  if (c.mounted) backToRoot(c);
}

class MoreSettingsView extends StatelessWidget {
  final String units, appearance;
  final bool phoneSteps, telemetry, barcodeLookup, cycleTracking;

  /// The home-screen icon, or null where the OS will not change it — Android,
  /// and the managed iOS configurations that refuse. Null means the row is not
  /// drawn: a control that cannot do its one job is worse than no control.
  final AppIconChoice? appIcon;
  final ValueChanged<AppIconChoice>? onPickIcon;

  /// The health-contribution row appears only where it means something: a
  /// build that has the feature, or an install that already said yes to it.
  final bool showHealthShare, healthShare;

  /// The platform health EXPORT. `healthStore` names it — "Apple Health" or
  /// "Health Connect" — because "your health app" is not something a user can
  /// go and grant a permission in.
  final bool healthSync;
  final HealthLinkState healthState;
  final String healthStore;

  /// The update-check row appears only on a build that can check.
  final bool showUpdateChecks, updateChecks;

  /// What the last check ANSWERED. The check itself was already running and
  /// already storing its answer; this row is the only place in the app that
  /// says what it found, so without these two the whole poll was a no-op.
  final bool updateAvailable, updateMandatory;

  /// `0.9.26 (57)`, or empty until package_info answers — the About group is
  /// the whole reveal gesture, so it is not drawn against a blank.
  final String version;

  /// Off by default and off on every fresh install. The group it gates is not
  /// a feature: nothing in it is for anyone who has not deliberately asked.
  final bool devMode;

  final VoidCallback? onVersionTap, onToggleDev, onGallery;

  final VoidCallback? onEditProfile,
      onAlarm,
      onNotifications,
      onData,
      onAutomation,
      onCycleUnits,
      onCycleAppearance,
      onTogglePhoneSteps,
      onToggleTelemetry,
      onToggleBarcodeLookup,
      onToggleCycleTracking,
      onToggleHealthShare,
      onToggleHealthSync,
      onToggleUpdateChecks,
      onReset;

  const MoreSettingsView({
    super.key,
    this.units = 'Metric',
    this.appearance = 'System',
    this.appIcon,
    this.onPickIcon,
    this.phoneSteps = false,
    this.healthSync = false,
    this.healthState = HealthLinkState.unknown,
    this.healthStore = 'Apple Health',
    this.telemetry = false,
    this.barcodeLookup = true,
    this.cycleTracking = false,
    this.showHealthShare = false,
    this.healthShare = false,
    this.showUpdateChecks = false,
    this.updateChecks = true,
    this.updateAvailable = false,
    this.updateMandatory = false,
    this.version = '',
    this.devMode = false,
    this.onVersionTap,
    this.onToggleDev,
    this.onGallery,
    this.onEditProfile,
    this.onAlarm,
    this.onNotifications,
    this.onData,
    this.onAutomation,
    this.onCycleUnits,
    this.onCycleAppearance,
    this.onTogglePhoneSteps,
    this.onToggleTelemetry,
    this.onToggleBarcodeLookup,
    this.onToggleCycleTracking,
    this.onToggleHealthShare,
    this.onToggleHealthSync,
    this.onToggleUpdateChecks,
    this.onReset,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final on = l?.stateOn ?? 'On';
    final off = l?.stateOff ?? 'Off';
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsNavTitle ?? 'Settings'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                // No "Edit profile" here. It lives in one place — Quick access
                // on the Profile screen — because two doors to one form is how
                // a user ends up unsure which one is the real setting.
                settingsGroup(c, l?.settingsGroupTheBand ?? 'The band', [
                  SetRow(LucideIcons.alarmClock, C.orange,
                      l?.settingsAlarmRowTitle ?? 'Alarm',
                      sub: l?.settingsAlarmRowSub ??
                          'Buzzes on your wrist, on the band’s own clock',
                      onTap: onAlarm),
                ]),
                // NOT in Preferences. Units and Appearance change how numbers
                // are drawn; this one asks the OS for a sensor and decides
                // where a measurement comes from. Its own group, next to the
                // band, because the two together are the step ladder — the
                // band covers the workout, the phone covers the rest — and
                // "This phone" is what the sources screen already calls it.
                settingsGroup(c, l?.settingsGroupThisPhone ?? 'This phone', [
                  SetRow(LucideIcons.footprints, C.teal,
                      l?.settingsStepsRowTitle ?? 'Steps',
                      sub: l?.settingsStepsRowSub ??
                          'This phone’s own step counter, for the hours the '
                              'band doesn’t cover. Nothing leaves the device',
                      value: phoneSteps ? on : off,
                      onTap: onTogglePhoneSteps),
                ]),
                settingsGroup(
                    c, l?.settingsGroupNotifications ?? 'Notifications', [
                  SetRow(LucideIcons.bell, C.blue,
                      l?.settingsManageNotificationsRowTitle ??
                          'Manage notifications',
                      sub: l?.settingsManageNotificationsRowSub ??
                          'What may interrupt you, quiet hours, and off '
                              'switches for all of them',
                      onTap: onNotifications),
                ]),
                settingsGroup(c, l?.settingsGroupPreferences ?? 'Preferences', [
                  SetRow(LucideIcons.ruler, C.blue,
                      l?.settingsUnitsRowTitle ?? 'Units',
                      value: units, onTap: onCycleUnits),
                  SetRow(LucideIcons.sun, C.yellow,
                      l?.settingsAppearanceRowTitle ?? 'Appearance',
                      value: appearance, onTap: onCycleAppearance),
                  if (appIcon != null)
                    _IconRow(chosen: appIcon!, onPick: onPickIcon),
                  // Opt-in, and it says what it does rather than what it is
                  // about — "Cycle tracking" alone leaves you guessing whether
                  // switching it off throws the entries away.
                  SetRow(LucideIcons.droplet, C.pink,
                      l?.settingsCycleTrackingRowTitle ?? 'Cycle tracking',
                      sub: l?.settingsCycleTrackingRowSub ??
                          'Adds the Cycle tab to Wellness. Off hides it and '
                              'keeps everything already logged',
                      value: cycleTracking ? on : off,
                      onTap: onToggleCycleTracking),
                ]),
                settingsGroup(c, l?.settingsGroupYourData ?? 'Your data', [
                  SetRow(LucideIcons.download, C.green,
                      l?.settingsExportBackupImportRowTitle ??
                          'Export, backup, import',
                      sub: l?.settingsExportBackupImportRowSub ??
                          'Spreadsheets, a full copy, and bringing history in',
                      onTap: onData),
                  // The row P1 was missing. Everything behind it — the
                  // permission request, the retry/backoff, the four gates —
                  // was already written and simply had no way to be switched
                  // on, so the write entitlement and usage strings described a
                  // path that could not run.
                  SetRow(LucideIcons.heartPulse, C.red,
                      l?.settingsWriteToHealthStoreRowTitle(healthStore) ??
                          'Write to $healthStore',
                      sub: healthSyncSub(c, healthSync, healthState, healthStore),
                      value: healthSync ? on : off,
                      onTap: onToggleHealthSync),
                ]),
                settingsGroup(c, l?.settingsGroupAutomation ?? 'Automation', [
                  // The picker died with the old ui tree and the engine kept
                  // running against a mapping nothing could set — the whole
                  // feature was live code pinned at "do nothing".
                  Builder(
                      builder: (c) => SetRow(
                          LucideIcons.hand, C.orange,
                          AppLocalizations.of(c)?.settingsDoubleTapRowTitle ??
                              'Double-tap',
                          sub: AppLocalizations.of(c)
                                  ?.settingsDoubleTapRowSub ??
                              'What a double-tap on the band does',
                          onTap: () => goto(c, const BandGestures()))),
                  SetRow(LucideIcons.workflow, C.indigo,
                      l?.settingsTaskerShortcutsRowTitle ??
                          'Tasker and Shortcuts',
                      // The row states the asymmetry rather than leaving it to
                      // the screen: someone on an iPhone should learn what they
                      // are not getting before they tap into it.
                      sub: l?.settingsTaskerShortcutsRowSub ??
                          'Android only for events out. iOS can buzz the band '
                              'but cannot be triggered by it',
                      onTap: onAutomation),
                ]),
                settingsGroup(c, l?.settingsGroupPrivacy ?? 'Privacy', [
                  SetRow(LucideIcons.bug, C.orange,
                      l?.settingsCrashReportsRowTitle ?? 'Crash reports',
                      sub: l?.settingsCrashReportsRowSub ??
                          'Nothing is sent until you say so',
                      value: telemetry ? on : off,
                      onTap: onToggleTelemetry),
                  // The food log's one outbound call. Named by what it sends,
                  // not by the feature it powers — a scan is the only thing
                  // that triggers it and the barcode is the whole payload.
                  SetRow(LucideIcons.scanBarcode, C.domFood,
                      l?.settingsBarcodeLookupRowTitle ??
                          'Look barcodes up online',
                      sub: l?.settingsBarcodeLookupRowSub ??
                          'Sends a scanned barcode to openfoodfacts.org. '
                              'Nothing about you goes with it',
                      value: barcodeLookup ? on : off,
                      onTap: onToggleBarcodeLookup),
                  if (showHealthShare)
                    SetRow(LucideIcons.cloudUpload, C.red,
                        l?.settingsContributeHealthDataRowTitle ??
                            'Contribute my health data',
                        sub: l?.settingsContributeHealthDataRowSub ??
                            'Uploads your whole database once a day, on '
                                'Wi-Fi and charging, to improve the algorithms',
                        value: healthShare ? on : off,
                        onTap: onToggleHealthShare),
                  if (showUpdateChecks)
                    SetRow(LucideIcons.refreshCw, C.blue,
                        l?.settingsCheckForUpdatesRowTitle ??
                            'Check for updates',
                        sub: updateMandatory
                            ? (l?.settingsUpdateBelowMinimum ??
                                'This build is below the minimum supported '
                                    'build. Install the newer release from GitHub')
                            : updateAvailable
                                ? (l?.settingsUpdateAvailable ??
                                    'A newer build is published on GitHub')
                                : (l?.settingsUpdateCheckSub ??
                                    'Asks the release server on launch. It sees '
                                        'your IP address and when you open the app'),
                        value: updateChecks ? on : off,
                        onTap: onToggleUpdateChecks),
                ]),
                settingsGroup(c, l?.settingsGroupAbout ?? 'About', [
                  if (version.isNotEmpty)
                    SetRow(LucideIcons.info, C.n500,
                        l?.settingsVersionRowTitle ?? 'Version',
                        value: version, chevron: false, onTap: onVersionTap),
                  // Where the licences of what this app uses are written out
                  // in full. Open Food Facts' ODbL asks for the notice to be
                  // reachable, not only for the credit beside the numbers.
                  SetRow(LucideIcons.scale, C.n500,
                      l?.settingsNoticesLicencesRowTitle ??
                          'Notices and licences',
                      sub: l?.settingsNoticesLicencesRowSub ??
                          'Who this app is not, and whose data it uses',
                      onTap: () => launchUrl(
                          Uri.parse(
                              'https://openstrap.github.io/edge/notice.html'),
                          mode: LaunchMode.externalApplication)),
                ]),
                if (devMode)
                  settingsGroup(c, l?.settingsGroupDeveloper ?? 'Developer', [
                    SetRow(LucideIcons.layoutGrid, C.purple,
                        l?.settingsComponentGalleryRowTitle ??
                            'Component gallery',
                        sub: l?.settingsComponentGalleryRowSub ??
                            'Every component, at any text scale, in either '
                                'theme',
                        onTap: onGallery),
                    SetRow(LucideIcons.code, C.n500,
                        l?.settingsDeveloperModeRowTitle ?? 'Developer mode',
                        value: on, chevron: false, onTap: onToggleDev),
                  ]),
                const SizedBox(height: S.x6),
                Surface(
                  pad: const EdgeInsets.symmetric(horizontal: S.x4),
                  child: SetRow(LucideIcons.trash2, C.red,
                      l?.settingsResetAllDataRowTitle ?? 'Reset all data',
                      danger: true, chevron: false, onTap: onReset),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════ NOTIFICATIONS ══════════════════
//
// There are exactly three things this app may put in your notification shade:
// the alarm, the day's aggregated exception, and the weekly lookback when the
// week contained something. The app used to be able to emit around twenty-two
// kinds — hydration slots, step goals, posture nudges, AI briefings — and none
// of them had a switch anywhere in the app, so the only way to stop any of it
// was the OS. A notification the user cannot turn off is a bug, which makes
// this screen part of the fix rather than a nicety on top of it.
//
// The alarm is deliberately not switchable here: its off switch is cancelling
// the alarm, and burying a second one in settings is how an alarm silently
// fails to wake someone.
//
// The water reminder is on this screen and IS a shade entry — a strap buzz and
// a phone notification at the same minute, because a buzz alone needs a live
// link and a live isolate and so is not a reminder. It reminds you to LOG a
// drink — the app measures no hydration and this screen may never imply it
// does. See MT-14 in IDEAS.md.

class NotificationSettings extends StatefulWidget {
  const NotificationSettings({super.key});

  @override
  State<NotificationSettings> createState() => _NotificationSettingsState();
}

class _NotificationSettingsState extends State<NotificationSettings> {
  NotificationPrefs? _prefs;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await NotificationPrefs.load();
    final granted = await NotificationService.instance.hasPermission();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _granted = granted;
    });
  }

  /// Whether the strap-buzz relay exists on this platform. Android only —
  /// iOS gives no app access to another app's notifications — and the row is
  /// absent rather than disabled there, so there is nothing to explain.
  bool get _relaySupported =>
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> _apply(NotificationPrefs next) async {
    setState(() => _prefs = next);
    await next.save();
    // Re-run the scheduler so a switch that was just turned off actually
    // cancels what it was standing for, rather than taking effect at some
    // later resume.
    //
    // Through AppState, not straight at the NotificationCenter: the medication
    // slots need the med schedule and the check-in needs today's journal, and
    // only AppState can read either. Calling the centre directly cancels what
    // the switch turned off and arms nothing back, so meds stayed silent until
    // the next foreground pass.
    if (mounted) await context.read<AppState>().refreshAiReminders();
    // the water buzz is an in-memory timer, not an OS slot — re-arm it here or
    // the switch only takes effect at the next launch.
    if (mounted) await context.read<AppState>().armWaterReminder(next);
    // the low-battery threshold is restored once per process — push the new
    // value into the alert pipeline or it applies only after a restart.
    if (mounted) {
      await context.read<AppState>().refreshBatteryThreshold(next);
    }
  }

  /// The one contextual moment left where prompting is honest: the user is
  /// standing in the notifications screen, having just asked for one.
  Future<void> _requestPermission() async {
    final ok = await NotificationService.instance.ensurePermission();
    if (mounted) setState(() => _granted = ok);
  }

  @override
  Widget build(BuildContext c) {
    final p = _prefs;
    return NotificationSettingsView(
      prefs: p ?? const NotificationPrefs(),
      loaded: p != null,
      granted: _granted,
      relaySupported: _relaySupported,
      onChanged: _apply,
      onRequestPermission: _requestPermission,
    );
  }
}

class NotificationSettingsView extends StatelessWidget {
  final NotificationPrefs prefs;
  final bool loaded, granted;

  /// Android only. False hides the strap-buzz relay row entirely rather than
  /// showing a control that cannot work.
  final bool relaySupported;

  final Future<void> Function(NotificationPrefs next)? onChanged;
  final VoidCallback? onRequestPermission;

  const NotificationSettingsView({
    super.key,
    this.prefs = const NotificationPrefs(),
    this.loaded = true,
    this.granted = true,
    this.relaySupported = false,
    this.onChanged,
    this.onRequestPermission,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final on = l?.stateOn ?? 'On';
    final off = l?.stateOff ?? 'Off';
    void set(NotificationPrefs next) => onChanged?.call(next);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsNotificationsNavTitle ?? 'Notifications',
                sub: l?.settingsNotificationsNavSub ??
                    'WHAT MAY INTERRUPT YOU'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (!granted)
                  StatusCard(
                    l?.settingsNotificationsOffSystemTitle ??
                        'Notifications are off at the system level',
                    l?.settingsNotificationsOffSystemBody ??
                        'Nothing below can reach you until the OS lets it.',
                    fix: l?.settingsTurnThemOn ?? 'Turn them on',
                    icon: LucideIcons.bellOff,
                    onFix: onRequestPermission,
                  ),
                if (loaded) ...[
                  settingsGroup(
                      c,
                      l?.settingsGroupManageNotifications ??
                          'Manage notifications', [
                    SetRow(LucideIcons.heartPulse, C.red,
                        l?.settingsHealthExceptionsRowTitle ??
                            'Health exceptions',
                        sub: l?.settingsHealthExceptionsRowSub ??
                            'One a day at most, and only when something in '
                                'your own baseline moved',
                        value: prefs.healthEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            healthEnabled: !prefs.healthEnabled))),
                    SetRow(LucideIcons.watch, C.orange,
                        l?.settingsBandAlertsRowTitle ?? 'Band alerts',
                        sub: l?.settingsBandAlertsRowSub ??
                            'Flat battery, on the charger, gone quiet',
                        value: prefs.deviceEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            deviceEnabled: !prefs.deviceEnabled))),
                    // On by default, unlike the reminders below: this exists to
                    // catch a wake alarm that silently isn't going to fire, and
                    // starting silent would defeat the point.
                    SetRow(LucideIcons.alarmClock, C.red,
                        l?.settingsAlarmLatchFailedRowTitle ??
                            'Alarm not confirmed',
                        sub: l?.settingsAlarmLatchFailedRowSub ??
                            'Warn when the band never confirms an alarm this '
                                'app just armed',
                        value: prefs.alarmLatchFailedEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            alarmLatchFailedEnabled:
                                !prefs.alarmLatchFailedEnabled))),
                    // Also on by default, same reasoning: silent whenever an
                    // alarm IS armed for tonight, so it only ever speaks up
                    // about a real gap.
                    SetRow(LucideIcons.moon, C.red,
                        l?.settingsAlarmNightCheckRowTitle ??
                            'No-alarm check-in',
                        sub: l?.settingsAlarmNightCheckRowSub ??
                            'A 7pm heads-up on any night with no wake alarm '
                                'armed — silent otherwise',
                        value: prefs.alarmNightCheckEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            alarmNightCheckEnabled:
                                !prefs.alarmNightCheckEnabled))),
                    // The low-battery threshold, only while band alerts are
                    // on — an interval for a muted alert is furniture, same
                    // rule as the water row below.
                    if (prefs.deviceEnabled)
                      SetRow(LucideIcons.batteryLow, C.orange,
                          l?.settingsAlertMeAtRowTitle ?? 'Alert me at',
                          sub: l?.settingsAlertMeAtRowSub ??
                              'Warn when the band drops under this charge '
                                  'level',
                          value: '${prefs.batteryAlertPct}%',
                          chevron: false,
                          onTap: () => set(prefs.copyWith(
                              batteryAlertPct:
                                  _nextBatteryPct(prefs.batteryAlertPct)))),
                    // The retained recovery-channel switch, now with a real
                    // event behind it again: the morning "recovery is ready"
                    // note. It was cut in the three-class cull and sat dead —
                    // emitted, classified null, dropped.
                    SetRow(LucideIcons.activity, C.green,
                        l?.settingsRecoveryReadyRowTitle ?? 'Recovery ready',
                        sub: l?.settingsRecoveryReadyRowSub ??
                            'One note when your morning recovery score '
                                'lands',
                        value: prefs.recoveryEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            recoveryEnabled: !prefs.recoveryEnabled))),
                    // Says what it DOES now: the finding is computed from the
                    // week's own crossday rollup (medical flags first, then a
                    // plainly-stated resting-HR drift), and most weeks still
                    // say nothing — which is the point.
                    SetRow(LucideIcons.calendarDays, C.purple,
                        l?.settingsWeeklyLookbackRowTitle ??
                            'Weekly lookback',
                        sub: l?.settingsWeeklyLookbackRowSub ??
                            'Sunday evening, but only for a week that '
                                'actually found something. Most weeks are quiet',
                        value: prefs.remindersEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            remindersEnabled: !prefs.remindersEnabled))),
                    // The auto-detector's off switch, asked for twice (#102,
                    // #149) and never built: the bouts were written, the
                    // prompt was emitted, and nothing anywhere could stop
                    // either. The sub-line says exactly what it stops,
                    // because it does NOT stop the detection itself.
                    SetRow(LucideIcons.radar, C.green,
                        l?.settingsDetectedWorkoutsRowTitle ??
                            'Detected workouts',
                        sub: l?.settingsDetectedWorkoutsRowSub ??
                            'Ask about efforts the band spotted that you did '
                                'not start. Off hides the prompt and the review '
                                'cards; the band goes on measuring either way',
                        value: prefs.autoDetectEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            autoDetectEnabled: !prefs.autoDetectEnabled))),
                    // Off by default, and it is the switch that lets the nudge
                    // be scheduled at all — see
                    // NotificationService.schedulableIds. It had none, so it
                    // was refused there and had never once fired. Covers BOTH
                    // sedentary surfaces: the OS-scheduled two-hour-still
                    // one-shot, and the foreground desk-posture check (which
                    // also buzzes the band when it fires).
                    SetRow(LucideIcons.footprints, C.orange,
                        l?.settingsMovementNudgeRowTitle ?? 'Movement nudge',
                        sub: l?.settingsMovementNudgeRowSub ??
                            'Nudges you after a still stretch — two hours '
                                'with no movement at all, or 90 minutes in a '
                                'desk posture. Phone notification plus a buzz '
                                'on the band while it is connected',
                        value: prefs.movementEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            movementEnabled: !prefs.movementEnabled))),
                    // The wind-down nudge. Silent until the Sleep Coach has
                    // actually LEARNED a bedtime — the nudge's whole content
                    // is that time, so there is no honest fallback.
                    SetRow(LucideIcons.moonStar, C.indigo,
                        l?.settingsWindDownRowTitle ?? 'Wind-down',
                        sub: l?.settingsWindDownRowSub ??
                            'A heads-up about 45 minutes before the bedtime '
                                'learned from your own nights, kept clear of your '
                                'quiet hours. Appears after about a week of wear',
                        value: prefs.windDownEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            windDownEnabled: !prefs.windDownEnabled))),
                    // The step-goal achievement's off switch. On by default:
                    // once a day at most, and only on a real crossing.
                    SetRow(LucideIcons.trophy, C.orange,
                        l?.settingsStepGoalAlertsRowTitle ??
                            'Step goal alerts',
                        sub: l?.settingsStepGoalAlertsRowSub ??
                            'Tells you once when today crosses your steps '
                                'goal',
                        value: prefs.stepGoalEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            stepGoalEnabled: !prefs.stepGoalEnabled))),
                    // The one prompt whose time is not a guess: it is the
                    // schedule already typed into the Medication tab. Only a
                    // dose still due is armed, and the notification names no
                    // drug — it lands on a lock screen in front of whoever is
                    // in the room.
                    SetRow(LucideIcons.pill, C.blue,
                        l?.settingsMedicationRemindersRowTitle ??
                            'Medication reminders',
                        sub: l?.settingsMedicationRemindersRowSub ??
                            'One notification per scheduled dose, at the '
                                'times you entered — with a buzz on the band if '
                                'it is connected. Nothing is sent for a dose '
                                'already marked taken or skipped',
                        value: prefs.medsEnabled ? on : off,
                        chevron: false,
                        onTap: () =>
                            set(prefs.copyWith(medsEnabled: !prefs.medsEnabled))),
                    // ONE prompt for the whole journal, not one per field —
                    // mood, energy, stress and the rest are all the same
                    // screen, so five rows would be five interruptions for one
                    // minute of typing.
                    SetRow(LucideIcons.notebookPen, C.purple,
                        l?.settingsDailyCheckInRowTitle ?? 'Daily check-in',
                        sub: l?.settingsDailyCheckInRowSub ??
                            'One prompt in the evening to write the day — '
                                'mood, energy, stress. Skipped once the day '
                                'already has a rating in it',
                        value: prefs.checkInEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            checkInEnabled: !prefs.checkInEnabled))),
                    // A prompt to log, not a reading. The app measures no
                    // hydration and this row may never imply it does.
                    SetRow(LucideIcons.glassWater, C.teal,
                        l?.settingsWaterReminderRowTitle ?? 'Water reminder',
                        sub: l?.settingsWaterReminderRowSub ??
                            'A buzz on the strap and a notification on your '
                                'phone through your waking hours, to remind you to '
                                'log a drink. Nothing is measured either way',
                        value: prefs.waterEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(
                            prefs.copyWith(waterEnabled: !prefs.waterEnabled))),
                    // only while it's on — the group is dense enough, and an
                    // interval for a reminder nobody armed is furniture.
                    if (prefs.waterEnabled)
                      SetRow(LucideIcons.timer, C.teal,
                          l?.settingsRemindMeEveryRowTitle ??
                              'Remind me every',
                          value: _everyLabel(prefs.waterIntervalMin),
                          chevron: false,
                          onTap: () => set(prefs.copyWith(
                              waterIntervalMin:
                                  _nextEvery(prefs.waterIntervalMin)))),
                  ]),
                  if (relaySupported)
                    settingsGroup(c, l?.settingsGroupTheStrap ?? 'The strap', [
                      // The other direction: not what this app sends you, but
                      // what your phone's apps make the band do. The permission
                      // for it has been in the manifest all along with nothing
                      // in the app that could reach it.
                      SetRow(LucideIcons.bellRing, C.purple,
                          l?.settingsBuzzOnAppNotificationsRowTitle ??
                              'Buzz on app notifications',
                          sub: l?.settingsBuzzOnAppNotificationsRowSub ??
                              'Pick which phone apps make the strap buzz',
                          onTap: () => goto(c, const BandNotifications())),
                    ]),
                  settingsGroup(c, l?.settingsGroupQuietHours ?? 'Quiet hours', [
                    SetRow(LucideIcons.moon, C.indigo,
                        l?.settingsQuietHoursRowTitle ?? 'Quiet hours',
                        sub: l?.settingsQuietHoursRowSub ??
                            'Nothing buzzes inside this window',
                        value: prefs.quietEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(
                            prefs.copyWith(quietEnabled: !prefs.quietEnabled))),
                    SetRow(LucideIcons.sunset, C.blue,
                        l?.settingsQuietHoursStartsRowTitle ?? 'Starts',
                        value: _hhmm(prefs.quietStartMin),
                        chevron: false,
                        onTap: () async {
                          final v = await _pickMinute(c, prefs.quietStartMin);
                          if (v != null) set(prefs.copyWith(quietStartMin: v));
                        }),
                    SetRow(LucideIcons.sunrise, C.yellow,
                        l?.settingsQuietHoursEndsRowTitle ?? 'Ends',
                        value: _hhmm(prefs.quietEndMin),
                        chevron: false,
                        onTap: () async {
                          final v = await _pickMinute(c, prefs.quietEndMin);
                          if (v != null) set(prefs.copyWith(quietEndMin: v));
                        }),
                    SetRow(LucideIcons.triangleAlert, C.red,
                        l?.settingsHealthExceptionsBreakThroughRowTitle ??
                            'Health exceptions break through',
                        value: prefs.criticalOverridesQuiet ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            criticalOverridesQuiet:
                                !prefs.criticalOverridesQuiet))),
                  ]),
                ],
                const SizedBox(height: S.x3),
                StatusCard(
                  l?.settingsAlarmNotOnListTitle ??
                      'The alarm is not on this list',
                  l?.settingsAlarmNotOnListBody ??
                      'Cancel it on the Alarm screen instead.',
                  icon: LucideIcons.alarmClock,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// The water intervals on offer, all inside
  /// [NotificationPrefs.waterIntervalMinAllowed]..[NotificationPrefs.waterIntervalMaxAllowed].
  /// None of them is "recommended" — we have no basis for one.
  static const waterEvery = [
    (30, '30m'),
    (60, '1h'),
    (90, '90m'),
    (120, '2h'),
    (180, '3h'),
    (240, '4h'),
  ];

  static String _everyLabel(int min) =>
      waterEvery.firstWhere((e) => e.$1 == min, orElse: () => (min, '${min}m'))
          .$2;

  /// Tapped through in place, like Units and Appearance. An unknown stored
  /// value (an older build, a hand-edited pref) lands on the first choice.
  static int _nextEvery(int min) {
    final i = waterEvery.indexWhere((e) => e.$1 == min);
    return waterEvery[(i + 1) % waterEvery.length].$1;
  }

  /// Low-battery alert thresholds, tapped through in place like [waterEvery].
  /// Bounds match NotificationPrefs.batteryPctMin/Max, so every choice here is
  /// one the pref will store unclamped.
  static const batteryChoices = [10, 15, 20, 25, 30, 40];

  static int _nextBatteryPct(int pct) {
    final i = batteryChoices.indexOf(pct);
    return batteryChoices[(i + 1) % batteryChoices.length];
  }

  static String _hhmm(int minuteOfDay) {
    final m = minuteOfDay % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  static Future<int?> _pickMinute(BuildContext c, int current) async {
    final picked = await showTimePicker(
      context: c,
      initialTime: TimeOfDay(hour: (current ~/ 60) % 24, minute: current % 60),
    );
    return picked == null ? null : picked.hour * 60 + picked.minute;
  }
}

// ══════════════════ EDIT PROFILE ══════════════════

class EditProfile extends StatelessWidget {
  const EditProfile({super.key});

  @override
  Widget build(BuildContext c) {
    final app = c.read<AppState>();
    return EditProfileView(
      initial: app.user ?? const {},
      // The app SHOWED lb and EDITED kg: Health converted on the way out, this
      // form did not convert on the way in, so typing back the 172 lb the app
      // had just printed stored 172 kg.
      units: c.watch<UnitsController>(),
      // The read lives on the form it fills. It used to be three taps away on
      // a settings screen, which is a long way to go to keep a weight current
      // — and the weight is the one the calorie and BMR estimates read.
      //
      // The merge policy (weight and height win, age and sex only fill a gap)
      // stays in `mergeHealthProfile` and is not re-decided here. The fields
      // come back so the form shows what arrived rather than claiming it.
      onImport: () async {
        final importer = HealthProfileImporter();
        final l = AppLocalizations.of(c);
        // Asked HERE, on the tap, and for these four types only. Nothing at
        // launch and nothing in onboarding: a permission sheet for data the
        // user has not asked us to read is how the whole set gets denied at
        // once.
        if (!await importer.requestPermission()) {
          return (
            l?.settingsImportNoPermission(storeName) ??
                '$storeName did not grant those fields. Nothing was read.',
            true,
            null,
          );
        }
        final snap = await importer.read();
        if (snap.isEmpty) {
          return (
            isAppleHealth
                ? (l?.settingsImportEmptyWithBirthday(storeName) ??
                    'Nothing came back. $storeName holds no height, weight, '
                        'birthday or sex for you — type them in here instead.')
                : (l?.settingsImportEmpty(storeName) ??
                    'Nothing came back. $storeName holds no height, weight'
                        ' or sex for you — type them in here instead.'),
            false,
            null,
          );
        }
        await markImported(HealthImport.profile);
        if (!c.mounted) return ('', false, null);
        final app = c.read<AppState>();
        final changes = healthProfileChanges(app.user, snap);
        final merged = mergeHealthProfile(app.user, snap);
        // Nothing to write is not a write of the same thing: `updateProfile`
        // notifies every listener and re-scores the day.
        if (changes.isEmpty) {
          return (
            l?.settingsImportNoChange(snap.found.join(', ')) ??
                'Read ${snap.found.join(', ')}. Your profile already says the '
                    'same thing, so nothing changed.',
            false,
            merged,
          );
        }
        await app.updateProfile(merged);
        return (
          l?.settingsImportUpdated(changes.join(', '), storeName) ??
              'Updated ${changes.join(', ')} from $storeName.',
          false,
          merged
        );
      },
      onSave: (fields) async {
        // A field the user CLEARED must be removed, not merged over — the
        // profile map is a merge, so writing only what is present would keep
        // a stale value alive and score the day against a body that is no
        // longer described.
        await app.updateProfile({
          for (final k in const [
            'name',
            'sex',
            'age',
            'height_cm',
            'weight_kg',
          ])
            k: fields[k],
        });
        if (c.mounted) Navigator.of(c).maybePop();
      },
    );
  }
}

class EditProfileView extends StatefulWidget {
  final Map<String, dynamic> initial;
  final Future<void> Function(Map<String, dynamic> fields) onSave;

  /// Display units for the height and weight fields. Null is metric, which is
  /// also what the storage is — the conversion only exists for imperial.
  final UnitsController? units;

  /// Read these fields from the phone's health store.
  ///
  /// Returns the line to show, whether it failed, and the profile as it now
  /// stands so the form can display what arrived. Null means no button — the
  /// gallery and the golden sweep get the form without a control that would
  /// raise a real health-store prompt from a screenshot.
  final Future<(String note, bool failed, Map<String, dynamic>? fields)>
          Function()?
      onImport;

  const EditProfileView(
      {super.key,
      required this.onSave,
      this.initial = const {},
      this.units,
      this.onImport});

  @override
  State<EditProfileView> createState() => _EditProfileViewState();
}

class _EditProfileViewState extends State<EditProfileView> {
  late final UnitsController _u =
      widget.units ?? UnitsController.seed(UnitSystem.metric);
  late final _name =
      TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final _age =
      TextEditingController(text: _s(widget.initial['age']));
  late final _height =
      TextEditingController(text: _u.heightField(widget.initial['height_cm'] as num?));
  late final _weight =
      TextEditingController(text: _u.weightField(widget.initial['weight_kg'] as num?));
  late String? _sex = (widget.initial['sex'] as String?)?.toLowerCase();

  /// When the store last gave us something. Null is "never", which is also
  /// what an unreadable preference reads as — the first-run word on the button
  /// is the safe one either way.
  DateTime? _lastImport;
  bool _importing = false;
  String? _importNote;
  bool _importFailed = false;

  static String _s(Object? v) => v == null ? '' : '$v';

  @override
  void initState() {
    super.initState();
    if (widget.onImport == null) return;
    lastImportAt(HealthImport.profile).then((at) {
      if (mounted) setState(() => _lastImport = at);
    });
  }

  /// Read, then show what arrived in the fields it fills.
  ///
  /// The controllers are rewritten rather than the screen rebuilt from
  /// `AppState`: this form owns its text while it is open, and a value that
  /// changed underneath it without the field moving is a value the user never
  /// sees.
  Future<void> _import() async {
    final job = widget.onImport;
    if (job == null || _importing) return;
    setState(() {
      _importing = true;
      _importNote = null;
    });
    try {
      final (note, failed, fields) = await job();
      if (!mounted) return;
      if (fields != null) {
        _age.text = _s(fields['age']);
        _height.text = _u.heightField(fields['height_cm'] as num?);
        _weight.text = _u.weightField(fields['weight_kg'] as num?);
        _sex = (fields['sex'] as String?)?.toLowerCase() ?? _sex;
      }
      setState(() {
        _importNote = note;
        _importFailed = failed;
        if (!failed && fields != null) _lastImport = DateTime.now();
      });
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        setState(() {
          _importNote = l?.settingsImportFailed('$e') ?? 'Failed: $e';
          _importFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  /// A field that cannot be read is NOT a cleared field.
  ///
  /// Every key here is written unconditionally, precisely so a cleared one is
  /// removed rather than merged over — which meant a typo ("78 kg", "78,5")
  /// parsed to null and wiped the stored weight while the screen popped as if
  /// it had saved. Blank still clears; a typo now stops the save and says so.
  void _save() {
    final l = AppLocalizations.of(context);
    final age = Typed.of(_age.text);
    final height = Typed.of(_height.text);
    final weight = Typed.of(_weight.text);
    final bad = [
      if (age.bad) (l?.settingsAgeFieldLabel ?? 'Age'),
      if (height.bad) _u.heightLabel,
      if (weight.bad) _u.weightLabel,
    ];
    if (bad.isNotEmpty) {
      sayUnreadable(context, bad);
      return;
    }
    widget.onSave({
      'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
      'sex': _sex,
      'age': age.value?.round(),
      // Typed in the units on the label, stored in metric.
      'height_cm': height.value == null ? null : _u.heightToCm(_height.text),
      'weight_kg': weight.value == null ? null : _u.weightToKg(_weight.text),
    });
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsEditProfileNavTitle ?? 'Edit profile',
                trailing: Pressable(
                  semanticLabel: l?.actionSave ?? 'Save',
                  onTap: _save,
                  child: Text(l?.actionSave ?? 'Save',
                      style: F.body.copyWith(
                          color: p.on(C.green), fontWeight: FontWeight.w600)),
                )),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                _text(c, _name, l?.settingsNameFieldLabel ?? 'NAME',
                    TextInputType.name),
                const SizedBox(height: S.x4),
                Text(l?.settingsSexFieldLabel ?? 'SEX',
                    style: F.over.copyWith(color: p.ink3)),
                const SizedBox(height: S.x2),
                Wrap(spacing: S.x2, runSpacing: S.x2, children: [
                  for (final (key, label) in [
                    ('m', l?.settingsSexMale ?? 'Male'),
                    ('f', l?.settingsSexFemale ?? 'Female'),
                    ('other', l?.settingsSexPreferNotToSay ?? 'Prefer not to say'),
                  ])
                    Pressable(
                      onTap: () => setState(() => _sex = key),
                      semanticLabel: label,
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                            horizontal: S.x4, vertical: S.x2),
                        decoration: BoxDecoration(
                          color: _sex == key ? p.wash(C.green) : p.card,
                          borderRadius: R.rPill,
                          border: Border.all(
                              color: _sex == key ? p.on(C.green) : p.line),
                        ),
                        child: Text(label,
                            style: F.cap.copyWith(
                                color: _sex == key ? p.on(C.green) : p.ink2)),
                      ),
                    ),
                ]),
                const SizedBox(height: S.x4),
                _text(c, _age, l?.settingsAgeYearsFieldLabel ?? 'AGE (YEARS)',
                    TextInputType.number),
                const SizedBox(height: S.x4),
                _text(c, _height, _u.heightLabel.toUpperCase(),
                    TextInputType.number),
                const SizedBox(height: S.x4),
                _text(c, _weight, _u.weightLabel.toUpperCase(),
                    TextInputType.number),
                ..._importBlock(p, c),
                const SizedBox(height: S.x6),
                StatusCard(
                  l?.settingsFourFieldsTitle ?? 'These four change your numbers',
                  l?.settingsFourFieldsBody ??
                      'They feed heart-rate zones, calorie estimates and training '
                          'load. Clear one and only the metrics that need it stay '
                          'unavailable.',
                  icon: LucideIcons.info,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// The health-store read, on the form it fills. Empty when the caller passed
  /// no [EditProfileView.onImport] — the gallery and the golden sweep must not
  /// carry a control that raises a real permission sheet.
  List<Widget> _importBlock(P p, BuildContext c) {
    if (widget.onImport == null) return const [];
    final l = AppLocalizations.of(c);
    return [
      const SizedBox(height: S.x6),
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            isAppleHealth
                ? (l?.settingsImportBlockAppleHealth(storeName) ??
                    'Height, weight, birthday and sex, straight out of '
                        '$storeName. Height and weight are taken every time; your '
                        'age and sex only fill a gap, because neither drifts and a '
                        'value already here was your choice.')
                : (l?.settingsImportBlockOther(storeName) ??
                    'Height and weight, straight out of $storeName. It has no '
                        'birthday and no sex to read — no app can — so set those '
                        'two above yourself.'),
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
          const SizedBox(height: S.x4),
          BigButton(
            importLabel(_lastImport),
            icon: LucideIcons.scale,
            color: C.purple,
            soft: true,
            onTap: _importing ? null : _import,
          ),
          if (_importNote != null && _importNote!.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            Text(
              _importNote!,
              style: F.cap.copyWith(
                  color: _importFailed ? p.on(C.red) : p.ink2, height: 1.5),
            ),
          ],
        ]),
      ),
    ];
  }

  Widget _text(BuildContext c, TextEditingController ctl, String label,
      TextInputType kind) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: F.over.copyWith(color: p.ink3)),
      TextField(
        controller: ctl,
        keyboardType: kind,
        style: F.head.copyWith(color: p.ink),
        decoration: InputDecoration(
          hintText: l?.settingsNotSetHint ?? 'Not set',
          hintStyle: F.head.copyWith(color: p.ink3),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: S.x3),
          enabledBorder:
              UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
          focusedBorder:
              UnderlineInputBorder(borderSide: BorderSide(color: p.on(C.green))),
        ),
      ),
    ]);
  }
}

// ══════════════════ AUTOMATION ══════════════════
//
// THE TWO PLATFORMS ARE NOT SYMMETRIC AND THIS SCREEN SAYS SO.
//
// Android gets real outbound event triggers: the app broadcasts an intent an
// automation app can start a profile on. iOS does NOT — there is no public
// mechanism for a Shortcuts personal automation to trigger on an arbitrary
// app-donated intent; that trigger list is a fixed system set, and
// `donate`/INInteraction buys Siri suggestions and discoverability, not an
// event trigger. So the iOS half of this screen names what iOS can do (invoke
// the app) and what it cannot (be invoked by it), rather than describing the
// Android feature in language vague enough to read as parity.
//
// And nothing that leaves here is a measurement. A Shortcut that receives
// `readiness=0` has recreated the fabricated-number problem outside the app,
// where there is no tier and no note to explain it — so the one event that
// ships carries facts about the SYNC and no metric at all.

class AutomationSettings extends StatefulWidget {
  const AutomationSettings({super.key});

  @override
  State<AutomationSettings> createState() => _AutomationSettingsState();
}

class _AutomationSettingsState extends State<AutomationSettings> {
  String? _token;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    TaskerBridge.authToken().then((t) {
      if (mounted) setState(() => _token = t);
    });
  }

  Future<void> _copy() async {
    final t = _token;
    if (t == null) return;
    await Clipboard.setData(ClipboardData(text: t));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final android = defaultTargetPlatform == TargetPlatform.android;
    final token = _token;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsAutomationNavTitle ?? 'Automation'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Section(
                  l?.settingsSyncFinishesSectionTitle ??
                      'When a sync finishes',
                  Surface(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            android
                                ? (l?.settingsSyncFinishesAndroidBody ??
                                    'The app broadcasts an intent your automation '
                                        'app can start a profile on. Filter on the '
                                        'action below; it carries how many records '
                                        'landed and when, at most one a minute.')
                                : (l?.settingsSyncFinishesIosBody ??
                                    'iOS cannot do this. A Shortcuts personal '
                                        'automation can only trigger on Apple’s '
                                        'own fixed list of events, and no app can '
                                        'add one — so nothing here can start a '
                                        'shortcut for you. Android gets it; this '
                                        'is a platform limit, not a setting.'),
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                          if (android) ...[
                            const SizedBox(height: S.x3),
                            SelectableText(
                              'wtf.openstrap.openstrap_edge.SYNC_COMPLETE',
                              style: F.cap.copyWith(color: p.ink),
                            ),
                            const SizedBox(height: S.x1),
                            Text(
                                l?.settingsSyncFinishesExtras ??
                                    'Extras: records (int), at (unix seconds)',
                                style: F.over.copyWith(color: p.ink3)),
                          ],
                        ]),
                  ),
                ),
                const SizedBox(height: S.x5),
                Section(
                  l?.settingsNeverSendSectionTitle ?? 'What it will never send',
                  Surface(
                    child: Text(
                      l?.settingsNeverSendBody ??
                          'No readiness, no strain, no sleep score — on either '
                              'platform. A number this app would have shown as absent, '
                              'with a reason attached, becomes a bare zero the moment '
                              'it leaves. Facts about the sync go out; measurements do '
                              'not.',
                      style: F.body,
                    ),
                  ),
                ),
                const SizedBox(height: S.x5),
                Section(
                  l?.settingsBuzzFromShortcutSectionTitle ??
                      'Buzzing the band from a shortcut',
                  Surface(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            android
                                ? (l?.settingsBuzzFromShortcutAndroidBody ??
                                    'Send '
                                        'wtf.openstrap.openstrap_edge.BUZZ_STRAP '
                                        'with this token as the “token” string '
                                        'extra. Without it any app on the phone '
                                        'could buzz your band.')
                                : (l?.settingsBuzzFromShortcutIosBody ??
                                    'This direction works on iOS: a shortcut you '
                                        'run yourself can reach the app. What it '
                                        'cannot do is run itself when the band '
                                        'syncs.'),
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                          if (android) ...[
                            const SizedBox(height: S.x4),
                            if (token == null)
                              Text(
                                  l?.settingsNoTokenYet ??
                                      'No token yet — reopen this screen.',
                                  style: F.cap.copyWith(color: p.ink3))
                            else ...[
                              SelectableText(token,
                                  style: F.cap.copyWith(color: p.ink)),
                              const SizedBox(height: S.x3),
                              BigButton(
                                  _copied
                                      ? (l?.settingsCopied ?? 'Copied')
                                      : (l?.settingsCopyTheToken ??
                                          'Copy the token'),
                                  icon: _copied
                                      ? LucideIcons.check
                                      : LucideIcons.copy,
                                  color: C.indigo,
                                  soft: true,
                                  onTap: _copy),
                            ],
                          ],
                        ]),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
