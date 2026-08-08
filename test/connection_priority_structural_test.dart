// Source hygiene: the BLE connection priority has exactly one decision point.
//
// THE BUG THIS EXISTS FOR
//
// See `connection_priority_test.dart` for the full story. The short version:
// the connect path hard-coded `ConnectionPriority.high` once, at setup, and
// nothing ever lowered it — so the band's radio ran at an 11.25-15 ms interval
// with slave latency 0 for the entire life of a link this app deliberately
// keeps open 24/7.
//
// The unit test next door pins the POLICY. It cannot pin that the engine
// actually routes through the policy, because `requestConnectionPriority` is a
// flutter_blue_plus call on a real `BluetoothDevice` and there is no BLE fake
// in this repo. A future refactor of the connect path could quietly re-add a
// literal `ConnectionPriority.high` request and every test here would still be
// green — which is exactly how the original bug got in.
//
// So this greps instead, in the same spirit as `no_debug_only_apis_test.dart`:
//
//   1. `requestConnectionPriority` is called from exactly ONE place in lib/.
//   2. Every `ConnectionPriority.<value>` literal in lib/ lives inside the
//      body of `connectionPriorityFor` — the one function allowed to choose.
//
// If you need a new priority state, add it to `connectionPriorityFor` and give
// it a case in `connection_priority_test.dart`. Do not request a literal at a
// call site.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Blank out `//` line comments while PRESERVING line count, so the offence
/// line numbers below stay accurate and a value named in an explanatory
/// comment (this repo documents these constants heavily) isn't a false hit.
List<String> _codeLines(String source) => source
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i == -1 ? l : l.substring(0, i);
    })
    .toList();

/// Every `.dart` file under `lib/`, as (path, comment-stripped lines).
List<MapEntry<String, List<String>>> _libSources() {
  final lib = Directory('lib');
  expect(lib.existsSync(), isTrue, reason: 'run from the package root');
  final out = <MapEntry<String, List<String>>>[];
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    out.add(MapEntry(entity.path, _codeLines(entity.readAsStringSync())));
  }
  out.sort((a, b) => a.key.compareTo(b.key));
  return out;
}

void main() {
  test('requestConnectionPriority is called from exactly one place', () {
    final callSites = <String>[];
    for (final entry in _libSources()) {
      for (var i = 0; i < entry.value.length; i++) {
        if (entry.value[i].contains('requestConnectionPriority')) {
          callSites.add('${entry.key}:${i + 1}');
        }
      }
    }
    expect(
      callSites,
      hasLength(1),
      reason:
          'The connection priority must have a single applier so the policy '
          'cannot be bypassed. Found: $callSites',
    );
  });

  test('every ConnectionPriority literal lives inside connectionPriorityFor',
      () {
    final literal = RegExp(r'ConnectionPriority\.\w+');
    final offences = <String>[];

    for (final entry in _libSources()) {
      final lines = entry.value;

      // The policy is a TOP-LEVEL function, so its body runs from its
      // signature to the next line that closes at column 0.
      var start = -1;
      var end = -1;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('ConnectionPriority connectionPriorityFor(')) {
          start = i;
          for (var j = i + 1; j < lines.length; j++) {
            if (lines[j] == '}') {
              end = j;
              break;
            }
          }
          break;
        }
      }

      for (var i = 0; i < lines.length; i++) {
        if (!literal.hasMatch(lines[i])) continue;
        final inPolicy = start >= 0 && end > start && i >= start && i <= end;
        if (!inPolicy) {
          offences.add('${entry.key}:${i + 1} → ${lines[i].trim()}');
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'A hard-coded ConnectionPriority outside connectionPriorityFor is '
          'how the 24/7-high-priority strap drain shipped. Route it through '
          'the policy instead.',
    );
  });

  test('the policy function exists in the engine', () {
    // Guards the two greps above against passing vacuously if the policy is
    // renamed, moved or deleted.
    final engine = _libSources().firstWhere(
      (e) => e.key.endsWith('ble/ble_engine.dart'),
    );
    expect(
      engine.value
          .any((l) => l.contains('ConnectionPriority connectionPriorityFor(')),
      isTrue,
      reason: 'connectionPriorityFor must live in ble/ble_engine.dart',
    );
  });
}
