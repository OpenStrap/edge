// THE personal quiet-waking level for scoring anything OUTSIDE a derive sweep
// — a saved/edited session, the on-read re-score, the live gauge, the strain
// rescale. A day's own derive reads the same window from its sweep snapshot
// (`_BaselineHistoryCache.valuesBefore('quiet_hrr', date)`); this is that read
// against the database, so a session and the day it sits in are priced on one
// level.

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';

/// The median of the trailing 28 measured `quiet_hrr` days strictly before
/// [dayLabel] (a LOCAL day label). Absent — never a stand-in — below three
/// days, or when the read fails.
Future<ana.Metric<ana.QuietLevel>> personalQuietLevelBefore(
  String dayLabel,
) async {
  try {
    return ana.personalQuietWakingHrr(
      await LocalDb.trailingSeriesValues(
        'quiet_hrr',
        ana.quietHrrWindowDays,
        before: dayLabel,
      ),
    );
  } catch (_) {
    return ana.personalQuietWakingHrr(const []); // abstains, never a stand-in
  }
}
