// CLAIM growing-tail: the oracle rejects a 2 px prefix move, and still reports
// growth below a stable prefix. This catches restoring the blanket exemption.
import 'package:flutter_test/flutter_test.dart';
import '../support/layout_shift/layout_shift.dart';
import '../support/tail_shift.dart';

void main() {
  test('tail growth is scored and cannot excuse prefix movement', () {
    const before = Frame(0, [
      ElementSnapshot(
        id: 'button',
        rect: ShiftRect(0, 0, 100, 20),
        role: ElementRole.control,
      ),
      ElementSnapshot(id: 'tail', rect: ShiftRect(0, 40, 100, 20)),
    ]);
    const grown = Frame(1000, [
      ElementSnapshot(
        id: 'button',
        rect: ShiftRect(0, 0, 100, 20),
        role: ElementRole.control,
      ),
      ElementSnapshot(id: 'tail', rect: ShiftRect(0, 40, 100, 80)),
    ]);
    final cost = checkGrowingTail(
      scenario: const Scenario(
        viewport: ShiftRect(0, 0, 390, 844),
        frames: [before, grown],
      ),
      pending: before,
      tailTop: 40,
      route: 'control',
    );
    expect(cost.prefix.total, 0);
    expect(cost.tail.total, greaterThan(0));
    const moved = Frame(1000, [
      ElementSnapshot(
        id: 'button',
        rect: ShiftRect(0, 2, 100, 20),
        role: ElementRole.control,
      ),
    ]);
    expect(
      () => checkGrowingTail(
        scenario: const Scenario(
          viewport: ShiftRect(0, 0, 390, 844),
          frames: [before, moved],
        ),
        pending: before,
        tailTop: 40,
        route: 'mutation',
      ),
      throwsA(isA<TestFailure>()),
    );
  });
}
