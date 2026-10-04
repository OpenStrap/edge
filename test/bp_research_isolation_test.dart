// Nothing outside the allow-list may name the BP research store: a wrist
// series regressed against cuff readings inside the app would be a cuffless
// blood pressure feature. Same mechanism as observation_isolation_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Readers for the dev screen and the CSV export only.
const _allowed = {
  'lib/data/db.dart',
  'lib/data/csv_export.dart',
  'lib/health/bp_research_capture.dart',
  'lib/ui2/profile/bp_research.dart',
};

void main() {
  test('no file outside the allow-list names a BP research table', () {
    final offenders = <String>[];
    final lib = Directory('lib');
    for (final f in lib.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final rel = p.normalize(f.path);
      final s = f.readAsStringSync();
      final hit = s.contains('bp_research_reference') ||
          s.contains('bp_research_window') ||
          s.contains('bp_research_snapshot') ||
          s.contains('bpResearchCaptures') ||
          s.contains('putBpResearchCapture') ||
          s.contains('reprocessBpResearchCapture') ||
          s.contains('deleteBpResearchCapture');
      if (hit && !_allowed.contains(rel)) offenders.add(rel);
    }
    expect(offenders, isEmpty,
        reason: 'files naming the BP research store must be on the allow-list '
            'in test/bp_research_isolation_test.dart');
  });

  test('the allow-list files themselves all exist', () {
    for (final rel in _allowed) {
      expect(File(rel).existsSync(), isTrue, reason: '$rel has vanished');
    }
  });
}
