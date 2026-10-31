import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/platform/tasker_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('openstrap/tasker');
  final now = DateTime.fromMillisecondsSinceEpoch(1_760_000_000_000);

  void mockPeek(Object? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'peek_pending_buzz') return reply;
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
  });

  test('a buzz queued seconds ago is still delivered', () async {
    mockPeek({
      'pattern': 3,
      'requestedAtMs': now.millisecondsSinceEpoch - 30 * 1000,
    });
    final p = await TaskerBridge.peekPendingBuzz();
    expect(p, isNotNull);
    expect(p!.pattern, 3);
    expect(p.isFresh(now), isTrue);
  });

  test('a buzz queued hours ago is stale', () async {
    mockPeek({
      'pattern': 2,
      'requestedAtMs':
          now.millisecondsSinceEpoch - const Duration(hours: 13).inMilliseconds,
    });
    final p = await TaskerBridge.peekPendingBuzz();
    expect(p!.isFresh(now), isFalse);
  });

  test('a flag with no request time (older build) is stale', () async {
    mockPeek({'pattern': 2, 'requestedAtMs': null});
    final p = await TaskerBridge.peekPendingBuzz();
    expect(p!.pattern, 2);
    expect(p.isFresh(now), isFalse);
  });

  test('a request time far in the future is stale', () {
    final p = PendingTaskerBuzz(
      pattern: 2,
      requestedAtMs:
          now.millisecondsSinceEpoch + const Duration(hours: 1).inMilliseconds,
    );
    expect(p.isFresh(now), isFalse);
  });

  test('nothing queued peeks as null', () async {
    mockPeek(null);
    expect(await TaskerBridge.peekPendingBuzz(), isNull);
  });
}
