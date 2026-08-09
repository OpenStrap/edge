// Regression cases for the scanner the structural tests are built on.
//
// Every case here is a way the previous per-line regex helper got it wrong.
// They matter because when this primitive fails, it fails invisibly: the grep
// test it feeds goes green either way.

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  test('line count and column positions survive', () {
    const src = "a();\n// gone\nb('str');\n";
    final lines = codeLines(src);
    expect(lines, hasLength(4));
    expect(lines[0], 'a();');
    expect(lines[1].trim(), isEmpty);
    // The literal goes, quotes included, but its width is kept so columns
    // still line up with the original source.
    expect(lines[2], 'b(     );');
    expect(lines[2], hasLength("b('str');".length));
  });

  test("a '//' inside a string does not truncate the rest of the line", () {
    // The bug: stripping `//` before strings ate everything after the URL,
    // including a real call the guard exists to catch.
    const src = "const u = 'https://x/y'; d.requestConnectionPriority(1);";
    final code = stripCommentsAndStrings(src);
    expect(code, contains('requestConnectionPriority'));
    expect(code, isNot(contains('https')));
  });

  test('braces inside a string are removed, not counted', () {
    // lib/ui/kit/route_map.dart is a live instance of this.
    const src = "const t = 'https://{s}.tiles/{z}/{x}/{y}{r}.png';";
    final code = stripCommentsAndStrings(src);
    expect(code.contains('{'), isFalse);
    expect(code.contains('}'), isFalse);
  });

  test('block comments are stripped, and they nest', () {
    const src = 'a(); /* x /* y */ z */ b();';
    final code = stripCommentsAndStrings(src);
    expect(code, contains('a();'));
    expect(code, contains('b();'));
    expect(code, isNot(contains('x')));
    expect(code, isNot(contains('z')));
  });

  test('a multi-line block comment keeps its newlines', () {
    const src = 'a();\n/* one\n   two\n */\nb();';
    final lines = codeLines(src);
    expect(lines, hasLength(5));
    expect(lines[4], 'b();');
    expect(lines[1].trim(), isEmpty);
    expect(lines[2].trim(), isEmpty);
  });

  test('a token named in a block comment is not a match', () {
    const src =
        '/* used to call d.requestConnectionPriority(x) here */\nok();';
    expect(
      stripCommentsAndStrings(src),
      isNot(contains('requestConnectionPriority')),
    );
  });

  test('triple-quoted strings are stripped across lines', () {
    // No per-line regex can do this, and lib/ has ~80 such lines.
    const src = "final q = '''\nrequestConnectionPriority(\n{{{\n''';\nok();";
    final code = stripCommentsAndStrings(src);
    expect(code, isNot(contains('requestConnectionPriority')));
    expect(code.contains('{'), isFalse);
    expect(code, contains('ok();'));
    expect(codeLines(src), hasLength(5));
  });

  test('interpolation containing a quote does not end the string early', () {
    const src = "_log('a \${m['k']} b'); real();";
    final code = stripCommentsAndStrings(src);
    expect(code, contains('_log('));
    expect(code, contains('real();'));
    expect(code, isNot(contains('k')));
    expect(code.contains('{'), isFalse);
  });

  test('a string inside interpolation can itself hold a comment marker', () {
    const src = "final s = '\${f('//')} tail'; kept();";
    expect(stripCommentsAndStrings(src), contains('kept();'));
  });

  test('escapes do not terminate a string, and raw strings ignore them', () {
    expect(stripCommentsAndStrings(r"var a = 'x\'y'; z();"), contains('z();'));
    expect(stripCommentsAndStrings(r"var a = r'x\'; z();"), contains('z();'));
  });

  test('the engine failure log is not counted as a call site', () {
    // The concrete reason the structural test needs string stripping at all.
    const src = r"_log('requestConnectionPriority(${want.name}) failed: $e');";
    expect(
      stripCommentsAndStrings(src),
      isNot(contains('requestConnectionPriority')),
    );
  });
}
