// Issue #200, the other half: keep ONE decision point for the link interval.
//
// `link_priority_policy_test.dart` pins the stepping RULE, and the
// LinkPriority → ConnectionPriority mapping arm by arm. Neither can pin that
// the engine still routes THROUGH them. The original bug was not a wrong
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
//   2. that call sits inside `_applyLinkPriority`, its argument is exactly
//      `connectionPriorityFor(want)`, and that `want` is assigned from
//      `desiredLinkPriority` — so no link in the chain can be short-circuited
//   3. every `ConnectionPriority.<value>` literal is inside the mapper
//   4. the mapper is declared once, in the engine, and stays @visibleForTesting
//   5. exactly ONE `desiredLinkPriority` declaration, in `sync/sync_policy.dart`
//
// (5) matters because (3) is scoped per-file: a second copy of the policy in
// another lib/ file would carry its own literals and quietly satisfy (3) while
// the engine stopped being the single decision point.
//
// WHAT THIS DELIBERATELY DOES NOT DO: assert the mapping is CORRECT. A grep
// cannot tell `LinkPriority.lowPower => ConnectionPriority.lowPower` from
// `=> ConnectionPriority.high`, and the latter is #200 restored — so that is
// `link_priority_policy_test.dart`'s job, and (4) is what keeps it able to do
// it. The two files are only jointly sufficient.
//
// Comments and string literals are stripped by `support/dart_source.dart`; see
// there for why that is subtler than a regex. Both matter here: this file names
// the offending API in prose, and the engine's own failure log is
// `_log('requestConnectionPriority(...) failed: $e')`, so a naive text count
// reports two calls where there is one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// The two members this test pins, matched as written.
const _applySig = 'Future<void> _applyLinkPriority()';
const _mapperSig =
    'ConnectionPriority connectionPriorityFor(LinkPriority want)';

/// Every `.dart` file under `lib/`, as (path, code-only lines).
List<MapEntry<String, List<String>>> _libSources() {
  final lib = Directory('lib');
  expect(lib.existsSync(), isTrue, reason: 'run from the package root');
  final out = <MapEntry<String, List<String>>>[];
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    out.add(MapEntry(entity.path, codeLines(entity.readAsStringSync())));
  }
  out.sort((a, b) => a.key.compareTo(b.key));
  return out;
}

/// Inclusive line range of the member whose signature contains [signature],
/// found by brace depth so it survives reformatting and nested blocks.
///
/// Handles a braced body and an `=>` body closed by `;`, so the mapper can be
/// an expression member without silently vacating the check.
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
      // `=> …;` with no braces at all: the member ends at the first `;`.
      if (!opened && depth == 0 && lines[j].contains(';')) {
        return (start: i, end: j);
      }
    }
    return null; // unbalanced — treat as not found rather than guessing
  }
  return null;
}

List<String> _engine() => _libSources()
    .firstWhere((e) => e.key.endsWith('ble/ble_engine.dart'))
    .value;

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

  test('the request is in _applyLinkPriority, fed by the whole chain', () {
    final engine = _engine();
    final range = _bodyRange(engine, _applySig);
    expect(range, isNotNull,
        reason: '$_applySig must exist in ble/ble_engine.dart');

    // Joined, because the call and its argument sit on different lines.
    final body = engine.sublist(range!.start, range.end + 1).join('\n');

    expect(
      callSite.hasMatch(body),
      isTrue,
      reason: 'the sole request must live in _applyLinkPriority',
    );
    // The argument is the mapper's return value and nothing else. Merely
    // requiring `connectionPriorityFor` SOMEWHERE in the body would pass a
    // body that computes it and then requests a literal anyway.
    expect(
      RegExp(r'connectionPriorityRequest:\s*connectionPriorityFor\(')
          .hasMatch(body),
      isTrue,
      reason: 'the request argument must be connectionPriorityFor(...) — not '
          'a literal and not another selector, or the policy is decorative',
    );
    expect(
      RegExp(r'\bwant\s*=\s*desiredLinkPriority\(').hasMatch(body),
      isTrue,
      reason: "and the mapper's input must come from desiredLinkPriority",
    );
    expect(
      RegExp(r'connectionPriorityFor\(\s*want\s*\)').hasMatch(body),
      isTrue,
      reason: 'the value handed to the mapper must be that same `want`',
    );
  });

  test('every ConnectionPriority literal is inside the mapper', () {
    final offences = <String>[];
    for (final entry in _libSources()) {
      final range = _bodyRange(entry.value, _mapperSig);
      for (var i = 0; i < entry.value.length; i++) {
        if (!literal.hasMatch(entry.value[i])) continue;
        final inMapper = range != null && i >= range.start && i <= range.end;
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

  test('the mapper is declared once, in the engine, and stays testable', () {
    final decls = <String>[];
    for (final entry in _libSources()) {
      for (var i = 0; i < entry.value.length; i++) {
        if (entry.value[i].contains(_mapperSig)) {
          decls.add('${entry.key}:${i + 1}');
        }
      }
    }
    expect(decls, hasLength(1), reason: 'Found: $decls');
    expect(decls.single, startsWith('lib/ble/ble_engine.dart:'));

    // Without @visibleForTesting a refactor can make it private, and the
    // arm-by-arm coverage in link_priority_policy_test.dart — the only thing
    // standing between a future edit and #200 itself — quietly disappears.
    final engine = _engine();
    final at = int.parse(decls.single.split(':').last) - 1;
    expect(
      engine
          .sublist((at - 3).clamp(0, at), at)
          .any((l) => l.contains('@visibleForTesting')),
      isTrue,
      reason: 'connectionPriorityFor must stay @visibleForTesting so the '
          'mapping keeps its arm-by-arm test',
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
