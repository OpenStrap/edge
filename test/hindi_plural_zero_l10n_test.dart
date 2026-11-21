import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations_hi.dart';

void main() {
  // Hindi plural 'one' also matches 0, so a literal "1" there shows "1" for a
  // count of zero.
  test('hindi plural one branches never hardcode the digit 1', () {
    final arb = File('lib/l10n/app_hi.arb').readAsStringSync();
    expect(RegExp(r'one\{[^{}]*\b1\b').hasMatch(arb), isFalse);
  });

  test('zero counts read as zero in hindi', () {
    final l = AppLocalizationsHi();
    expect(l.profileSourcesCount(0), '0 स्रोत');
    expect(l.dataDaysReanalyzed(0), startsWith('0 '));
    expect(l.bandStatusReconnectPausedReason(0), contains('0 बार'));
  });
}
