// DEMO FIXTURES (phase 2) — RED-PHASE STUBS ONLY. In lib so the app can render
// them; never written to the DB.

import '../activity/day_strain.dart' show DayStrainData;
import '../activity/zones.dart' show ZonesData;
import '../screens/home_screen.dart' show HomeData;

abstract final class GuideDemo {
  /// Today, all three rings scored (strain visible).
  static HomeData get home => throw UnimplementedError();

  /// A curve, zone minutes with a non-zero total, a computed (not manual) set.
  static DayStrainData get dayStrain => throw UnimplementedError();

  /// Five zone rows, source not 'manual' (so the link reads "Set your own").
  static ZonesData get zones => throw UnimplementedError();
}
