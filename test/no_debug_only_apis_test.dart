// Source hygiene: no assert-stripped Flutter APIs in production code.
//
// THE BUG THIS EXISTS FOR
//
// The workout share flow called `RenderRepaintBoundary.debugNeedsPaint` to
// decide whether to wait a frame before rasterising. That getter is shaped like
// this in the Flutter SDK (rendering/object.dart):
//
//     bool get debugNeedsPaint {
//       late bool result;
//       assert(() { result = _needsPaint; return true; }());
//       return result;
//     }
//
// Asserts are stripped in release and profile builds, so `result` is never
// assigned and simply READING the getter throws:
//
//     LateInitializationError: Local 'result' has not been initialized.
//
// Sharing therefore worked perfectly in debug and failed on every real build.
//
// Nothing else catches this. `flutter analyze` is happy — it is a legal getter
// call. The entire test suite runs in DEBUG mode, where the assert executes and
// the getter behaves, so no widget or unit test can reproduce it. Only a
// release build on a device does, which is the slowest possible feedback loop.
//
// So this test greps instead. The denylist below was not guessed: it is every
// getter in the Flutter SDK matching the `late <T> result; assert(...)` shape.
// Regenerate it with:
//
//     grep -rzoP '\w[\w<>, ?]*\s+get\s+\w+\s*\{\s*late\s+[\w<>, ?]+\s+result;\s*assert\(' \
//       $FLUTTER_ROOT/packages/flutter/lib/src
//
// If a member here is genuinely needed, guard it inside an `assert(() {...})`
// block — never on a code path that runs in release.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// Getters whose value only exists when asserts are enabled.
const _assertStrippedMembers = <String>[
  'debugNeedsPaint',
  'debugNeedsLayout',
  'debugNeedsCompositedLayerUpdate',
];

void main() {
  test('no assert-stripped Flutter APIs are called in lib/', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the package root');

    final offences = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final code = stripCommentsAndStrings(entity.readAsStringSync());
      final lines = code.split('\n');
      for (var i = 0; i < lines.length; i++) {
        for (final member in _assertStrippedMembers) {
          // `.member` — a call on an instance. A declaration of the same name
          // (we don't have one) wouldn't match the leading dot.
          if (lines[i].contains('.$member')) {
            offences.add('${entity.path}:${i + 1} → $member');
          }
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason: 'These read fine in debug and throw LateInitializationError in '
          'release/profile, because their value is only assigned inside an '
          'assert. Guard them inside `assert(() { ... }())` or drop them:\n'
          '${offences.join('\n')}',
    );
  });

  test('the denylist itself is non-empty and plausible', () {
    // A regenerated-but-emptied denylist would make the test above vacuous.
    expect(_assertStrippedMembers, isNotEmpty);
    expect(_assertStrippedMembers, contains('debugNeedsPaint'));
  });

  test('the shared source stripper does not hide a real call', () {
    const sample = '''
      // boundary.debugNeedsPaint is mentioned here in prose
      final x = boundary.debugNeedsPaint;
    ''';
    final stripped = stripCommentsAndStrings(sample);
    expect(stripped.contains('.debugNeedsPaint'), isTrue,
        reason: 'the real call on line 2 must survive stripping');
    expect('\n'.allMatches(stripped).length, greaterThan(1));
    // And a comment-only mention must NOT trip it.
    const commentOnly = '// see boundary.debugNeedsPaint for why';
    expect(
        stripCommentsAndStrings(commentOnly).contains('.debugNeedsPaint'),
        isFalse);
  });
}
