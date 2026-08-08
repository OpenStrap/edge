// Regressions for the crashes reported through Crashlytics against 0.9.21.
//
// Each group pins the exact mechanism that reached production, so a future
// refactor that reintroduces it fails here rather than in the field.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/telemetry/error_classification.dart';
import 'package:openstrap_edge/ui/kit/share_origin.dart';
import 'package:openstrap_edge/ui/timeline/timeline_screen.dart';

void main() {
  group('activityBandExtent (the inverted clamp)', () {
    // The painter used `x1.clamp(x0 + 1, size.width)`. x(t) saturates at
    // size.width, so a band starting in the final pixel made lowerLimit exceed
    // upperLimit and double.clamp threw — reported from JourneyScreen as
    // "Invalid argument(s): 330.7788280945566" (the value IS x0 + 1).
    const w = 330.7788280945566;

    void expectSane(({double left, double right}) e) {
      expect(e.left, lessThanOrEqualTo(e.right),
          reason: 'an inverted rect is the crash');
      expect(e.right, lessThanOrEqualTo(w));
      expect(e.right - e.left, greaterThanOrEqualTo(1.0),
          reason: 'a band must stay visible');
    }

    test('a band starting exactly at the right edge', () {
      expectSane(activityBandExtent(w, w, w));
    });

    test('a band starting within the last pixel', () {
      // The exact production case: x0 = 329.7788, so x0 + 1 > width.
      expectSane(activityBandExtent(w - 0.2, w, w));
    });

    test('a zero-length band mid-plot still gets a visible width', () {
      final e = activityBandExtent(100, 100, w);
      expect(e.right - e.left, 1.0);
    });

    test('an end before its start does not invert', () {
      expectSane(activityBandExtent(200, 100, w));
    });

    test('an ordinary band is left untouched', () {
      final e = activityBandExtent(40, 200, w);
      expect(e.left, 40);
      expect(e.right, 200);
    });

    test('the old expression really did throw on these inputs', () {
      // Pins WHY the function exists: without it, this is the production crash.
      expect(() => w.clamp(w + 1, w), throwsArgumentError);
    });
  });

  group('shareOriginFor', () {
    // iOS 26 rejects a missing origin AND a zero one, so `null` was never a
    // safe fallback — it is the crashing input.
    testWidgets('returns the widget rect when laid out', (tester) async {
      late Rect origin;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          origin = shareOriginFor(context);
          return const SizedBox(width: 100, height: 40);
        }),
      ));
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
    });

    testWidgets('falls back to a non-zero rect with no render box',
        (tester) async {
      late Rect origin;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          // A LayoutBuilder's context has no RenderBox of its own at this point.
          origin = shareOriginFor(context);
          return const SizedBox.shrink();
        }),
      ));
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
      expect(origin, isNot(Rect.zero));
    });
  });

  group('isTransientError', () {
    test('network failures are not crashes', () {
      for (final e in [
        "ClientException with SocketException: Failed host lookup: "
            "'c.basemaps.cartocdn.com' (OS Error: No address associated with "
            'hostname, errno = 7)',
        'SocketException: Network is unreachable (OS Error: Network is '
            'unreachable, errno = 51)',
        'HandshakeException: Connection terminated during handshake',
        'ClientException: Connection closed while receiving data',
      ]) {
        expect(isTransientError(_Err(e)), isTrue, reason: e);
      }
    });

    test('real defects still count as crashes', () {
      expect(isTransientError(ArgumentError('330.77')), isFalse);
      expect(isTransientError(StateError('readiness_absent')), isFalse);
      expect(isTransientError(_Err('Null check operator used on a null value')),
          isFalse);
    });
  });

  group('carryForwardDetail', () {
    // A timed-out second half produced a headline-only bundle, and putDayResult
    // replaces the row wholesale — so re-deriving a complete day destroyed its
    // naps, workouts, HRR, wear and curves.
    test('restores detail blocks the failed pass never produced', () {
      final prev = <String, dynamic>{
        'scalars': {'readiness': 71.0, 'nap_min': 24.0},
        'series': {'rhr': 52.0},
        'naps': [
          {'start': 1, 'end': 2}
        ],
        'sessions': [
          {'sport': 'run'}
        ],
      };
      final next = <String, dynamic>{
        'scalars': {'readiness': 68.0},
        'series': {'rhr': 53.0},
      };

      expect(DerivationEngine.carryForwardDetail(prev, next), isTrue);
      expect(next['naps'], prev['naps']);
      expect(next['sessions'], prev['sessions']);
      // Second-half scalar restored...
      expect((next['scalars'] as Map)['nap_min'], 24.0);
      // ...but the freshly computed headline always wins.
      expect((next['scalars'] as Map)['readiness'], 68.0);
      expect((next['series'] as Map)['rhr'], 53.0);
    });

    test('a deliberate null is absence, not a hole to backfill', () {
      // Isolate 1 succeeded and measured no readiness today. Carrying yesterday's
      // value forward would fabricate a metric — the honesty contract forbids it.
      final prev = <String, dynamic>{
        'scalars': {'readiness': 71.0},
      };
      final next = <String, dynamic>{
        'scalars': {'readiness': null},
      };
      DerivationEngine.carryForwardDetail(prev, next);
      expect((next['scalars'] as Map)['readiness'], isNull);
    });

    test('reports nothing carried when the previous result was no richer', () {
      final prev = <String, dynamic>{
        'scalars': {'readiness': 71.0},
      };
      final next = <String, dynamic>{
        'scalars': {'readiness': 68.0},
      };
      expect(DerivationEngine.carryForwardDetail(prev, next), isFalse);
    });
  });
}

/// Stands in for the platform exception types, which carry their identity in
/// their message the same way `ClientException` does.
class _Err implements Exception {
  final String message;
  const _Err(this.message);
  @override
  String toString() => message;
}
