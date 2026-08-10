// The curve wire format has to be applied at EVERY seam, not most of them.
//
// AGENTS.md §4.7 is the recurring failure this guards against: a capability
// wired into one call path but not all N. The worst instance in this repo's
// history — FirmwareAwareR24Decoder existing but reaching only one of three
// decode paths — was a total sync outage for real users.
//
// The equivalent here is quiet rather than loud. A day_result reader that calls
// jsonDecode directly gets `{'t0':…,'dt':60,'v':[…]}` where it expects
// `[{t,v},…]`, matches neither, and renders an empty chart. No exception, no
// crash — just a curve that silently is not there.
//
// So: assert the seams structurally. These are the functions that turn a stored
// payload_json into a Map, and each one must route through SeriesCodec.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// A bundle-decode seam: the file, the helper, and why it counts.
class Seam {
  const Seam(this.path, this.helper, this.why);
  final String path;
  final String helper;
  final String why;
}

const seams = [
  Seam(
    'lib/data/local_repository_impl.dart',
    '_decode',
    'the read seam every screen is served from',
  ),
  Seam(
    'lib/compute/derivation_engine.dart',
    '_decodeBundle',
    'the re-derive path merges a previous bundle into a fresh one',
  ),
  Seam(
    'lib/health/health_export.dart',
    '_decode',
    'the Apple Health sleep export reads hypnogram out of a bundle',
  ),
];

/// Index just past the `)` matching the `(` at [open].
int? _matchParen(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return null;
}

/// The body of the DECLARATION of `name`, from comment/string-stripped source.
///
/// Two things a naive scan gets wrong, both of which made this guard pass while
/// looking at the wrong text:
///   • `code.indexOf(name)` finds a CALL SITE — `local_repository_impl` calls
///     `_decode` seventy lines above where it declares it.
///   • brace-matching from the first `{` matches the NAMED PARAMETER list, so
///     `putDayResult({…})` returned its own signature instead of its body.
String? helperBody(String code, String name) {
  var from = 0;
  while (true) {
    final start = code.indexOf(name, from);
    if (start < 0) return null;
    from = start + name.length;

    // Must be `name(`, not a substring of a longer identifier.
    var i = start + name.length;
    while (i < code.length && code[i] == ' ') {
      i++;
    }
    if (i >= code.length || code[i] != '(') continue;

    final afterParams = _matchParen(code, i);
    if (afterParams == null) continue;

    // Skip whitespace and any `async` / `async*` / `sync*` modifier.
    var j = afterParams;
    while (j < code.length && (code[j] == ' ' || code[j] == '\n')) {
      j++;
    }
    for (final kw in const ['async*', 'async', 'sync*']) {
      if (code.startsWith(kw, j)) {
        j += kw.length;
        while (j < code.length && (code[j] == ' ' || code[j] == '\n')) {
          j++;
        }
        break;
      }
    }

    // Expression body ends at the semicolon; block body brace-matches.
    if (code.startsWith('=>', j)) {
      final end = code.indexOf(';', j);
      return end < 0 ? null : code.substring(start, end);
    }
    if (j < code.length && code[j] == '{') {
      var depth = 0;
      for (var k = j; k < code.length; k++) {
        if (code[k] == '{') depth++;
        if (code[k] == '}') {
          depth--;
          if (depth == 0) return code.substring(start, k + 1);
        }
      }
      return null;
    }
    // A call site — keep looking for the declaration.
  }
}

void main() {
  for (final seam in seams) {
    test('${seam.path} ${seam.helper} routes through SeriesCodec', () {
      final file = File(seam.path);
      expect(file.existsSync(), isTrue, reason: '${seam.path} moved or was renamed');

      final code = stripCommentsAndStrings(file.readAsStringSync());
      final body = helperBody(code, seam.helper);
      expect(
        body,
        isNotNull,
        reason: '${seam.helper} not found in ${seam.path} — if it was renamed, '
            'update this guard rather than deleting it',
      );
      expect(
        body,
        contains('SeriesCodec'),
        reason: 'BYPASSED: ${seam.helper} decodes a stored bundle without '
            'normalizing the curve format. ${seam.why}. A grid/offset curve '
            'reaches the caller as a Map where it expects a List and silently '
            'renders as nothing.',
      );
    });
  }

  test('putDayResult encodes on the way in', () {
    // The single write seam. All four callers (DerivationEngine x2,
    // cloud_import, whoop_import) go through it, which is the only reason
    // producers can keep building plain [{t,v}] lists in memory.
    final code = stripCommentsAndStrings(
      File('lib/data/db.dart').readAsStringSync(),
    );
    final body = helperBody(code, 'putDayResult');
    expect(body, isNotNull);
    expect(
      body,
      contains('SeriesCodec.encodePayloadJson'),
      reason: 'putDayResult stopped encoding — new days would be written in '
          'the legacy shape and the saving would quietly stop',
    );
  });

  test('the payload column is still TEXT, never a BLOB', () {
    // The coach views read payload_json with json_each/json_extract. If this
    // column ever becomes a compressed BLOB, v_series and v_hypnogram return
    // nothing and the AI Coach loses every intra-day curve — sqflite cannot
    // register a SQL decompress function to get it back.
    final code = stripCommentsAndStrings(
      File('lib/data/db.dart').readAsStringSync(),
    );
    expect(code, isNot(contains('payload_json BLOB')));
  });

  test('v_series reads all three shapes', () {
    // Old rows keep the legacy shape forever — there is no rewriting migration
    // — so dropping the legacy branch would blank every un-backfilled day.
    final src = File('lib/data/db.dart').readAsStringSync();
    final view = src.substring(
      src.indexOf('CREATE VIEW v_series'),
      src.indexOf('CREATE VIEW v_hypnogram'),
    );
    expect(view, contains(".pth)) = 'array'"), reason: 'legacy branch missing');
    expect(view, contains(".pth||'.dt'"), reason: 'grid branch missing');
    expect(view, contains(".pth||'.to'"), reason: 'offset branch missing');
  });
}
