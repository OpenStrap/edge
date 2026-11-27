import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../gps/gps_source.dart';
import '../../integrations/calendar.dart';
import '../../integrations/hue.dart';
import '../../integrations/intervals_icu.dart';
import '../../integrations/weather.dart';
import '../../l10n/display_text.dart';
import '../screens/coach.dart' show CoachSetup, coachSubtitle;
import '../ui2.dart';
import 'profile.dart' show SetRow, settingsGroup, goto;

/// Everything OpenStrap connects to, in one list. Each row says whether it is
/// on and what it does; nothing here is on until the user turns it on.
class ConnectedApps extends StatefulWidget {
  const ConnectedApps({super.key});
  @override
  State<ConnectedApps> createState() => _ConnectedAppsState();
}

class _ConnectedAppsState extends State<ConnectedApps> {
  final _intervals = IntervalsIcu.instance;
  bool _weather = false, _calendar = false, _busy = false;
  HueBridge? _hue;
  String? _hueRoomName;

  @override
  void initState() {
    super.initState();
    _intervals.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    _intervals.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await Future.wait([_intervals.load()]);
    final w = await weatherEnabled(), cal = await calendarEnabled();
    final hue = await HueBridge.load();
    String? roomName;
    final room = await hueRoom();
    if (hue != null && room != null) {
      try {
        roomName = (await hue.rooms()).where((r) => r.id == room).firstOrNull?.name;
      } catch (_) {} // bridge unreachable right now: the row still shows linked
    }
    if (!mounted) return;
    setState(() {
      _weather = w;
      _calendar = cal;
      _hue = hue;
      _hueRoomName = roomName;
    });
  }

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(uiText(context, msg))));
  }

  /// One wrapper for every action on this screen: a spinner-free busy guard
  /// and the failure said in the exception's own words.
  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // The redirect lands on a loopback listener in this app, so the page must
  // open in an in-app browser (see oauth_loopback.dart).
  Future<bool> _open(Uri u) => launchUrl(u, mode: LaunchMode.inAppBrowserView);
  Future<void> _closeBrowser() async {
    try {
      if (await supportsCloseForLaunchMode(LaunchMode.inAppBrowserView)) {
        await closeInAppWebView();
      }
    } catch (_) {}
  }

  // ── intervals.icu ─────────────────────────────────────────────────────────
  Future<void> _tapIntervals() => _run(() async {
        if (_intervals.authFailed) await _intervals.signOut();
        if (!mounted) return;
        if (_intervals.signedIn) {
          final choice = await showModalBottomSheet<String>(
            context: context,
            builder: (s) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    leading: const Icon(LucideIcons.upload),
                    title: Text(uiText(s, 'Send the last 7 days now')),
                    onTap: () => Navigator.pop(s, 'push')),
                ListTile(
                    leading: Icon(_intervals.autoPush ? LucideIcons.pause : LucideIcons.play),
                    title: Text(uiText(s, _intervals.autoPush ? 'Stop sending automatically' : 'Send automatically')),
                    onTap: () => Navigator.pop(s, 'auto')),
                ListTile(
                    leading: const Icon(LucideIcons.unlink),
                    title: Text(uiText(s, 'Disconnect')),
                    onTap: () => Navigator.pop(s, 'out')),
              ]),
            ),
          );
          if (choice == 'push') {
            final n = await _intervals.pushRecent();
            _say(n == 0 ? 'Nothing to send yet.' : 'Sent $n days to intervals.icu.');
          } else if (choice == 'auto') {
            await _intervals.setAutoPush(!_intervals.autoPush);
          } else if (choice == 'out') {
            await _intervals.signOut();
          }
          return;
        }
        if (_intervals.oauthAvailable) {
          try {
            await _intervals.signIn(_open);
          } finally {
            await _closeBrowser();
          }
        } else {
          final creds = await _apiKeyDialog();
          if (creds == null) return;
          await _intervals.saveApiKey(creds.$1, creds.$2);
        }
        final n = await _intervals.pushRecent();
        _say('intervals.icu connected. Sent $n days.');
      });

  Future<(String, String)?> _apiKeyDialog() {
    final id = TextEditingController(), key = TextEditingController();
    return showDialog<(String, String)>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(uiText(d, 'Connect intervals.icu')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(uiText(d, 'On intervals.icu open Settings, then Developer Settings, and copy your athlete ID and API key.'),
              style: F.cap),
          TextField(controller: id, decoration: InputDecoration(labelText: uiText(d, 'Athlete ID'))),
          TextField(
              controller: key,
              obscureText: true,
              decoration: InputDecoration(labelText: uiText(d, 'API key'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(uiText(d, 'Cancel'))),
          TextButton(
              onPressed: () => id.text.trim().isEmpty || key.text.trim().isEmpty
                  ? null
                  : Navigator.pop(d, (id.text.trim(), key.text.trim())),
              child: Text(uiText(d, 'Connect'))),
        ],
      ),
    );
  }

  // ── weather / calendar ────────────────────────────────────────────────────
  Future<void> _tapWeather() => _run(() async {
        if (!_weather && await GpsSource.ensurePermission() != GpsPermissionStatus.granted) {
          _say('Weather needs location access. Allow it in the phone settings.');
          return;
        }
        await setWeatherEnabled(!_weather);
        setState(() => _weather = !_weather);
      });

  Future<void> _tapCalendar() => _run(() async {
        if (!await setCalendarEnabled(!_calendar)) {
          _say('Calendar access was refused. Allow it in the phone settings.');
          return;
        }
        setState(() => _calendar = !_calendar);
      });

  // ── Hue ───────────────────────────────────────────────────────────────────
  Future<void> _tapHue() => _run(() async {
        var hue = _hue;
        if (hue == null) {
          final ips = await HueBridge.discover().catchError((_) => <String>[]);
          final ip = ips.isNotEmpty ? ips.first : await _askIp();
          if (ip == null) return;
          if (!mounted) return;
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (d) => AlertDialog(
              title: Text(uiText(d, 'Press the button on your Hue bridge')),
              content: Text(uiText(d, 'The round button on top. Waiting up to 30 seconds.')),
            ),
          );
          try {
            hue = await HueBridge.link(ip);
          } finally {
            if (mounted) Navigator.of(context).pop();
          }
        }
        final rooms = await hue.rooms();
        if (!mounted) return;
        final pick = await showModalBottomSheet<String>(
          context: context,
          builder: (s) => SafeArea(
            child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(uiText(s, 'Which lights follow your sleep?'), style: F.over)),
              for (final r in rooms)
                ListTile(title: Text(r.name), onTap: () => Navigator.pop(s, r.id)),
              if (_hue != null)
                ListTile(
                    leading: const Icon(LucideIcons.unlink),
                    title: Text(uiText(s, 'Forget this bridge')),
                    onTap: () => Navigator.pop(s, '__forget')),
            ]),
          ),
        );
        if (pick == '__forget') {
          await hue.clearSchedules().catchError((_) {});
          await hue.forget();
          await setHueRoom(null);
          setState(() => _hue = _hueRoomName = null);
          return;
        }
        if (pick == null) {
          setState(() => _hue = hue);
          return;
        }
        await setHueRoom(pick);
        setState(() {
          _hue = hue;
          _hueRoomName = rooms.firstWhere((r) => r.id == pick).name;
        });
        _say('Set. Lights rise before your next alarm and dim at wind-down.');
      });

  Future<String?> _askIp() {
    final ip = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(uiText(d, 'No bridge found')),
        content: TextField(
            controller: ip,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: uiText(d, 'Bridge IP address'), hintText: '192.168.1.20')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(uiText(d, 'Cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(d, ip.text.trim().isEmpty ? null : ip.text.trim()),
              child: Text(uiText(d, 'Connect'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    String t(String s) => uiText(c, s);
    final on = t('On'), off = t('Off');
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(t('Connected apps')),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                settingsGroup(c, t('AI'), [
                  SetRow(LucideIcons.sparkles, C.purple, t('AI coach'),
                      sub: coachSubtitle(c) ?? t('Not set up'),
                      onTap: () => goto(c, const CoachSetup())),
                ]),
                settingsGroup(c, t('Training'), [
                  SetRow(LucideIcons.chartLine, C.blue, 'intervals.icu',
                      sub: _intervals.authFailed
                          ? t('Sign-in expired. Tap to reconnect.')
                          : _intervals.signedIn
                          ? t(_intervals.autoPush
                              ? 'Sends recovery, HRV, resting heart rate and sleep each day'
                              : 'Connected. Automatic sending is off.')
                          : t('Send recovery and sleep, upload workouts'),
                      value: _intervals.signedIn ? on : '',
                      onTap: _tapIntervals),
                ]),
                settingsGroup(c, t('Coach context'), [
                  SetRow(LucideIcons.cloudSun, C.teal, t('Weather and air'),
                      sub: t('Lets the coach check weather, air quality and pollen. $kWeatherAttribution'),
                      value: _weather ? on : off,
                      chevron: false,
                      onTap: _tapWeather),
                  SetRow(LucideIcons.calendar, C.indigo, t('Calendar'),
                      sub: t('Lets the coach read your calendar and add events you approve'),
                      value: _calendar ? on : off,
                      chevron: false,
                      onTap: _tapCalendar),
                ]),
                settingsGroup(c, t('Home'), [
                  SetRow(LucideIcons.lightbulb, C.yellow, 'Philips Hue',
                      sub: _hue == null
                          ? t('Sunrise before your alarm, dim lights at wind-down')
                          : _hueRoomName == null
                              ? t('Bridge linked. Pick a room.')
                              : t('$_hueRoomName follows your alarm and wind-down'),
                      value: _hue != null && _hueRoomName != null ? on : '',
                      onTap: _tapHue),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
