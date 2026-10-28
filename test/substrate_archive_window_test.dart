// The archive window the data settings step through.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/substrate_archive.dart';

void main() {
  test('defaults to 90 days', () {
    expect(SubstrateArchivePolicy.defaults.keepDays, 90);
    expect(SubstrateArchivePolicy.fromJson(null).keepDays, 90);
  });

  test('steps 30 → 90 → 365 → forever → 30', () {
    var p = const SubstrateArchivePolicy(30);
    final seen = <int>[];
    for (var i = 0; i < 4; i++) {
      p = p.next;
      seen.add(p.keepDays);
    }
    expect(seen, [90, 365, -1, 30]);
  });

  test('an off or hand-set window moves to the next longer choice', () {
    expect(const SubstrateArchivePolicy(0).next.keepDays, 30);
    expect(const SubstrateArchivePolicy(45).next.keepDays, 90);
    expect(const SubstrateArchivePolicy(400).next.keepDays, -1);
  });

  test('only a shorter window counts as deleting history', () {
    const forever = SubstrateArchivePolicy(-1);
    const year = SubstrateArchivePolicy(365);
    const month = SubstrateArchivePolicy(30);
    expect(forever.keepsLongerThan(month), isTrue);
    expect(year.keepsLongerThan(month), isTrue);
    expect(month.keepsLongerThan(year), isFalse);
    expect(month.keepsLongerThan(forever), isFalse);
    expect(year.keepsLongerThan(year), isFalse);
  });
}
