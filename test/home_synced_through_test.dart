// "Synced through …" — the Home header's answer to "how far are we?".
//
// It reads the BAND's clock (the newest record banked), not when the app last
// talked to the strap: a sync that connects, transfers nothing and disconnects
// is not progress, and a status built on last contact would call it progress.
//
// "Today" is the day the SCREEN is showing, never `DateTime.now()` — a clock
// read during build decides once and then goes stale across midnight.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';

void main() {
  const today = '2026-09-08';

  test('a record from today shows the bare time', () {
    expect(
      syncedThroughLabel(DateTime(2026, 9, 8, 11, 6), today),
      'Synced through 11:06',
    );
  });

  test('midnight pads to two digits rather than reading as 0:6', () {
    expect(
      syncedThroughLabel(DateTime(2026, 9, 8, 0, 6), today),
      'Synced through 00:06',
    );
  });

  test('an older record carries its day — a lone time would mislead', () {
    // A strap last worn on Friday must not report "07:12" beside today's
    // date and let it read as this morning.
    expect(
      syncedThroughLabel(DateTime(2026, 9, 4, 7, 12), today),
      'Synced through Fri 4 Sep, 07:12',
    );
  });

  test('same clock time on another day is still dated', () {
    expect(
      syncedThroughLabel(DateTime(2026, 9, 7, 11, 6), today),
      isNot('Synced through 11:06'),
    );
  });

  test('with no day on screen, even a same-day record is dated', () {
    // The loading / failed / first-run path has no day label. Without one,
    // "today" is not a thing we know, so the honest render is the dated form.
    expect(
      syncedThroughLabel(DateTime(2026, 9, 8, 11, 6), null),
      'Synced through Tue 8 Sep, 11:06',
    );
  });

  test('nothing banked says so plainly', () {
    expect(syncedThroughLabel(null, today), 'No band data yet');
  });
}
