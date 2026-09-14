// The pure R17 reducer against every rule of the official foreground state
// machine (docs/mg/05 §4, docs/mg/06 §6), plus a synthetic replay of the
// frozen official capture's shape: 86 transport frames → 30 accepted →
// 3,000 samples, repeated terminal excluded.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

LabradorR17 pkt({
  required int seq,
  int progress = 3,
  bool presence = true,
  bool s2One = true,
  int s2State = 1,
  int result = 0,
  int liveHr = 70,
  int avgHr = 0,
  int unreadable = 0,
  int samples = 100,
  bool transition = false,
}) {
  final inner = Uint8List(26 + 2 * samples);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2B;
  inner[1] = 17;
  v.setUint32(3, seq, Endian.little);
  v.setUint32(7, 1787823700 + seq, Endian.little);
  inner[13] = 1;
  inner[14] =
      (presence ? 0x08 : 0) | (s2One ? 0x02 : 0) | (transition ? 0x04 : 0);
  inner[15] = result;
  inner[16] = s2State;
  inner[17] = progress;
  inner[18] = unreadable;
  inner[19] = avgHr;
  inner[20] = liveHr;
  v.setUint16(21, 0xffff, Endian.little);
  v.setUint16(24, samples, Endian.little);
  for (var i = 0; i < samples; i++) {
    v.setInt16(26 + 2 * i, seq, Endian.little);
  }
  return LabradorR17.parse(inner)!;
}

LabradorR17 terminal({
  required int seq,
  int result = 1,
  int avgHr = 77,
  int liveHr = 78,
  int unreadable = 0,
}) => pkt(
  seq: seq,
  progress: 100,
  s2State: 2,
  s2One: false,
  transition: true,
  result: result,
  avgHr: avgHr,
  liveHr: liveHr,
  unreadable: unreadable,
);

/// Run [frames] from a fresh state; return the final state and every effect.
(EcgReducerState, List<EcgEffect>) run(
  List<LabradorR17> frames, {
  int retriesUsed = 0,
}) {
  var s = EcgReducerState.initial(retriesUsed: retriesUsed);
  final effects = <EcgEffect>[];
  for (final f in frames) {
    final step = reduceEcg(s, f);
    s = step.state;
    effects.addAll(step.effects);
  }
  return (s, effects);
}

List<int> seqs(EcgReducerState s) => s.accepted.map((p) => p.sequence).toList();

void main() {
  group('WAITING', () {
    test('pre-contact frames are ignored: no presence, zero progress, 255', () {
      final (s, e) = run([
        pkt(seq: 1, presence: false, progress: 0),
        pkt(seq: 2, presence: true, progress: 0),
        pkt(seq: 3, presence: false, progress: 5),
        pkt(seq: 4, presence: true, progress: 255),
      ]);
      expect(s.phase, EcgPhase.waiting);
      expect(s.accepted, isEmpty);
      expect(e, isEmpty);
    });

    test('the first presence + positive non-255 progress frame opens the '
        'window and enters ACTIVE', () {
      final (s, e) = run([pkt(seq: 9, progress: 3)]);
      expect(s.phase, EcgPhase.active);
      expect(seqs(s), [9]);
      expect(s.previous?.sequence, 9);
      expect(e, [isA<EcgClear>(), isA<EcgAppend>()]);
    });
  });

  group('ACTIVE accumulation and terminal', () {
    test('ordinary frames append while the current-S2-state-1 flag is set', () {
      final (s, _) = run([
        pkt(seq: 1),
        pkt(seq: 2, progress: 6),
        pkt(seq: 3, progress: 9),
      ]);
      expect(seqs(s), [1, 2, 3]);
      expect(s.interruptions, 0);
    });

    test(
      'progress 100 or S2 state 2 is terminal; the terminal frame is '
      'appended; the persisted category uses AVERAGE HR, the live one LIVE HR',
      () {
        final (s, e) = run([
          pkt(seq: 1),
          terminal(seq: 2, avgHr: 120, liveHr: 78, result: 1),
        ]);
        expect(s.phase, EcgPhase.done);
        expect(seqs(s), [1, 2]);
        final t = e.whereType<EcgTerminal>().single.outcome;
        expect(
          t.kind,
          EcgTerminalKind.completed,
          reason: 'the LIVE branch (78 bpm) completes',
        );
        expect(t.liveCategory, EcgCategory.sinusRhythm);
        expect(
          t.persistedCategory,
          EcgCategory.unreadable,
          reason:
              'result 1 at an average of 120 bpm is out of range — the '
              'stored category says so, exactly like the official row',
        );
        expect(t.averageHr, 120);
        expect(t.liveHr, 78);
      },
    );

    test(
      'a live-unreadable terminal (live HR out of range) clears the window',
      () {
        final (s, e) = run([
          pkt(seq: 1),
          terminal(seq: 2, avgHr: 77, liveHr: 120, result: 1),
        ]);
        expect(s.accepted, isEmpty);
        expect(
          e.whereType<EcgTerminal>().single.outcome.kind,
          EcgTerminalKind.unreadable,
        );
      },
    );

    test('a completed terminal via S2 state 2 with progress below 100', () {
      final (s, e) = run([
        pkt(seq: 1),
        pkt(
          seq: 2,
          progress: 96,
          s2State: 2,
          s2One: false,
          result: 1,
          liveHr: 72,
          avgHr: 72,
        ),
      ]);
      expect(s.phase, EcgPhase.done);
      final t = e.whereType<EcgTerminal>().single.outcome;
      expect(t.kind, EcgTerminalKind.completed);
      expect(t.persistedCategory, EcgCategory.sinusRhythm);
      expect(t.liveCategory, EcgCategory.sinusRhythm);
      expect(seqs(s), [1, 2]);
    });

    test('a repeated terminal frame is ignored', () {
      final (s, e) = run([pkt(seq: 1), terminal(seq: 2), terminal(seq: 3)]);
      expect(seqs(s), [1, 2]);
      expect(e.whereType<EcgTerminal>(), hasLength(1));
    });

    test(
      'unreadable terminal: window cleared, mask surfaced, nothing appended',
      () {
        final (s, e) = run([
          pkt(seq: 1),
          terminal(seq: 2, result: 0, unreadable: 0x05),
        ]);
        expect(s.phase, EcgPhase.done);
        expect(s.accepted, isEmpty);
        final t = e.whereType<EcgTerminal>().single.outcome;
        expect(t.kind, EcgTerminalKind.unreadable);
        expect(t.unreadableMask, 0x05);
        expect(e.last, isA<EcgTerminal>());
        expect(e[e.length - 2], isA<EcgClear>());
      },
    );

    test(
      'first-attempt inconclusive offers ONE retry and persists nothing',
      () {
        final (s, e) = run([pkt(seq: 1), terminal(seq: 2, result: 6)]);
        expect(s.accepted, isEmpty);
        expect(
          e.whereType<EcgTerminal>().single.outcome.kind,
          EcgTerminalKind.inconclusiveOfferRetry,
        );
      },
    );

    test(
      'inconclusive on the retry is final and persisted as inconclusive',
      () {
        final (s, e) = run([
          pkt(seq: 1),
          terminal(seq: 2, result: 6),
        ], retriesUsed: 1);
        expect(seqs(s), [1, 2]);
        final t = e.whereType<EcgTerminal>().single.outcome;
        expect(t.kind, EcgTerminalKind.inconclusiveFinal);
        expect(t.persistedCategory, EcgCategory.inconclusive);
      },
    );

    test('progress 255 while active clears and fails', () {
      final (s, e) = run([pkt(seq: 1), pkt(seq: 2, progress: 255)]);
      expect(s.phase, EcgPhase.done);
      expect(s.accepted, isEmpty);
      expect(e.whereType<EcgFail>().single.reason, 'progress_255');
    });
  });

  group('contact loss', () {
    test('missing presence clears the window, counts ONE interruption and '
        'enters CONTACT_LOST', () {
      final (s, e) = run([
        pkt(seq: 1),
        pkt(seq: 2, progress: 6),
        pkt(seq: 3, presence: false, progress: 6),
      ]);
      expect(s.phase, EcgPhase.contactLost);
      expect(s.accepted, isEmpty);
      expect(s.interruptions, 1);
      expect(e.last, isA<EcgClear>());
    });

    test('zero progress and progress regression are losses too', () {
      expect(
        run([pkt(seq: 1, progress: 5), pkt(seq: 2, progress: 0)]).$1.phase,
        EcgPhase.contactLost,
      );
      expect(
        run([pkt(seq: 1, progress: 5), pkt(seq: 2, progress: 4)]).$1.phase,
        EcgPhase.contactLost,
      );
      expect(
        run([pkt(seq: 1, progress: 5), pkt(seq: 2, progress: 5)]).$1.phase,
        EcgPhase.active,
        reason: 'equal progress is nondecreasing',
      );
    });

    test('further bad packets while lost do not add interruptions; recovery '
        'returns to ACTIVE with NO restart', () {
      final (s, e) = run([
        pkt(seq: 1),
        pkt(seq: 2, presence: false),
        pkt(seq: 3, presence: false),
        pkt(seq: 4, progress: 0),
        pkt(seq: 5, progress: 3),
        pkt(seq: 6, progress: 6),
      ]);
      expect(s.phase, EcgPhase.active);
      expect(s.interruptions, 1);
      expect(seqs(s), [
        5,
        6,
      ], reason: 'a fresh window, no placeholder from before the loss');
      expect(e.whereType<EcgSendRestart>(), isEmpty);
    });

    test('the exact three-interruption boundary: the third loss enters '
        'CONTACT_LOST; the next bad packet fails', () {
      final frames = [
        pkt(seq: 1),
        pkt(seq: 2, presence: false), // loss 1
        pkt(seq: 3, progress: 3),
        pkt(seq: 4, presence: false), // loss 2
        pkt(seq: 5, progress: 3),
        pkt(seq: 6, presence: false), // loss 3
      ];
      final (s3, e3) = run(frames);
      expect(s3.phase, EcgPhase.contactLost);
      expect(s3.interruptions, 3);
      expect(
        e3.whereType<EcgFail>(),
        isEmpty,
        reason: 'the transition itself does not fail',
      );
      // A fourth loss AFTER a recovery is also fine to enter lost…
      final (s4, e4) = run([
        ...frames,
        pkt(seq: 7, progress: 3),
        pkt(seq: 8, presence: false),
      ]);
      expect(s4.phase, EcgPhase.contactLost);
      expect(s4.interruptions, 4);
      expect(e4.whereType<EcgFail>(), isEmpty);
      // …but a bad packet while lost with the count at ≥3 fails.
      final (s5, e5) = run([...frames, pkt(seq: 7, presence: false)]);
      expect(s5.phase, EcgPhase.done);
      expect(e5.whereType<EcgFail>().single.reason, 'interruptions');
      // With the count at 2, a bad packet while lost just stays lost.
      final (s6, e6) = run(
        frames.sublist(0, 4) + [pkt(seq: 5, presence: false)],
      );
      expect(s6.phase, EcgPhase.contactLost);
      expect(s6.interruptions, 2);
      expect(e6.whereType<EcgFail>(), isEmpty);
    });

    test('progress 255 while lost fails immediately', () {
      final (s, e) = run([
        pkt(seq: 1),
        pkt(seq: 2, presence: false),
        pkt(seq: 3, progress: 255),
      ]);
      expect(s.phase, EcgPhase.done);
      expect(e.whereType<EcgFail>().single.reason, 'progress_255');
    });

    test(
      'a recovered window that then completes carries the interruption count',
      () {
        final (s, e) = run([
          pkt(seq: 1),
          pkt(seq: 2, presence: false),
          pkt(seq: 3, progress: 3),
          terminal(seq: 4),
        ]);
        expect(s.interruptions, 1);
        expect(seqs(s), [3, 4]);
        expect(
          e.whereType<EcgTerminal>().single.outcome.kind,
          EcgTerminalKind.completed,
        );
      },
    );
  });

  group('explicit RESTART predicate', () {
    test('presence, positive nondecreasing nonterminal progress, S2-state-1 '
        'flag clear → clear the unfinished window and send RESTART', () {
      final (s, e) = run([
        pkt(seq: 1),
        pkt(seq: 2, progress: 6),
        pkt(seq: 3, progress: 6, s2One: false),
      ]);
      expect(s.phase, EcgPhase.active);
      expect(s.accepted, isEmpty);
      expect(s.interruptions, 0, reason: 'not a contact loss');
      expect(e.sublist(e.length - 2), [isA<EcgClear>(), isA<EcgSendRestart>()]);
    });

    test('a short loss / recontact never sends RESTART', () {
      final (_, e) = run([
        pkt(seq: 1),
        pkt(seq: 2, progress: 0),
        pkt(seq: 3, progress: 3),
        pkt(seq: 4, progress: 6),
      ]);
      expect(e.whereType<EcgSendRestart>(), isEmpty);
    });

    test('the S2 flag is not consulted for the FIRST accepted frame', () {
      final (s, _) = run([pkt(seq: 1, s2One: false)]);
      expect(s.phase, EcgPhase.active);
      expect(seqs(s), [1]);
    });
  });

  group('sequence gaps', () {
    test('a jump inserts exactly one empty placeholder at previous + 1', () {
      final (s, e) = run([pkt(seq: 10), pkt(seq: 20, progress: 6)]);
      expect(seqs(s), [10, 11, 20]);
      expect(s.accepted[1].placeholder, isTrue);
      expect(s.accepted[1].samples, isEmpty);
      expect(e.whereType<EcgAppendPlaceholder>().single.sequence, 11);
    });

    test('a jump on the terminal frame is placeholder-then-terminal', () {
      final (s, _) = run([pkt(seq: 10), terminal(seq: 15)]);
      expect(seqs(s), [10, 11, 15]);
    });
  });

  group('official capture shape', () {
    test('86 transport frames → 30 accepted → 3,000 samples, repeated '
        'terminal excluded, no resets', () {
      // 55 pre-contact frames (no presence / zero progress), then 29
      // progressing frames, the terminal, and one repeated terminal.
      final frames = <LabradorR17>[
        for (var i = 0; i < 49; i++)
          pkt(seq: 23940914 + i, presence: false, progress: 0),
        for (var i = 49; i < 55; i++)
          pkt(seq: 23940914 + i, presence: true, progress: 0),
        for (var i = 55; i < 84; i++)
          pkt(seq: 23940914 + i, progress: 3 + ((i - 55) * 97 ~/ 29)),
        terminal(seq: 23940998, avgHr: 77, liveHr: 78),
        terminal(seq: 23940999, avgHr: 77, liveHr: 78),
      ];
      expect(frames, hasLength(86));
      final (s, e) = run(frames);
      expect(s.phase, EcgPhase.done);
      expect(s.accepted, hasLength(30));
      expect(seqs(s).first, 23940969);
      expect(seqs(s).last, 23940998);
      expect(s.accepted.fold<int>(0, (n, p) => n + p.samples.length), 3000);
      expect(s.accepted.any((p) => p.placeholder), isFalse);
      expect(s.interruptions, 0);
      final t = e.whereType<EcgTerminal>().single.outcome;
      expect(t.kind, EcgTerminalKind.completed);
      expect(t.persistedCategory, EcgCategory.sinusRhythm);
      expect(t.averageHr, 77);
      final stats = EcgWindowStats.of(s.accepted);
      expect(stats.sampleCount, 3000);
      expect(stats.missingSegments, 0);
    });
  });
}
