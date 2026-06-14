// Widget bridge — writes a small snapshot of today's metrics into the shared App
// Group so the iOS WidgetKit extension (and Android widget) can render them with
// no network. Called whenever the app loads /today or finishes a sync. The widget
// process reads these keys; it never runs Dart.
//
// The App Group id MUST match the one set in Xcode (Runner + widget targets) and
// in the Swift suite name. See WIDGET_SETUP.md.

import 'package:home_widget/home_widget.dart';

import '../models/payloads.dart';

class WidgetService {
  /// App Group id — keep in sync with Xcode entitlements + the Swift suite name.
  static const String appGroupId = 'group.wtf.openstrap';

  /// WidgetKit "kind" (Swift) / Android provider class name.
  static const String _iOSName = 'OpenStrapWidget';
  static const String _androidName = 'OpenStrapWidgetProvider';

  static bool _inited = false;
  static Future<void> init() async {
    if (_inited) return;
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      _inited = true;
    } catch (_) {/* platform without widgets — ignore */}
  }

  /// Push the latest snapshot and trigger a widget reload. Best-effort; never
  /// throws into the caller. Sentinels: ints use -1 / strings use '' for "no data".
  static Future<void> push(TodayData t) async {
    try {
      await init();
      final hrv = t.hrv;
      final s = t.strain;
      final sleep = t.sleepDuration;
      final need = t.sleepNeed;
      final rhr = t.restingHr;

      Future<void> setI(String k, int v) => HomeWidget.saveWidgetData<int>(k, v);

      await HomeWidget.saveWidgetData<bool>('has_data', !t.isEmpty);
      // Headline composite Readiness + the three rings (Strain · Sleep · HRV).
      await setI('readiness', t.readiness.isEmpty ? -1 : t.readiness.value!.round());
      await setI('hrv', hrv == null ? -1 : hrv.rmssd.round());
      await setI('hrv_baseline', hrv?.baseline == null ? -1 : hrv!.baseline!.round());
      await HomeWidget.saveWidgetData<double>(
          'strain', s.isEmpty ? -1.0 : s.value!.toDouble());
      await setI('sleep_min', sleep.isEmpty ? -1 : sleep.value!.round());
      await setI('sleep_need_min', need.isEmpty ? 480 : need.value!.round());
      await setI('rhr', rhr.isEmpty ? -1 : rhr.value!.round());
      await HomeWidget.saveWidgetData<String>('coach_line', _coachLine(t.coach));
      await HomeWidget.saveWidgetData<String>('stress_band',
          t.stress?.band ?? '');
      await setI('updated_at', DateTime.now().millisecondsSinceEpoch ~/ 1000);

      await HomeWidget.updateWidget(iOSName: _iOSName, androidName: _androidName);
    } catch (_) {/* widgets unavailable / not configured yet — ignore */}
  }

  /// Store the backend URL + access JWT so the widget can self-refresh /today
  /// (~hourly) even when the app is closed. Call alongside push() when signed in.
  static Future<void> saveAuth(String url, String? jwt) async {
    try {
      await init();
      await HomeWidget.saveWidgetData<String>('backend_url', url);
      await HomeWidget.saveWidgetData<String>('access_jwt', jwt ?? '');
    } catch (_) {}
  }

  /// True once (and clears) if the Live Activity's Finish button was tapped.
  /// The App Intent sets `end_session` in the App Group; we consume it on resume.
  static Future<bool> consumeEndSessionFlag() async {
    try {
      await init();
      final v = await HomeWidget.getWidgetData<bool>('end_session', defaultValue: false);
      if (v == true) {
        await HomeWidget.saveWidgetData<bool>('end_session', false);
        return true;
      }
    } catch (_) {}
    return false;
  }

  static String _coachLine(CoachData? c) {
    if (c == null) return '';
    if (c.plan.isNotEmpty) return c.plan.first.title;
    final tgt = c.strainTarget;
    if (tgt != null) return 'Aim for strain ${tgt.value.toStringAsFixed(0)}';
    return c.summary;
  }
}
