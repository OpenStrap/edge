// notification_service.dart — the ONE place OS-level notifications are presented.
//
// It is source-agnostic: device alerts (battery/charging), derive-driven insights
// (illness, recovery), and scheduled nudges (wind-down, weekly recap, move) all
// flow through here. NotificationCenter decides *whether* to fire; this class is
// purely the OS presentation + scheduling layer.
//
// Design guarantees:
//   • One channel per category (NotifCategory) so Android users mute each kind
//     independently. The `health` channel is max-importance (illness alerts).
//   • Notification ids are partitioned by NotificationEvent.osId; fixed device +
//     scheduled-reminder ids live in disjoint low bands (< 3000).
//   • One init, one permission prompt.
//   • Local + scheduled only — NO FCM/APNs (this app is cloud-free by design).
//     `kServerIdBase` stays reserved-but-unused for any future push layer.
//
// Tap routing: a tapped notification's payload (a deep-link route) is pushed onto
// [taps]; AppState listens and navigates.

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notification_event.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;
  bool? _granted;

  /// Deep-link routes from tapped notifications. AppState listens & navigates.
  final StreamController<String> _taps = StreamController<String>.broadcast();
  Stream<String> get taps => _taps.stream;

  // ── Channels (one per category — keep them disjoint) ────────────────────────
  static const AndroidNotificationChannel _deviceChannel =
      AndroidNotificationChannel(
    'device_alerts',
    'Device alerts',
    description: 'Band battery and charging',
    importance: Importance.high,
  );
  static const AndroidNotificationChannel _healthChannel =
      AndroidNotificationChannel(
    'health',
    'Health alerts',
    description: 'Illness, unusual physiology and temperature signals',
    importance: Importance.max,
  );
  static const AndroidNotificationChannel _recoveryChannel =
      AndroidNotificationChannel(
    'recovery',
    'Recovery',
    description: 'Daily recovery readiness from your own data',
    importance: Importance.defaultImportance,
  );
  static const AndroidNotificationChannel _remindersChannel =
      AndroidNotificationChannel(
    'reminders',
    'Reminders',
    description: 'Wind-down, movement nudges, goals and weekly recaps',
    importance: Importance.defaultImportance,
  );

  // ── Fixed ids: device alerts + scheduled reminders (disjoint low band) ───────
  static const int idLowBattery = 1001;
  static const int idCharging = 1002;
  static const int idWindDown = 2002; // scheduled daily ("time to sleep")
  static const int idWeeklyRecap = 2003; // scheduled weekly
  static const int idJournalLog = 2004; // scheduled daily ("log your day")
  static const int idMorningBrief = 2005; // scheduled daily (AI morning briefing)
  static const int idEveningBrief = 2006; // scheduled daily (AI evening recap)

  /// Hydration reminders occupy a contiguous slot band [idWaterBase ..
  /// idWaterBase + maxWaterSlots) — one daily-repeating slot per fire time across
  /// the waking window. Still inside the disjoint <3000 scheduled-reminder band.
  static const int idWaterBase = 2100;
  static const int maxWaterSlots = 24;

  /// Reserved for a future server/push layer (unused — app is cloud-free).
  static const int kServerIdBase = 2000;

  AndroidNotificationChannel _channelFor(NotifCategory c) => switch (c) {
        NotifCategory.health => _healthChannel,
        NotifCategory.recovery => _recoveryChannel,
        NotifCategory.reminders => _remindersChannel,
        NotifCategory.device => _deviceChannel,
      };

  Importance _importanceFor(NotifCategory c) =>
      c == NotifCategory.health ? Importance.max : Importance.defaultImportance;
  Priority _priorityFor(NotifCategory c) =>
      c == NotifCategory.health ? Priority.max : Priority.defaultPriority;

  /// Set up the plugin, channels, timezone db and the tap handler. Idempotent.
  /// Does NOT prompt for permission.
  Future<void> init() async {
    if (_inited) return;
    try {
      tzdata.initializeTimeZones();
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {/* tz stays UTC; scheduling still works, just in UTC wall-clock */}

    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/launcher_icon');
    const DarwinInitializationSettings darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: _onTap,
    );
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_deviceChannel);
    await androidImpl?.createNotificationChannel(_healthChannel);
    await androidImpl?.createNotificationChannel(_recoveryChannel);
    await androidImpl?.createNotificationChannel(_remindersChannel);
    _inited = true;
  }

  void _onTap(NotificationResponse r) {
    final route = r.payload;
    if (route != null && route.isNotEmpty) _taps.add(route);
  }

  /// If the app was launched by tapping a notification, replay its route once.
  Future<void> consumeLaunchRoute() async {
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d?.didNotificationLaunchApp ?? false) {
        final route = d?.notificationResponse?.payload;
        if (route != null && route.isNotEmpty) _taps.add(route);
      }
    } catch (_) {}
  }

  /// Request notification permission once (iOS always; Android 13+). Cached.
  ///
  /// [allowPrompt] gates whether this may show the OS's interactive
  /// authorization dialog. Apple's notification docs ("Asking permission to
  /// use notifications") document that authorization should be requested in
  /// CONTEXT — the interactive prompt assumes an active foreground scene to
  /// present from — never automatically, and never from a background
  /// execution context (a headless BGTaskScheduler/BGAppRefreshTask run or a
  /// Dart background isolate has no such scene). Callers that know they're
  /// running headless (see background_sync.dart's checkSyncStaleness) must
  /// pass `allowPrompt: false`; every foreground/contextual caller keeps the
  /// default `true`. With `false` and no prior decision cached, this checks
  /// (never requests) via `checkPermissions()` and fails closed to `false`
  /// rather than attempting to prompt — matching the "in-app feed is ALWAYS
  /// written, OS presentation is best-effort" contract in NotificationCenter.
  Future<bool> ensurePermission({bool allowPrompt = true}) async {
    await init();
    if (_granted != null) return _granted!;
    if (!allowPrompt) return hasPermission();

    bool granted = true;
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      granted =
          await ios.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      granted = await android.requestNotificationsPermission() ?? false;
    }
    _granted = granted;
    return granted;
  }

  /// Non-mutating: whether notifications are currently enabled, WITHOUT ever
  /// showing the OS authorization prompt. Safe to call from any context,
  /// including headless/background. Does not populate [_granted] — a
  /// not-yet-decided status here shouldn't get permanently cached as
  /// "denied" just because a background check happened to run first.
  Future<bool> hasPermission() async {
    try {
      await init();
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return (await ios.checkPermissions())?.isEnabled ?? false;
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return await android.areNotificationsEnabled() ?? false;
      }
      return true; // other platforms (macOS/Linux) — no gating here
    } catch (_) {
      return false;
    }
  }

  NotificationDetails _details(NotifCategory c) {
    final ch = _channelFor(c);
    return NotificationDetails(
      android: AndroidNotificationDetails(
        ch.id,
        ch.name,
        channelDescription: ch.description,
        importance: _importanceFor(c),
        priority: _priorityFor(c),
        icon: '@mipmap/launcher_icon',
      ),
      iOS: const DarwinNotificationDetails(),
    );
  }

  /// Present a NotificationEvent on its category channel. Same osId replaces, so
  /// re-firing the same logical event never stacks duplicates. Never throws.
  ///
  /// [allowPermissionPrompt] — see [ensurePermission]'s doc. Pass `false` from
  /// any caller that knows it's running headless/in the background.
  Future<void> presentEvent(
    NotificationEvent e, {
    bool allowPermissionPrompt = true,
  }) async {
    try {
      if (!await ensurePermission(allowPrompt: allowPermissionPrompt)) return;
      await _plugin.show(
        e.osId,
        e.title,
        e.body,
        _details(e.category),
        payload: e.route,
      );
    } catch (_) {/* best-effort */}
  }

  /// Legacy device-alert entry (battery/charging). Kept for device_alerts.dart.
  Future<void> showDevice({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      if (!await ensurePermission()) return;
      await _plugin.show(id, title, body, _details(NotifCategory.device));
    } catch (_) {}
  }

  // ── Scheduling (wall-clock recurring nudges) ────────────────────────────────

  tz.TZDateTime _nextInstanceOf(int hour, int minute, {int? weekday}) {
    final now = tz.TZDateTime.now(tz.local);
    var d = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (weekday != null) {
      while (d.weekday != weekday) {
        d = d.add(const Duration(days: 1));
      }
    }
    if (!d.isAfter(now)) {
      d = d.add(Duration(days: weekday != null ? 7 : 1));
    }
    return d;
  }

  Future<void> scheduleDaily({
    required int id,
    required NotifCategory category,
    required String title,
    required String body,
    required int hour,
    required int minute,
    String? route,
    bool skipToday = false,
  }) async {
    try {
      if (!await ensurePermission()) return;
      var when = _nextInstanceOf(hour, minute);
      // skipToday: tonight's instance is already handled (e.g. the journal was
      // logged before the prompt time) — start the daily repeat tomorrow.
      if (skipToday) {
        final now = tz.TZDateTime.now(tz.local);
        if (when.year == now.year &&
            when.month == now.month &&
            when.day == now.day) {
          when = when.add(const Duration(days: 1));
        }
      }
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        _details(category),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: route,
      );
    } catch (_) {}
  }

  Future<void> scheduleWeekly({
    required int id,
    required NotifCategory category,
    required String title,
    required String body,
    required int weekday, // DateTime.monday..sunday
    required int hour,
    required int minute,
    String? route,
  }) async {
    try {
      if (!await ensurePermission()) return;
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _nextInstanceOf(hour, minute, weekday: weekday),
        _details(category),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: route,
      );
    } catch (_) {}
  }

  Future<void> cancel(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }
}
