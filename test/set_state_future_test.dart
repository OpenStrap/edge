// No `setState(() => field = …)` may assign a Future-typed field.
//
// The arrow form RETURNS the assigned value, and `State.setState` asserts
// that its callback returned no Future: in a debug build it throws ("setState()
// callback argument returned a Future") AFTER the assignment and BEFORE
// `markNeedsBuild`, so the field changes and the screen does not rebuild.
// Release builds skip the assert, which is why this survives until someone runs
// a debug build and opens the screen. Three sites shipped this way
// (`ProfileHome._open`, `WorkoutScreen.reload`, the workout delete path).
//
// A source scan rather than a widget test because each site sits behind a
// different screen's providers and navigation, and what is wrong is the shape
// of one line, which is what this reads.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fields declared with a `Future<…>` type in [src], by name.
Set<String> _futureFields(String src) => {
      for (final m
          in RegExp(r'Future<[^;=]*?>\??\s+(_?\w+)\s*[;=]').allMatches(src))
        m.group(1)!,
    };

/// `setState(() => name =` sites in [src], as (line, name).
Iterable<(int, String)> _arrowAssignments(String src) sync* {
  for (final m
      in RegExp(r'setState\(\s*\(\)\s*=>\s*(_?\w+)\s*=(?!=)').allMatches(src)) {
    yield ('\n'.allMatches(src.substring(0, m.start)).length + 1, m.group(1)!);
  }
}

void main() {
  test('the scan sees the bad shape and passes the good one', () {
    const bad = 'Future<int>? _f;\n'
        'void a() { setState(() => _f = g()); }';
    const good = 'Future<int>? _f;\n'
        'void a() { setState(() { _f = g(); }); }\n'
        'int _n = 0;\n'
        'void b() { setState(() => _n = 1); }';
    expect(
        [
          for (final (l, n) in _arrowAssignments(bad))
            if (_futureFields(bad).contains(n)) (l, n)
        ],
        [(2, '_f')]);
    expect(
        [
          for (final (l, n) in _arrowAssignments(good))
            if (_futureFields(good).contains(n)) (l, n)
        ],
        isEmpty);
  });

  test('no setState arrow callback assigns a Future-typed field', () {
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      final futures = _futureFields(src);
      for (final (line, name) in _arrowAssignments(src)) {
        if (futures.contains(name)) offenders.add('${f.path}:$line ($name)');
      }
    }
    expect(offenders, isEmpty,
        reason: 'use a block body: setState(() { field = …; })');
  });
}
