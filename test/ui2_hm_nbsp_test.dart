// A sleep stage duration is shown as a range, "1 Std. 34 Min.-2 Std. 54 Min.".
// Each side is one reading. Left with ordinary spaces it wrapped between a
// number and its unit, so the value broke before the final unit and dropped a
// lone "Min." onto its own right-aligned line (the shifted numbers in #… /
// the Sleep screen). `nbsp` binds each duration; only the dash may wrap.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show hm, nbsp;

void main() {
  test('a range value only ever wraps at the dash between its two durations',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = LocaleController.seed('de');
    c.useForPresentation();

    // Same visible text, no breakable space inside a single duration.
    final one = nbsp(hm(154)); // 2 h 34 min
    expect(one.replaceAll(' ', ' '), '2 Std. 34 Min.');
    expect(one.contains(' '), isFalse);

    // The range as the screen builds it: a dash joins two bound durations, so
    // the dash is the only place a line may break and neither side can split.
    final range = '${nbsp(hm(94))}–${nbsp(hm(154))}';
    final parts = range.split('–');
    expect(parts, hasLength(2));
    for (final part in parts) {
      expect(part.contains(' '), isFalse,
          reason: 'each duration in a range stays whole');
    }

    await c.setCode(null);
    c.dispose();
  });
}
