// The profile setup intro used to say "four numbers" could each be left
// blank, while Continue stays disabled until a sex is picked. Sex is not a
// number and is not optional, so the copy has to say it is required.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile setup intro names sex as required, not as a blankable number',
      () {
    final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final body = arb['profileSetupBody'] as String;
    expect(body.toLowerCase(), isNot(contains('four numbers')));
    expect(body, contains('Sex'));
    expect(body.toLowerCase(), contains('continue'));

    final src =
        File('lib/ui2/onboarding/profile_setup.dart').readAsStringSync();
    expect(src, isNot(contains('Four numbers')));
  });

  test('every locale carries the profile setup intro', () {
    for (final loc in const ['de', 'en', 'es', 'fr', 'hi', 'ru', 'zh']) {
      final arb = jsonDecode(File('lib/l10n/app_$loc.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(arb['profileSetupBody'], isA<String>(), reason: loc);
      expect((arb['profileSetupBody'] as String).isNotEmpty, isTrue,
          reason: loc);
    }
  });
}
