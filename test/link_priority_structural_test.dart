// Issue #200, the other half: keep ONE decision point for the link interval.
//
// `link_priority_policy_test.dart` pins the stepping RULE. It cannot pin that
// the engine still routes through that rule. The original bug was not a wrong
// policy — it was no policy at all: a literal
//
//     device.requestConnectionPriority(
//       connectionPriorityRequest: ConnectionPriority.high)
//
// sat in the connect path, ran once, and nothing ever stepped it back down. A
// future refactor of that path can re-add exactly that line, and every
// behavioural test in this repo would stay green, because `desiredLinkPriority`
// would still return the right answer to a caller that no longer exists.
//
// There is no BLE fake here to assert against, so this greps instead — same
// approach as `no_debug_only_apis_test.dart`, for the same reason (the failure
// is invisible to any test that runs the code):
//
//   1. exactly ONE real `requestConnectionPriority` call in lib/, in the engine
//   2. that call sits inside `_applyLinkPriority`, and takes its target from
//      `desiredLinkPriority` — so the request cannot bypass the policy
//   3. every `ConnectionPriority.<value>` literal is inside that one method's
//      mapping switch
//   4. exactly ONE `desiredLinkPriority` declaration, in `sync/sync_policy.dart`
//
// (4) matters because (3) is scoped per-file: a second copy of the policy in
// another lib/ file would carry its own literals and quietly satisfy (3) while
// the engine stopped being the single decision point.
//
// Comments AND string literals are stripped before matching. Both are load
// bearing: this file names the offending API in prose, and the engine's own
// failure log is `_log('requestConnectionPriority(...) failed: $e')` — a naive
// text count reports two calls where there is one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Blank out `//` comments and string literals, preserving line count so the
/// reported line numbers stay true.
List<String> _codeLines(String source) => source.split('\n').map((line) {
      final commentAt = line.indexOf('//');
      final noComment = commentAt == -1 ? line : line.substring(0, commentAt);
      return noComment
          .replaceAll(RegExp(r"r?'''(?:.|\n)*?'''"), "''")
          .replaceAll(RegExp(r'r?"""(?:.|\n)*?"""'), '""')
          .replaceAll(RegExp(r"r?'(?:\\.|[^'\\])*'"), "''")
          .replaceAll(RegExp(r'r?"(?:\\.|[^"\\])*"'), '""');
    }).toList();

/// Every `.dart` file under `lib/`, as (path, code-only lines).
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

/// Inclusive line range of the method whose signature contains [signature],
/// found by brace depth so it survives reformatting and nested blocks.
/// Returns null when the signature is absent.
({int start, int end})? _bodyRange(List<String> lines, String signature) {
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].contains(signature)) continue;
    var depth = 0;
    var opened = false;
    for (var j = i; j < lines.length; j++) {
      for (final ch in lines[j].split('')) {
        if (ch == '{') {
          depth++;
          opened = true;
        } else if (ch == '}') {
          depth--;
        }
      }
      if (opened && depth == 0) return (start: i, end: j);
    }
    return null; // unbalanced — treat as not found rather than guessing
  }
  return null;
}

void main() {
  // A method call, not the API name appearing in prose or a log string.
  final callSite = RegExp(r'\.requestConnectionPriority\s*\(');
  final literal = RegExp(r'ConnectionPriority\.\w+');
  final policyDecl = RegExp(r'^\s*LinkPriority\s+desiredLinkPriority\s*\(');

  test('exactly one requestConnectionPriority call, and it is in the engine',
      () {
    final calls = <String>[];
    for (final entry in _libSources()) {
      for (var i = 0; i < entry.value.length; i++) {
        if (callSite.hasMatch(entry.value[i])) {
          calls.add('${entry.key}:${i + 1}');
        }
      }
    }
    expect(
      calls,
      hasLength(1),
      reason: 'a second request site can bypass the policy. Found: $calls',
    );
    expect(calls.single, startsWith('lib/ble/ble_engine.dart:'));
  });

  test('the request is inside _applyLinkPriority and takes desiredLinkPriority',
      () {
    final engine = _libSources()
        .firstWhere((e) => e.key.endsWith('ble/ble_engine.dart'))
        .value;
    final range = _bodyRange(engine, 'Future<void> _applyLinkPriority()');
    expect(range, isNotNull,
        reason: '_applyLinkPriority must exist in ble/ble_engine.dart');

    final body = engine.sublist(range!.start, range.end + 1);
    expect(
      body.any(callSite.hasMatch),
      isTrue,
      reason: 'the sole request must live in _applyLinkPriority',
    );
    expect(
      body.any((l) => l.contains('desiredLinkPriority(')),
      isTrue,
      reason:
          'the request must take its target from desiredLinkPriority, not a '
          'literal or another selector — otherwise the policy is decorative',
    );
  });

  test('every ConnectionPriority literal is inside _applyLinkPriority', () {
    final offences = <String>[];
    for (final entry in _libSources()) {
      final range = _bodyRange(entry.value, 'Future<void> _applyLinkPriority()');
      for (var i = 0; i < entry.value.length; i++) {
        if (!literal.hasMatch(entry.value[i])) continue;
        final inMapper =
            range != null && i >= range.start && i <= range.end;
        if (!inMapper) {
          offences.add('${entry.key}:${i + 1} → ${entry.value[i].trim()}');
        }
      }
    }
    expect(
      offences,
      isEmpty,
      reason: 'a hard-coded ConnectionPriority outside the mapping switch is '
          'how issue #200 shipped. Route it through desiredLinkPriority.',
    );
  });

  test('exactly one desiredLinkPriority declaration, in sync_policy.dart', () {
    final decls = <String>[];
    for (final entry in _libSources()) {
      for (var i = 0; i < entry.value.length; i++) {
        if (policyDecl.hasMatch(entry.value[i])) {
          decls.add('${entry.key}:${i + 1}');
        }
      }
    }
    expect(
      decls,
      hasLength(1),
      reason: 'a second policy copy would satisfy the per-file literal check '
          'while the engine stopped being the single decision point. '
          'Found: $decls',
    );
    expect(decls.single, startsWith('lib/sync/sync_policy.dart:'));
  });
}
