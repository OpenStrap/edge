// A NOOP import must gate HR and RR the same way the band decode does, or the
// same night scores differently depending on where it came from.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/import/noop_ingest.dart';

/// Captures the Substrate the ingest hands over instead of deriving it.
class _CapturingEngine extends DerivationEngine {
  final List<Substrate> subs = [];

  @override
  Future<int> deriveImportedDays(
    Substrate sub,
    Profile profile,
    Set<String> dates, {
    void Function(String day)? onDayDone,
    int? resetGeneration,
  }) async {
    subs.add(sub);
    return dates.length;
  }

  @override
  Future<void> finalizeImport(Profile profile) async {}
}

void main() {
  test('implausible HR becomes 0 and implausible RR is dropped', () async {
    final engine = _CapturingEngine();
    final ingest = NoopIngest(const Profile(), engine);
    // Midday, so every sample sits on the same local date.
    final base = DateTime(2026, 3, 10, 12).millisecondsSinceEpoch ~/ 1000;

    final hrs = [60, 255, 1, 230, 25, 24, 231];
    for (var i = 0; i < hrs.length; i++) {
      expect(await ingest.offer(base + i), isTrue);
      ingest.hr(base + i, hrs[i]);
    }
    final rrs = [800.0, 30.0, 9000.0, 250.0, 2400.0, 249.0, 2401.0];
    for (var i = 0; i < rrs.length; i++) {
      expect(await ingest.offer(base + i), isTrue);
      ingest.rr(base + i, rrs[i]);
    }
    await ingest.finish();

    expect(engine.subs, hasLength(1));
    final sub = engine.subs.single;
    // Every second is kept, so its other channels still have a home.
    expect(sub.tsSec, [for (var i = 0; i < hrs.length; i++) base + i]);
    expect(sub.hr, [60, 0, 0, 230, 25, 0, 0]);
    expect(sub.rrMs, [800.0, 250.0, 2400.0]);
  });
}
