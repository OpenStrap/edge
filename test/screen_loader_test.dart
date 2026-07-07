import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/widgets/screen_loader.dart';

void main() {
  group('ScreenRefreshGate', () {
    test('admits first refresh immediately', () {
      final gate = ScreenRefreshGate();

      expect(gate.tryBegin(), isTrue);
      expect(gate.busy, isTrue);
      expect(gate.queued, isFalse);
    });

    test('queues a refresh that arrives while busy', () {
      final gate = ScreenRefreshGate();

      expect(gate.tryBegin(), isTrue);
      expect(gate.tryBegin(), isFalse);
      expect(gate.busy, isTrue);
      expect(gate.queued, isTrue);
    });

    test('replays exactly one queued refresh when current fetch finishes', () {
      final gate = ScreenRefreshGate();

      expect(gate.tryBegin(), isTrue);
      expect(gate.tryBegin(), isFalse);

      expect(gate.finishAndShouldReplay(), isTrue);
      expect(gate.busy, isFalse);
      expect(gate.queued, isFalse);

      expect(gate.finishAndShouldReplay(), isFalse);
    });
  });
}
