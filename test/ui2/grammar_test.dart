import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/units_controller.dart';
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

    test('reads a decimal comma that cannot be a thousands separator', () {
      // The iOS decimal pad on a comma-locale phone has no '.' key.
      expect(Typed.of('4,5').value, 4.5);
      expect(Typed.of('72,25').value, 72.25);
      expect(Typed.of('0,125').value, 0.125);
      expect(Typed.of('1234,567').value, 1234.567);
      expect(Typed.of('-0,5').value, -0.5);
      expect(Typed.of(' 4,5 ').bad, isFalse);
    });

    test('a comma that could be grouping is still unreadable', () {
      for (final s in ['1,200', '72,500', '1,2,3', '1,5.0', ',5', '5,']) {
        expect(Typed.of(s).bad, isTrue, reason: s);
        expect(Typed.of(s).value, isNull, reason: s);
      }
    });

    test('profile weight and height take a decimal comma too', () {
      final u = UnitsController.seed(UnitSystem.metric);
      expect(u.weightToKg('72,5'), 72.5);
      expect(u.heightToCm('180,5'), 180.5);
      expect(u.weightToKg('1,200'), isNull);
    });

    test('blank text is blank, not bad', () {
      final t = Typed.of('   ');
      expect(t.blank, isTrue);
      expect(t.bad, isFalse);
    });
  });
}
