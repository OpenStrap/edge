// An import keeps running after its screen is closed. A "delete everything"
// that ran meanwhile must stop it, or what it still holds in memory is written
// into the emptied store.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/import/noop_ingest.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

void main() {
  test('an import started before a reset stops at its next sample', () async {
    final ingest = NoopIngest(const Profile(), DerivationEngine());
    ResetGate.enter();
    ResetGate.leave();
    await expectLater(ingest.offer(1760000000), throwsStateError);
    await expectLater(ingest.finish(), throwsStateError);
  });

  test('an import started after a reset is not affected by it', () async {
    ResetGate.enter();
    ResetGate.leave();
    final ingest = NoopIngest(const Profile(), DerivationEngine());
    expect(await ingest.offer(1760000000), isTrue);
  });

  test('a derive the import queued behind the reset writes nothing', () {
    final src =
        File('lib/compute/derivation_engine.dart').readAsStringSync();
    final fn = src.substring(src.indexOf('Future<int> deriveImportedDays('));
    final lock = fn.indexOf('return _withRunLock(');
    final check = fn.indexOf('if (resetSince()) break;');
    final write = fn.indexOf('await _deriveDay(');
    expect(check, greaterThan(lock));
    expect(check, lessThan(write));
    final ingest = File('lib/import/noop_ingest.dart').readAsStringSync();
    expect('resetGeneration: _resetGen'.allMatches(ingest).length, 2);
  });
}
