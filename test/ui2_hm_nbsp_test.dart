// A sleep stage duration is shown as a range, "1 Std. 34 Min.-2 Std. 54 Min.".
// Each side is one reading and must stay whole wherever it is drawn. Binding
// only ASCII spaces kept Latin units together but left CJK units (e.g. zh
// "分钟") breakable, since those scripts wrap between characters with no space
// to guard (#757 review). `nbsp` now glues every character with a word joiner,
// so no duration breaks internally in any locale; only the dash may wrap.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show hm, nbsp;

/// True iff a word joiner sits between every adjacent pair of code points, so
/// the run offers no internal line-break opportunity.
bool fullyGlued(String s) {
  final runes = s.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    if (runes[i] != 0x2060 && runes[i + 1] != 0x2060) return false;
  }
  return true;
}

void main() {
  test('a duration never breaks internally, in Latin or CJK scripts', () async {
    SharedPreferences.setMockInitialValues({});
    final c = LocaleController.seed('de');
    c.useForPresentation();

    final one = nbsp(hm(154)); // 2 h 34 min
    expect(one.replaceAll('⁠', ''), '2 Std. 34 Min.'); // unchanged text
    expect(fullyGlued(one), isTrue);

    // CJK has no spaces to bind, and wraps between characters — the gap the
    // space-only version missed.
    expect(nbsp('分钟'), '分⁠钟');
    expect(fullyGlued(nbsp('1 小时 34 分钟')), isTrue);

    await c.setCode(null);
    c.dispose();
  });

  test('a range only ever wraps at the dash between its two durations',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = LocaleController.seed('de');
    c.useForPresentation();

    final range = '${nbsp(hm(94))}–${nbsp(hm(154))}';
    // The dash is the one separator left un-glued, so it is the only break.
    expect(range.replaceAll('⁠', '').split('–'), [hm(94), hm(154)]);
    for (final part in range.split('–')) {
      expect(fullyGlued(part), isTrue);
    }

    await c.setCode(null);
    c.dispose();
  });
}
