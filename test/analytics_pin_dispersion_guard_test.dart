// M5 §0.2/§17: the baseline-dispersion-below-quantum guard in
// readiness_composite.dart is a genuine prerequisite for any cross-device
// masking of readiness's inputs, and it is ALREADY SHIPPED in the pinned
// analytics SHA (verified once, in the planning pass, via `git show`). This
// is the reachability proof that a future repin cannot silently drop it —
// the same defence derivation_engine.dart:916's comment already asks for by
// name, mirrored here as a runnable check rather than a one-off manual grep.
//
// Skips (not fails) when the sibling analytics checkout is not present at
// `../analytics` — this asserts something about THAT repo's history, not
// about this one, and a CI runner that only checks out edge has no way to
// answer it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAnalyticsPin;

void main() {
  test('kAnalyticsPin SHA contains the baseline-dispersion-below-quantum '
      'guard in readiness_composite.dart', () async {
    final analyticsRepo = Directory('../analytics');
    if (!analyticsRepo.existsSync()) {
      markTestSkipped('no sibling analytics checkout at ../analytics');
      return;
    }
    final result = await Process.run(
      'git',
      ['show', '$kAnalyticsPin:lib/src/onehz/wellness/readiness_composite.dart'],
      workingDirectory: analyticsRepo.path,
    );
    expect(result.exitCode, 0,
        reason: 'git show failed for $kAnalyticsPin — is the pin reachable '
            'in the sibling checkout? stderr: ${result.stderr}');
    expect(
      (result.stdout as String).contains('baseline_dispersion_below_quantum'),
      isTrue,
      reason: 'the pinned analytics SHA no longer contains the dispersion '
          'guard readiness_composite.dart needs before M5\'s masking can '
          'safely apply to readiness inputs — this is exactly the v43 '
          'mistake (a changelog citing a change the pin never had) '
          'happening in reverse: a repin silently DROPPING one',
    );
  });
}
