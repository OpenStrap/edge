// Shared source scanner for the structural ("grep") tests.
//
// Several tests in this suite assert things about the SHAPE of `lib/` that no
// test running the code can see — `no_debug_only_apis_test.dart` (an API that
// only misbehaves in release), `link_priority_structural_test.dart` (a call
// site that must not be duplicated). All of them need the same primitive: the
// source with its comments and string literals removed, so a token named in
// prose or in a log message is not mistaken for a call.
//
// Getting that primitive right is fiddly enough to be worth doing once:
//
//   * `//` must be stripped AFTER string literals, not before. Stripping it
//     first truncates the line at the `//` inside `'https://…'` and silently
//     discards everything after it — including, in the worst case, a real call
//     the test exists to catch. `lib/ui/kit/route_map.dart` has exactly such a
//     URL, and it carries five brace pairs that a naive strip throws away.
//   * `/* … */` must be handled, and it nests in Dart.
//   * `'''…'''` spans lines, so no per-line regex can consume one — `lib/` has
//     ~80 lines of them.
//   * `'${foo('bar')}'` puts a quote inside a string, so the scanner has to
//     track interpolation rather than pair quotes naively.
//
// Line count is preserved exactly: every removed character becomes a space,
// every newline stays a newline, so reported line numbers stay true.

/// One string literal we are currently inside.
///
/// [depth] is 0 while lexing the string body and counts unclosed braces once
/// we step into a `${…}` interpolation — which is code, and may open further
/// strings of its own.
class _StringFrame {
  _StringFrame(this.quote, this.triple, this.raw);

  final String quote;
  final bool triple;
  final bool raw;
  int depth = 0;
}

/// [source] with every comment and string literal blanked to spaces.
///
/// Interpolated code is blanked along with the string that contains it: it is
/// still inside a literal, and removing it keeps braces balanced for callers
/// that locate a method body by brace depth.
String stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  final stack = <_StringFrame>[];
  final n = source.length;
  var i = 0;

  void blank(int count) {
    for (var k = 0; k < count && i + k < n; k++) {
      out.write(source[i + k] == '\n' ? '\n' : ' ');
    }
    i += count;
  }

  while (i < n) {
    final frame = stack.isEmpty ? null : stack.last;

    // ── inside a string body ────────────────────────────────────────────────
    if (frame != null && frame.depth == 0) {
      if (!frame.raw && source[i] == r'\') {
        blank(2);
        continue;
      }
      if (!frame.raw && source.startsWith(r'${', i)) {
        frame.depth = 1; // step into interpolated code
        blank(2);
        continue;
      }
      final close = frame.triple ? frame.quote * 3 : frame.quote;
      if (source.startsWith(close, i)) {
        stack.removeLast();
        blank(close.length);
        continue;
      }
      blank(1);
      continue;
    }

    // ── code: either top level, or inside a `${…}` ──────────────────────────
    if (source.startsWith('//', i)) {
      final nl = source.indexOf('\n', i);
      blank((nl == -1 ? n : nl) - i); // leave the newline itself
      continue;
    }
    if (source.startsWith('/*', i)) {
      var depth = 0;
      var j = i;
      while (j < n) {
        if (source.startsWith('/*', j)) {
          depth++;
          j += 2;
        } else if (source.startsWith('*/', j)) {
          depth--;
          j += 2;
          if (depth == 0) break;
        } else {
          j++;
        }
      }
      blank(j - i);
      continue;
    }

    // A string start, optionally raw (`r'…'`).
    var q = i;
    var raw = false;
    if (source[i] == 'r' &&
        i + 1 < n &&
        (source[i + 1] == "'" || source[i + 1] == '"')) {
      raw = true;
      q = i + 1;
    }
    if (source[q] == "'" || source[q] == '"') {
      final quote = source[q];
      final triple = source.startsWith(quote * 3, q);
      stack.add(_StringFrame(quote, triple, raw));
      blank((q - i) + (triple ? 3 : 1));
      continue;
    }

    if (frame != null) {
      // Interpolated code — track braces so we know where it ends, but blank
      // it, because it is part of the literal.
      if (source[i] == '{') {
        frame.depth++;
      } else if (source[i] == '}') {
        frame.depth--; // 0 ⇒ back to the string body
      }
      blank(1);
      continue;
    }

    out.write(source[i]);
    i++;
  }

  return out.toString();
}

/// [stripCommentsAndStrings], as lines. Index `i` is source line `i + 1`.
List<String> codeLines(String source) =>
    stripCommentsAndStrings(source).split('\n');
