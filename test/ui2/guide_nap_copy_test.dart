import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide_copy.dart';

void main() {
  // WHY: CLAIM(guide-nap-limits). Someone following the guide must not be
  // promised a duration the real form refuses. Use the shared validation caps,
  // with independently translated units, against the shipped footer.
  // catches: the former six-hour promise in any locale, or a stale literal
  // after the shared cap changes.
  const units = {
    'en': ('minutes', 'hours'), 'de': ('Minuten', 'Stunden'),
    'es': ('minutos', 'horas'), 'fr': ('minutes', 'heures'),
    'hi': ('मिनट', 'घंटे'), 'ru': ('минут', 'часов'),
    'th': ('นาที', 'ชั่วโมง'), 'zh': ('分钟', '小时'),
  };
  for (final entry in units.entries) {
    test('${entry.key}: nap guide uses the form duration limits', () {
      final l = lookupAppLocalizations(Locale(entry.key));
      final text = GuideCopy.addNapFooter2Body.of(l);
      expect(text, contains('${kMinManualNapSec ~/ 60} ${entry.value.$1}'));
      expect(text, contains('${kMaxManualNapSec ~/ 3600} ${entry.value.$2}'));
      expect(manualNapWindowIsValid(0, kMinManualNapSec), isTrue);
      expect(manualNapWindowIsValid(0, kMaxManualNapSec), isTrue);
      expect(manualNapWindowIsValid(0, kMaxManualNapSec + 1), isFalse);
    });
  }
}
