// EcgController over a scripted fake transport: ownership order, the
// guard-before-write rule, subscription before START, single-flight,
// cleanup on every exit exactly once, the one inconclusive retry, save
// before completed, and the stale-link / malformed / link-down exits.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_guard_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_transport.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

LabradorR17 frame({
  required int seq,
  int progress = 3,
  bool presence = true,
  bool s2One = true,
  int s2State = 1,
  int result = 0,
  int liveHr = 70,
  int avgHr = 0,
  int unreadable = 0,
}) {
  final inner = Uint8List(26 + 200);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2B;
  inner[1] = 17;
  v.setUint32(3, seq, Endian.little);
  v.setUint32(7, 1787823700 + seq, Endian.little);
  inner[13] = 2;
  inner[14] = (presence ? 0x08 : 0) | (s2One ? 0x02 : 0);
  inner[15] = result;
  inner[16] = s2State;
  inner[17] = progress;
  inner[18] = unreadable;
  inner[19] = avgHr;
  inner[20] = liveHr;
  v.setUint16(21, 0xffff, Endian.little);
  v.setUint16(24, 100, Endian.little);
  for (var i = 0; i < 100; i++) {
    v.setInt16(26 + 2 * i, i - 50, Endian.little);
  }
  return LabradorR17.parse(inner)!;
}

LabradorR17 terminal({
  required int seq,
  int result = 1,
  int avgHr = 77,
  int liveHr = 78,
  int unreadable = 0,
}) => frame(
  seq: seq,
  progress: 100,
  s2State: 2,
  s2One: false,
  result: result,
  avgHr: avgHr,
  liveHr: liveHr,
  unreadable: unreadable,
);

EcgCommandListResult _ok(List<String> labels) => EcgCommandListResult([
  for (final l in labels) EcgMemberOutcome(l, written: true, succeeded: true),
]);

class FakeTransport implements EcgTransport {
  final calls = <String>[];
  final _events = StreamController<EcgTransportEvent>.broadcast();
  bool ready = true;
  bool maverick = true;
  int gen = 7;
  @override
  String? serial = 'MG-SERIAL';
  EcgLeaseHandle? current;
  int acquired = 0;

  /// Per-list scripted results (null = all succeed).
  EcgCommandListResult? prepareResult;
  EcgCommandListResult? startResult;
  EcgCommandListResult? restartResult;
  EcgCommandListResult? cleanupResult;

  /// Runs INSIDE start()/restart() before they resolve — to emit frames at
  /// the write/response boundary.
  void Function()? duringStart;
  Completer<void>? holdRestart;
  Completer<void>? holdCleanup;
  int syncRequests = 0;

  @override
  bool get isReady => ready;
  @override
  bool get isMaverick => maverick;
  @override
  int get linkGeneration => gen;
  @override
  Stream<EcgTransportEvent> get events => _events.stream;

  void emit(EcgTransportEvent e) => _events.add(e);
  void emitFrame(LabradorR17 r, {int? generation}) =>
      emit(EcgTransportFrame(r, generation ?? gen));

  /// Simulate a link teardown: new generation, lease void, event.
  void dropLink() {
    final old = gen;
    gen++;
    current = null;
    emit(EcgTransportLinkDown(old));
  }

  @override
  EcgLeaseHandle? acquire() {
    if (!ready || current != null) return null;
    acquired++;
    return current = EcgLeaseHandle(Object(), gen);
  }

  @override
  bool leaseValid(EcgLeaseHandle lease) =>
      identical(current, lease) && lease.linkGeneration == gen;

  @override
  void release(EcgLeaseHandle lease) {
    calls.add('release');
    if (identical(current, lease)) current = null;
  }

  @override
  Future<void> cancelHistory(EcgLeaseHandle lease) async =>
      calls.add('cancelHistory');

  @override
  Future<EcgCommandListResult> prepare(
    EcgLeaseHandle lease,
    EcgWrist wrist,
  ) async {
    calls.add('prepare:${wrist.name}');
    return prepareResult ?? _ok(['selectWrist', 'filteredOn', 'rawSaveOn']);
  }

  @override
  Future<EcgCommandListResult> start(EcgLeaseHandle lease) async {
    calls.add('start');
    duringStart?.call();
    return startResult ?? _ok(['abortHistorical', 'generationStart']);
  }

  @override
  Future<EcgCommandListResult> restart(EcgLeaseHandle lease) async {
    calls.add('restart');
    if (holdRestart != null) await holdRestart!.future;
    return restartResult ?? _ok(['abortHistorical', 'generationRestart']);
  }

  @override
  Future<EcgCommandListResult> cleanup(EcgLeaseHandle lease) async {
    calls.add('cleanup');
    if (holdCleanup != null) await holdCleanup!.future;
    if (!leaseValid(lease)) {
      return EcgCommandListResult([
        for (final l in ['generationStop', 'filteredOff', 'rawSaveOff'])
          EcgMemberOutcome(l, written: false, succeeded: false),
      ]);
    }
    return cleanupResult ??
        _ok(['generationStop', 'filteredOff', 'rawSaveOff']);
  }

  @override
  Future<void> requestSync() async {
    calls.add('sync');
    syncRequests++;
  }
}

class Rig {
  final t = FakeTransport();
  final guard = MemoryEcgGuardStore();
  final saved = <(EcgReading, List<EcgAcceptedPacket>)>[];
  final screen = <String>[];
  final phases = <EcgCapturePhase>[];
  bool failSave = false;
  String? busy;
  late final EcgController c;
  var now = 1787823754000;

  Rig({Duration timeout = const Duration(seconds: 120)}) {
    c = EcgController(
      transport: t,
      guard: guard,
      save: (r, p) async {
        if (failSave) throw StateError('disk full');
        saved.add((r, p));
      },
      busyReason: () => busy,
      holdScreen: (o) async => screen.add('hold:$o'),
      releaseScreen: (o) async => screen.add('release:$o'),
      captureTimeout: timeout,
      nowMs: () => now,
    );
    c.addListener(() => phases.add(c.state.phase));
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preconditions', () {
    test(
      'not ready → disconnected; not MG → incompatible; busy → busy',
      () async {
        final r = Rig();
        r.t.ready = false;
        await r.c.begin(EcgWrist.right);
        expect(r.c.state.phase, EcgCapturePhase.disconnected);
        r.t.ready = true;
        r.t.maverick = false;
        await r.c.begin(EcgWrist.right);
        expect(r.c.state.phase, EcgCapturePhase.incompatible);
        r.t.maverick = true;
        r.busy = 'workout';
        await r.c.begin(EcgWrist.right);
        expect(r.c.state.phase, EcgCapturePhase.busy);
        expect(r.c.state.reason, 'workout');
        expect(r.t.calls, isEmpty, reason: 'nothing touched the band');
        expect(r.guard.log, isEmpty);
      },
    );

    test('a leased transport (recovery or another owner) is busy', () async {
      final r = Rig();
      r.t.current = EcgLeaseHandle(Object(), r.t.gen);
      await r.c.begin(EcgWrist.left);
      expect(r.c.state.phase, EcgCapturePhase.busy);
      expect(r.c.state.reason, 'transport');
    });
  });

  group('the successful reading', () {
    test('order: cancelHistory → guard set → prepare → start; save before '
        'cleanup; completed only after cleanup; then sync', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.waiting);
      expect(r.t.calls, ['cancelHistory', 'prepare:right', 'start']);
      expect(r.guard.log, ['set:MG-SERIAL']);
      expect(r.guard.wrists['MG-SERIAL'], EcgWrist.right);
      expect(r.screen, ['hold:ecg']);
      expect(r.c.isCapturing, isTrue);

      r.t.emitFrame(frame(seq: 1, presence: false, progress: 0));
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.waiting);
      expect(
        r.c.live.length,
        100,
        reason: 'the preview shows real samples pre-contact',
      );

      r.t.emitFrame(frame(seq: 2, progress: 3, liveHr: 71));
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.active);
      expect(r.c.state.progress, 3);
      expect(r.c.state.liveHr, 71);
      r.t.emitFrame(frame(seq: 3, progress: 50));
      r.t.emitFrame(terminal(seq: 4, avgHr: 77));
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.completed);
      expect(r.saved, hasLength(1));
      final (reading, packets) = r.saved.single;
      expect(packets.map((p) => p.sequence), [2, 3, 4]);
      expect(reading.category, EcgCategory.sinusRhythm);
      expect(reading.status, EcgReadingStatus.completed);
      expect(reading.avgHr, 77);
      expect(reading.sampleCount, 300);
      expect(reading.wrist, EcgWrist.right);
      expect(reading.startTs, 1787823754);
      expect(r.c.state.readingId, reading.id);
      // Save happened, then cleanup, then sync — and cleanup exactly once.
      expect(r.t.calls, [
        'cancelHistory',
        'prepare:right',
        'start',
        'cleanup',
        'release',
        'sync',
      ]);
      expect(r.guard.active, isEmpty, reason: 'cleared after a full cleanup');
      expect(r.screen, ['hold:ecg', 'release:ecg']);
      expect(r.c.isCapturing, isFalse);
      // The completed phase was never shown before saving/cleanup.
      final completedAt = r.phases.indexOf(EcgCapturePhase.completed);
      expect(r.phases.indexOf(EcgCapturePhase.saving), lessThan(completedAt));
      expect(
        r.phases.indexOf(EcgCapturePhase.cleaningUp),
        lessThan(completedAt),
      );
    });

    test('a contact frame delivered during the START write is the first '
        'accepted packet', () async {
      final r = Rig();
      r.t.duringStart = () => r.t.emitFrame(frame(seq: 10, progress: 3));
      await r.c.begin(EcgWrist.left);
      await r.settle();
      expect(r.c.reducerState.accepted.map((p) => p.sequence), [10]);
      expect(r.c.state.phase, EcgCapturePhase.active);
    });

    test(
      'START failing after such a frame discards it and cleans up',
      () async {
        final r = Rig();
        r.t.duringStart = () => r.t.emitFrame(frame(seq: 10, progress: 3));
        r.t.startResult = EcgCommandListResult(const [
          EcgMemberOutcome('abortHistorical', written: true, succeeded: true),
          EcgMemberOutcome('generationStart', written: true, succeeded: false),
        ]);
        await r.c.begin(EcgWrist.left);
        expect(r.c.state.phase, EcgCapturePhase.failed);
        expect(r.c.state.reason, 'start');
        expect(r.saved, isEmpty);
        expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
        expect(r.guard.active, isEmpty);
      },
    );
  });

  group('command-list failures', () {
    test('a failed PREPARE prevents START and cleans up', () async {
      final r = Rig();
      r.t.prepareResult = EcgCommandListResult(const [
        EcgMemberOutcome('selectWrist', written: true, succeeded: true),
        EcgMemberOutcome('filteredOn', written: true, succeeded: false),
        EcgMemberOutcome('rawSaveOn', written: true, succeeded: true),
      ]);
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'prepare');
      expect(r.t.calls, [
        'cancelHistory',
        'prepare:right',
        'cleanup',
        'release',
      ]);
      expect(r.screen, isEmpty, reason: 'the screen hold comes after PREPARE');
    });

    test('an unacknowledged guard write refuses to enable the band', () async {
      final r = Rig();
      r.guard.failWrites = true;
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'guard');
      expect(r.t.calls, ['cancelHistory', 'cleanup', 'release']);
      expect(r.t.calls, isNot(contains('prepare:right')));
    });

    test('a failed cleanup member retains the guard and flags it', () async {
      final r = Rig();
      r.t.cleanupResult = EcgCommandListResult(const [
        EcgMemberOutcome('generationStop', written: true, succeeded: true),
        EcgMemberOutcome('filteredOff', written: true, succeeded: false),
        EcgMemberOutcome('rawSaveOff', written: true, succeeded: true),
      ]);
      await r.c.begin(EcgWrist.right);
      await r.c.cancel();
      expect(r.c.state.phase, EcgCapturePhase.cancelled);
      expect(r.c.state.cleanupIncomplete, isTrue);
      expect(r.guard.active, contains('MG-SERIAL'));
    });
  });

  group('retained guard on begin', () {
    test('runs the cleanup triplet first, then proceeds', () async {
      final r = Rig();
      r.guard.active.add('MG-SERIAL');
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.waiting);
      expect(r.t.calls, ['cleanup', 'cancelHistory', 'prepare:right', 'start']);
      expect(r.guard.log, ['clear:MG-SERIAL', 'set:MG-SERIAL']);
    });

    test('recovery cleanup failing means no PREPARE', () async {
      final r = Rig();
      r.guard.active.add('MG-SERIAL');
      r.t.cleanupResult = EcgCommandListResult(const [
        EcgMemberOutcome('generationStop', written: true, succeeded: false),
        EcgMemberOutcome('filteredOff', written: true, succeeded: true),
        EcgMemberOutcome('rawSaveOff', written: true, succeeded: true),
      ]);
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'recovery');
      expect(r.t.calls, isNot(contains('prepare:right')));
      expect(r.guard.active, contains('MG-SERIAL'));
    });
  });

  group('exits', () {
    test('cancel cleans up exactly once and releases everything', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      await r.c.cancel();
      await r.c.cancel();
      expect(r.c.state.phase, EcgCapturePhase.cancelled);
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.screen, ['hold:ecg', 'release:ecg']);
      expect(r.t.current, isNull);
      expect(r.saved, isEmpty);
    });

    test('app pause is a cancel with its own reason', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      await r.c.onAppPaused();
      expect(r.c.state.phase, EcgCapturePhase.cancelled);
      expect(r.c.state.reason, 'paused');
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
    });

    test('the capture timeout fails and cleans up once', () async {
      final r = Rig(timeout: const Duration(milliseconds: 30));
      await r.c.begin(EcgWrist.right);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'timeout');
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
    });

    test(
      'a malformed R17 during capture fails through the single path',
      () async {
        final r = Rig();
        await r.c.begin(EcgWrist.right);
        r.t.emit(EcgTransportMalformed(r.t.gen, 'r17_parse'));
        await r.settle();
        await r.settle();
        expect(r.c.state.phase, EcgCapturePhase.failed);
        expect(r.c.state.reason, 'malformed');
        expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      },
    );

    test(
      'link loss fails, attempts cleanup (unwritten) and retains the guard',
      () async {
        final r = Rig();
        await r.c.begin(EcgWrist.right);
        r.t.dropLink();
        await r.settle();
        await r.settle();
        expect(r.c.state.phase, EcgCapturePhase.failed);
        expect(r.c.state.reason, 'disconnected');
        expect(r.t.calls, contains('cleanup'));
        expect(
          r.guard.active,
          contains('MG-SERIAL'),
          reason: 'nothing was written; the next READY recovers',
        );
        expect(r.c.state.cleanupIncomplete, isTrue);
      },
    );

    test('frames from an older link generation are ignored', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      r.t.emitFrame(frame(seq: 1, progress: 3), generation: r.t.gen - 1);
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.waiting);
      expect(r.c.reducerState.accepted, isEmpty);
    });

    test('progress 255 fails the reading', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      r.t.emitFrame(frame(seq: 1, progress: 3));
      r.t.emitFrame(frame(seq: 2, progress: 255));
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'progress_255');
    });
  });

  group('restart', () {
    test('several frames during a slow RESTART start ONE list; frames are '
        'dropped meanwhile', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      r.t.holdRestart = Completer<void>();
      r.t.emitFrame(frame(seq: 1, progress: 3));
      r.t.emitFrame(
        frame(seq: 2, progress: 6, s2One: false),
      ); // restart predicate
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.restarting);
      r.t.emitFrame(frame(seq: 3, progress: 6, s2One: false));
      r.t.emitFrame(frame(seq: 4, progress: 6, s2One: false));
      await r.settle();
      expect(r.t.calls.where((c) => c == 'restart'), hasLength(1));
      expect(r.c.reducerState.accepted, isEmpty);
      r.t.holdRestart!.complete();
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.active);
      r.t.emitFrame(frame(seq: 5, progress: 3));
      await r.settle();
      expect(r.c.reducerState.accepted.map((p) => p.sequence), [5]);
    });

    test('cancel during a RESTART wins', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      r.t.holdRestart = Completer<void>();
      r.t.emitFrame(frame(seq: 1, progress: 3));
      r.t.emitFrame(frame(seq: 2, progress: 6, s2One: false));
      await r.settle();
      final cancel = r.c.cancel();
      r.t.holdRestart!.complete();
      await cancel;
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.cancelled);
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
    });

    test('a failed RESTART fails the reading', () async {
      final r = Rig();
      r.t.restartResult = EcgCommandListResult(const [
        EcgMemberOutcome('abortHistorical', written: true, succeeded: true),
        EcgMemberOutcome('generationRestart', written: true, succeeded: false),
      ]);
      await r.c.begin(EcgWrist.right);
      r.t.emitFrame(frame(seq: 1, progress: 3));
      r.t.emitFrame(frame(seq: 2, progress: 6, s2One: false));
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'restart');
    });
  });

  group('terminal outcomes', () {
    test('unreadable: cleanup, mask surfaced, nothing saved', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      r.t.emitFrame(frame(seq: 1, progress: 3));
      r.t.emitFrame(terminal(seq: 2, result: 0, unreadable: 0x03));
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.unreadable);
      expect(r.c.state.unreadableMask, 0x03);
      expect(r.saved, isEmpty);
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.t.syncRequests, 0);
    });

    test(
      'first inconclusive offers one retry; the retry persists inconclusive',
      () async {
        final r = Rig();
        await r.c.begin(EcgWrist.right);
        r.t.emitFrame(frame(seq: 1, progress: 3));
        r.t.emitFrame(terminal(seq: 2, result: 6));
        await r.settle();
        await r.settle();
        expect(r.c.state.phase, EcgCapturePhase.inconclusiveRetry);
        expect(r.saved, isEmpty);
        expect(r.c.isCapturing, isFalse);
        await r.c.retry();
        expect(r.c.state.phase, EcgCapturePhase.waiting);
        expect(r.t.calls.where((c) => c == 'prepare:right'), hasLength(2));
        r.t.emitFrame(frame(seq: 3, progress: 3));
        r.t.emitFrame(terminal(seq: 4, result: 6));
        await r.settle();
        await r.settle();
        expect(r.c.state.phase, EcgCapturePhase.completed);
        expect(r.saved.single.$1.status, EcgReadingStatus.inconclusive);
        // No third attempt is offered.
        await r.c.retry();
        expect(r.t.calls.where((c) => c == 'prepare:right'), hasLength(2));
      },
    );

    test('a save failure never shows completed', () async {
      final r = Rig()..failSave = true;
      await r.c.begin(EcgWrist.right);
      r.t.emitFrame(frame(seq: 1, progress: 3));
      r.t.emitFrame(terminal(seq: 2));
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'save');
      expect(r.phases, isNot(contains(EcgCapturePhase.completed)));
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.t.syncRequests, 0);
    });
  });

  group('single flight', () {
    test('a second begin while capturing is ignored', () async {
      final r = Rig();
      await r.c.begin(EcgWrist.right);
      await r.c.begin(EcgWrist.left);
      expect(r.t.acquired, 1);
      expect(r.t.calls.where((c) => c.startsWith('prepare')), hasLength(1));
      expect(r.c.state.wrist, EcgWrist.right);
    });
  });
}
