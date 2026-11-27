// The phone's own calendar (EventKit / CalendarContract), so the coach can
// weigh tomorrow's plans against tonight's recovery and add a block the user
// approves. No account: whatever calendars the phone already syncs. Event
// titles reach the coach's model only when this is switched on.

import 'dart:convert';

import 'package:device_calendar/device_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/notification_service.dart';

const _kOn = 'integration_calendar_on';

Future<bool> calendarEnabled() async =>
    (await SharedPreferences.getInstance()).getBool(_kOn) ?? false;

/// Turning it on asks for calendar access; false when the user refuses.
Future<bool> setCalendarEnabled(bool on) async {
  if (on) {
    final p = DeviceCalendarPlugin();
    final has = (await p.hasPermissions()).data ?? false;
    if (!has && !((await p.requestPermissions()).data ?? false)) return false;
  }
  await (await SharedPreferences.getInstance()).setBool(_kOn, on);
  return true;
}

/// One event as the coach sees it. All-day events carry dates only.
Map<String, Object?> calendarEventJson(Event e, String calendar) => {
      'title': e.title ?? '(no title)',
      'calendar': calendar,
      if (e.allDay ?? false) ...{
        'all_day': true,
        'date': e.start?.toIso8601String().substring(0, 10),
      } else ...{
        'start': e.start?.toLocal().toIso8601String(),
        'end': e.end?.toLocal().toIso8601String(),
      },
    };

/// Events from now until [daysAhead] days out, soonest first.
Future<String> calendarForCoach({int daysAhead = 2}) async {
  if (!await calendarEnabled()) {
    return 'Calendar is off. The user can turn it on in Profile > Connected apps.';
  }
  final p = DeviceCalendarPlugin();
  if (!((await p.hasPermissions()).data ?? false)) {
    return 'Calendar access was withdrawn in the phone settings.';
  }
  final now = DateTime.now();
  final end = DateTime(now.year, now.month, now.day).add(Duration(days: daysAhead.clamp(1, 14) + 1));
  final cals = (await p.retrieveCalendars()).data ?? const <Calendar>[];
  final out = <({DateTime at, Map<String, Object?> json})>[];
  for (final c in cals) {
    final evs = (await p.retrieveEvents(c.id, RetrieveEventsParams(startDate: now, endDate: end))).data;
    for (final e in evs ?? const <Event>[]) {
      out.add((at: e.start ?? now, json: calendarEventJson(e, c.name ?? '')));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return jsonEncode({'from': now.toIso8601String(), 'events': [for (final o in out) o.json]});
}

/// Adds one event to the phone's default writable calendar.
Future<String> addCalendarEvent(
    {required String title, required DateTime start, required DateTime end, String? note}) async {
  if (!await calendarEnabled()) throw StateError('Calendar is off in Connected apps.');
  if (!end.isAfter(start)) throw ArgumentError('The event must end after it starts.');
  final p = DeviceCalendarPlugin();
  final cals = ((await p.retrieveCalendars()).data ?? const <Calendar>[])
      .where((c) => !(c.isReadOnly ?? true))
      .toList();
  if (cals.isEmpty) throw StateError('No calendar on this phone accepts new events.');
  final cal = cals.firstWhere((c) => c.isDefault ?? false, orElse: () => cals.first);
  await NotificationService.instance.ensureTimezone();
  final r = await p.createOrUpdateEvent(Event(cal.id,
      title: title,
      description: note,
      start: TZDateTime.from(start, local),
      end: TZDateTime.from(end, local)));
  if (r == null || !r.isSuccess) {
    throw StateError('The calendar refused the event${r?.errors.isNotEmpty ?? false ? ': ${r!.errors.first.errorMessage}' : ''}.');
  }
  return 'Added "$title" to ${cal.name}.';
}
