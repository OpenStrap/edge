// The raw retention policy only ever ran behind `if (scope.fullHistory)` — i.e.
// only on a manual "Re-analyze data". An ordinary install never pruned, and
// `decoded_onehz` + `decoded_rr` grew ~12 MB/day forever. On top of that the
// guard was all-or-nothing: one day stuck `partial` (which `dayResultIds`
// excludes and which is deliberately never finalized by age) latched pruning
// off for every older day too.
//
// Both halves are asserted here: the cutoff decision as a pure function, and
// the CALL SITE, because the whole bug was a call site sitting under the wrong
// `if` while the function it called was perfectly correct.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

import 'support/dart_source.dart';

int _dayStart(String label) {
  final d = DateTime.parse(label);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
}

/// Local midnight of the day [sec] falls in.
int _midnightOf(int sec) {
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
}

void main() {
  group('rawPruneCutoffSec', () {
    // A day stays recomputable until 48 h after its end; the prune must not
    // have reached its derive window (from the previous noon) by the time it
    // finalizes.
    test('a day that has just finalized still has its raw', () {
      final start = _dayStart('2026-05-10');
      final end = _dayStart('2026-05-11');
      final dataNow = end + 48 * 3600 + 1;
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-05-10'],
        finalizedDayIds: const {'2026-05-10'},
      )!;
      expect(cutoff, lessThanOrEqualTo(start));
      expect(DerivationEngine.windowTruncatedByPrune('2026-05-10', cutoff),
          isFalse);
    });

    // A settled install: everything with raw is finalized, so the plain
    // retention window applies.
    test('prunes at the retention edge when every raw day is finalized', () {
      const dataNow = 1780000000;
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-05-01', '2026-05-02', '2026-05-03'],
        finalizedDayIds: const {'2026-05-01', '2026-05-02', '2026-05-03'},
      );
      expect(cutoff, _midnightOf(dataNow - rawRetentionDays * 86400));
    });

    // #450: a mid-day cutoff left the edge day half-pruned, and the next
    // rescan re-derived it from what survived — its breakdown then started
    // wherever the cutoff had been. The cutoff must land on a local midnight.
    test('never splits a day — the cutoff is a local midnight', () {
      final dataNow = _dayStart('2026-05-20') + 9 * 3600 + 47 * 60;
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-05-16', '2026-05-17', '2026-05-20'],
        finalizedDayIds: const {'2026-05-16', '2026-05-17', '2026-05-20'},
      );
      // The raw retention edge falls at 09:47; that day survives whole.
      final edge = dataNow - rawRetentionDays * 86400;
      expect(cutoff, _midnightOf(edge));
      expect(cutoff, isNot(edge));
    });

    test('an unfinalized day holds the cutoff, not off', () {
      // Data edge well past the unfinalized day, so the plain cutoff would
      // otherwise delete it.
      final dataNow = _dayStart('2026-05-20') + 12 * 3600;
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-05-12', '2026-05-15', '2026-05-19'],
        finalizedDayIds: const {'2026-05-12', '2026-05-19'},
      );
      // Held at 05-14 (05-15's night search starts 05-14 noon)…
      expect(cutoff, _dayStart('2026-05-14'));
      // …but older finalized days are still reclaimed. The old guard
      // returned early and kept them too.
      expect(cutoff, greaterThan(_dayStart('2026-05-13')));
    });

    // Day D's night starts the evening before. A day with a result that has
    // not LOCKED yet is still re-derived; cutting D-1's evening first made
    // that re-derive score a half night, overwrite the good row, then lock.
    test('keeps the evening before an unfinalized day with a result', () {
      // Past the plain retention edge for 05-16 and 05-17.
      final dataNow = _dayStart('2026-05-16') +
          (rawRetentionDays + 1) * 86400 +
          21 * 3600;
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-05-14', '2026-05-15', '2026-05-16'],
        // 05-16 has a complete row but never got locked.
        finalizedDayIds: const {'2026-05-14', '2026-05-15'},
      )!;
      final eveningBefore = _dayStart('2026-05-16') - 4 * 3600;
      expect(cutoff, lessThanOrEqualTo(eveningBefore));
      expect(cutoff, _dayStart('2026-05-15'));
    });

    test('the hold is bounded — a permanently stuck day cannot wedge it', () {
      // A day that never completes: `partial` rows are never finalized by
      // age, so this state is reachable and used to be permanent.
      final dataNow = _dayStart('2026-06-30');
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-01-05', '2026-06-29'],
        finalizedDayIds: const {'2026-06-29'},
      )!;
      expect(cutoff, greaterThan(_dayStart('2026-01-05')));
      // Never keeps more than the documented ceiling behind the data edge.
      expect(dataNow - cutoff, lessThanOrEqualTo(7 * 86400));
    });

    test('a day still inside the retention window does not move it', () {
      final dataNow = _dayStart('2026-05-20');
      final cutoff = DerivationEngine.rawPruneCutoffSec(
        dataNowSec: dataNow,
        rawDayIds: const ['2026-05-19'],
        finalizedDayIds: const {},
      );
      // The unfinalized day is newer than the retention edge, so the edge wins.
      expect(cutoff, _midnightOf(dataNow - rawRetentionDays * 86400));
    });

    test('no data edge yet — nothing is pruned', () {
      expect(
        DerivationEngine.rawPruneCutoffSec(
          dataNowSec: 0,
          rawDayIds: const [],
          finalizedDayIds: const {},
        ),
        isNull,
      );
    });
  });

  group('rescanDayIds', () {
    // The midnight cut keeps the oldest day whole but drops the evening half
    // of its night (its derive window starts the previous noon). A rescan of
    // it replaced the full-night result with a truncated one.
    test('skips a day whose derive window reaches below the prune', () {
      final dataNow = _dayStart('2026-05-20') + 9 * 3600 + 47 * 60;
      final days = DerivationEngine.rescanDayIds(
        rawDayIds: const ['2026-05-19', '2026-05-17', '2026-05-18'],
        dataNowSec: dataNow,
        prunedBeforeSec: _dayStart('2026-05-17'),
      );
      expect(days, ['2026-05-18', '2026-05-19']);
    });

    test('never pruned — every recent day is rescanned', () {
      final dataNow = _dayStart('2026-05-20') + 9 * 3600;
      final days = DerivationEngine.rescanDayIds(
        rawDayIds: const ['2026-05-18', '2026-05-17'],
        dataNowSec: dataNow,
      );
      expect(days, ['2026-05-17', '2026-05-18']);
    });

    // A user-set sleep window that starts after the cut has its whole night,
    // so its re-derive must not be declined off the generic previous-noon
    // search window.
    test('a forced sleep window is judged by its own onset', () {
      final cut = _dayStart('2026-05-17');
      expect(DerivationEngine.windowTruncatedByPrune('2026-05-17', cut), isTrue);
      expect(
        DerivationEngine.windowTruncatedByPrune('2026-05-17', cut,
            forcedOnsetSec: cut + 3600),
        isFalse,
      );
      expect(
        DerivationEngine.windowTruncatedByPrune('2026-05-17', cut,
            forcedOnsetSec: cut - 3600),
        isTrue,
      );
    });
  });

  group('the prune call site', () {
    late List<String> lines;

    setUpAll(() {
      lines = codeLines(
        File('lib/compute/derivation_engine.dart').readAsStringSync(),
      );
    });

    test('_pruneOldDecoded runs on the ORDINARY derive path', () {
      final calls = <int>[
        for (var i = 0; i < lines.length; i++)
          if (lines[i].contains('_pruneOldDecoded(')) i,
      ];
      expect(calls, isNotEmpty, reason: 'the raw prune call vanished');

      // Not one of them may be gated on a full restage. Scan back up from the
      // call to the enclosing `if` at a lower indent.
      for (final call in calls) {
        final indent = lines[call].indexOf(RegExp(r'\S'));
        for (var i = call - 1; i >= 0 && i > call - 40; i--) {
          final line = lines[i];
          if (line.trim().isEmpty) continue;
          final at = line.indexOf(RegExp(r'\S'));
          if (at >= indent) continue;
          expect(
            line,
            isNot(contains('fullHistory')),
            reason: 'line ${call + 1}: the raw prune is gated on a full '
                'restage again — an ordinary derive will never prune, and '
                'the substrate grows ~12 MB/day without bound',
          );
          break;
        }
      }
    });

    test('the prune is passed every day that has raw, not the target days', () {
      // `todoDays` is the days THIS pass derives. The day at risk is the one
      // that fell out of the scope while still un-derived, so the guard has to
      // see `scope.rawDays`.
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('_pruneOldDecoded(')) continue;
        if (lines[i].contains('Future<void>')) continue; // the declaration
        expect(lines[i], contains('scope.rawDays'), reason: 'line ${i + 1}');
      }
    });

    test('the prune holds for FINALIZED days, not merely derived ones', () {
      // A day with a complete but unfinalized result still re-derives; if a
      // derived row were enough to release the hold, D-1's evening would be
      // cut and D would re-derive from half a night, then lock.
      final start =
          lines.indexWhere((l) => l.contains('Future<void> _pruneOldDecoded('));
      expect(start, isNot(-1), reason: 'the prune declaration vanished');
      final end = lines.indexWhere((l) => l.startsWith('  }'), start);
      final body = lines.sublist(start, end).join('\n');
      expect(body, contains('LocalDb.finalizedDayIds('));
      expect(body, isNot(contains('dayResultIds')));
    });
  });
}
