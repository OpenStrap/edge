// The import pages each table by rowid. alarm_schedule is keyed on `weekday`,
// so its rowid IS the weekday, and a cursor that started at `rowid > 0` never
// read Monday (weekday 0): a restored schedule lost its Monday alarm. The
// settings_complete weekday test only hit this when tomorrow was a Monday.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_rowid_zero_test.db'));
  tearDownAll(() async => env.dispose());

  test('every weekday of the alarm schedule survives export and import, '
      'Monday (weekday 0, rowid 0) included', () async {
    await env.wipe();
    for (var weekday = 0; weekday < 7; weekday++) {
      await LocalDb.setAlarmScheduleDay(weekday: weekday, hour: 6,
          minute: weekday, enabled: true, smartWindowMinutes: 10);
    }
    final path = await LocalDb.exportCopy();
    await env.wipe();
    expect(await LocalDb.alarmScheduleRows(), isEmpty);

    await LocalDb.importFromDbFile(path);

    final rows = await LocalDb.alarmScheduleRows();
    expect({for (final r in rows) r['weekday']: r['minute']},
        {for (var weekday = 0; weekday < 7; weekday++) weekday: weekday});
  });
}
