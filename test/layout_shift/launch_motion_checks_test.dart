import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

const _p = ShiftPolicy.standard;

void main() {
  group('checkFirstPaint (<= 20 ms, no brighter than #222)', () {
    test('20 ms on a dark colour is ok', () {
      expect(checkFirstPaint(20, 0xFF0B1017, _p), ShiftSeverity.none);
    });
    test('21 ms is late => error', () {
      expect(checkFirstPaint(21, 0xFF0B1017, _p), ShiftSeverity.error);
    });
    test('#222222 exactly is ok', () {
      expect(checkFirstPaint(0, 0xFF222222, _p), ShiftSeverity.none);
    });
    test('#232323 is brighter => error', () {
      expect(checkFirstPaint(0, 0xFF232323, _p), ShiftSeverity.error);
    });
    test('#0B1017 (dark app background) is ok', () {
      expect(checkFirstPaint(0, 0xFF0B1017, _p), ShiftSeverity.none);
    });
    test('#F8FAFC (light app background) is an error', () {
      expect(checkFirstPaint(0, 0xFFF8FAFC, _p), ShiftSeverity.error);
    });
    test('firstPaintMaxMs / firstPaintMaxArgb are tunable', () {
      final loose = _p.copyWith(firstPaintMaxMs: 50, firstPaintMaxArgb: 0xFFFFFFFF);
      expect(checkFirstPaint(40, 0xFFF8FAFC, loose), ShiftSeverity.none);
    });
  });

  group('checkReducedMotion (<= 150 ms, or chain cycles 750..2000 ms)', () {
    test('149 ms span is ok', () {
      expect(checkReducedMotion(const [AnimationSpan(0, 149)], _p), isEmpty);
    });
    test('150 ms span is ok', () {
      expect(checkReducedMotion(const [AnimationSpan(0, 150)], _p), isEmpty);
    });
    test('151 ms span is an error', () {
      final f = checkReducedMotion(const [AnimationSpan(0, 151)], _p);
      expect(f, hasLength(1));
      expect(f.single.severity, ShiftSeverity.error);
    });
    test('chain of 1000 ms cycles is ok', () {
      final f = checkReducedMotion(const [
        AnimationSpan(0, 1000, chainId: 'c'),
        AnimationSpan(1000, 2000, chainId: 'c'),
        AnimationSpan(2000, 3000, chainId: 'c'),
      ], _p);
      expect(f, isEmpty);
    });
    test('chain of 300 ms cycles errors once per span', () {
      final f = checkReducedMotion(const [
        AnimationSpan(0, 300, chainId: 'c'),
        AnimationSpan(300, 600, chainId: 'c'),
        AnimationSpan(600, 900, chainId: 'c'),
      ], _p);
      expect(f, hasLength(3));
      expect(f.every((e) => e.severity == ShiftSeverity.error), isTrue);
    });
    test('a lone 1000 ms span (no chain) is an error', () {
      expect(checkReducedMotion(const [AnimationSpan(0, 1000)], _p), hasLength(1));
    });
    test('a chain with one 2500 ms cycle is an error', () {
      final f = checkReducedMotion(const [
        AnimationSpan(0, 1000, chainId: 'c'),
        AnimationSpan(1000, 3500, chainId: 'c'),
      ], _p);
      expect(f, isNotEmpty);
    });
    test('reducedMaxAnimationMs 200 admits a 151 ms span', () {
      final p = _p.copyWith(reducedMaxAnimationMs: 200);
      expect(checkReducedMotion(const [AnimationSpan(0, 151)], p), isEmpty);
    });
  });
}
