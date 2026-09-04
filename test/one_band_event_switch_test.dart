// M1 §13 roll-up: after the host rewire there is exactly one `switch` over
// `BandEvent` in the whole of lib/ — `BandHost._onEvent`
// (lib/ble/adapters/host.dart). hrs_link.dart and oura_link.dart used to each
// have their own hand-written copy; a third one appearing anywhere else is
// exactly the drift M1 exists to close off.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _allowlist = {'lib/ble/adapters/host.dart'};

final _pureComment = RegExp(r'^\s*(///|//|\*|/\*)');

void main() {
  test('case SampleBatch( only appears in the one allowlisted host file', () {
    final pattern = RegExp(r'case SampleBatch\(');
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = f.path.replaceFirst(RegExp(r'^\./'), '');
      if (_allowlist.contains(rel)) continue;
      for (final line in f.readAsStringSync().split('\n')) {
        if (_pureComment.hasMatch(line)) continue;
        if (pattern.hasMatch(line)) offenders.add('$rel: $line');
      }
    }
    expect(offenders, isEmpty,
        reason: 'a second BandEvent switch means the ephemeral refusal, the '
            'commit-then-confirm ordering, or the device_id stamping can '
            'drift between two copies:\n${offenders.join('\n')}');
  });
}
