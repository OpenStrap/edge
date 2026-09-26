// Pure tests for the two suspension-aware liveness decisions in
// sync_policy.dart. An iOS process suspended between band prompts sees
// minutes of silence on a perfectly healthy link; neither decision may read
// that silence as death.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  const period = Duration(seconds: kKeepAliveIntervalSeconds);

  group('livenessSilence', () {
    test('ticks arriving on cadence: silence is the raw rx gap', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: period,
          tickPeriod: period,
        ),
        const Duration(seconds: 200),
      );
    });

    test('first tick of a session (no previous tick) passes rx through', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: Duration.zero,
          tickPeriod: period,
        ),
        const Duration(seconds: 200),
      );
    });

    test('a tick that missed more than two periods restarts the clock', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(minutes: 15),
          sinceLastTick: const Duration(minutes: 15),
          tickPeriod: period,
        ),
        Duration.zero,
      );
    });

    test('exactly two periods late is still a normal tick', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: period * 2,
          tickPeriod: period,
        ),
        const Duration(seconds: 200),
      );
    });

    test('one microsecond past two periods is a resume', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: period * 2 + const Duration(microseconds: 1),
          tickPeriod: period,
        ),
        Duration.zero,
      );
    });
  });

  group('resumeLinkAction', () {
    test('fresh under the streaming bar → trust', () {
      expect(
        resumeLinkAction(const Duration(seconds: 5), liveStreamArmed: true),
        ResumeLinkAction.trust,
      );
    });
    test('fresh under the no-stream bar → trust', () {
      expect(
        resumeLinkAction(const Duration(seconds: 60), liveStreamArmed: false),
        ResumeLinkAction.trust,
      );
    });
    test('stale with a live stream armed → reconnect (a stream that stopped)',
        () {
      expect(
        resumeLinkAction(const Duration(seconds: 31), liveStreamArmed: true),
        ResumeLinkAction.reconnect,
      );
    });
    test('stale with no stream armed → probe, never guess', () {
      expect(
        resumeLinkAction(const Duration(minutes: 15), liveStreamArmed: false),
        ResumeLinkAction.probe,
      );
    });
    test('agrees with isLinkStale on the trust boundary', () {
      for (final armed in [true, false]) {
        for (var s = 0; s < 200; s += 5) {
          final d = Duration(seconds: s);
          final stale = isLinkStale(d, liveStreamArmed: armed);
          expect(
            resumeLinkAction(d, liveStreamArmed: armed) ==
                ResumeLinkAction.trust,
            !stale,
            reason: 'armed=$armed s=$s',
          );
        }
      }
    });
  });
}
