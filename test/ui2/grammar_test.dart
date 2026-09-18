import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';

void main() {
  group('Typed.of', () {
    test('rejects Infinity, -Infinity, NaN and overflow literals', () {
      for (final s in ['Infinity', '-Infinity', 'NaN', '1e400']) {
        final t = Typed.of(s);
        expect(t.bad, isTrue, reason: '"$s" should be bad');
        expect(t.value, isNull);
      }
    });

    test('accepts ordinary numbers', () {
      final t = Typed.of('180');
      expect(t.bad, isFalse);
      expect(t.value, 180.0);
    });

    test('blank text is blank, not bad', () {
      final t = Typed.of('   ');
      expect(t.blank, isTrue);
      expect(t.bad, isFalse);
    });
  });
}
