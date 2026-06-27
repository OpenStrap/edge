// noop_import.dart — import a NOOP raw-sensor CSV export into the local store.
//
// The NOOP export is LONG-FORMAT raw 1 Hz: one row per decoded sample, with a
// `stream` discriminator (hr / rr / gravity / spo2 / skintemp / resp / event) and
// only that stream's columns filled. Header (line 4):
//   unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter,
//   ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,event_kind,event_payload
//
// Because this is RAW 1 Hz — the SAME signal family as our own Substrate — we run
// it through the FULL local pipeline (full-fidelity analytics, identical to a live
// band sync), NOT degraded snapshots.
//
// LARGE FILES: a 90-day export is hundreds of MB / tens of millions of rows, so we
// NEVER load the file or build one big Substrate. We STREAM the file and derive in
// a 2-day sliding window (the day model needs the prior evening for a sleep that
// starts before midnight), writing + freeing each day as we go. Memory stays flat
// (~2 days) regardless of file size.

import 'dart:convert';
import 'dart:io';

import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../compute/substrate.dart';

class NoopImportResult {
  final int days;
  final int rows;
  NoopImportResult(this.days, this.rows);
}

/// One second's worth of the 1 Hz channels (sparse — only set streams present).
class _Sec {
  int? hr;
  double? ax, ay, az;
  int? spo2Red, spo2Ir, skinTemp;
}

/// Documented default column order (used only if the export omits its header).
const Map<String, int> _defaultCols = {
  'unix_s': 0, 'iso_utc': 1, 'stream': 2, 'hr_bpm': 3, 'rr_ms': 4,
  'grav_x': 5, 'grav_y': 6, 'grav_z': 7, 'step_counter': 8, 'ppg_bpm': 9,
  'ppg_conf': 10, 'spo2_red': 11, 'spo2_ir': 12, 'skintemp_raw': 13,
  'resp_raw': 14, 'event_kind': 15, 'event_payload': 16,
};

class NoopImporter {
  /// Stream-import [path] and derive each day at full 1 Hz fidelity via [engine].
  /// [onProgress] reports days written so far. Never loads the whole file.
  static Future<NoopImportResult> importFile(
    String path,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FileSystemException('CSV not found');
    }

    // Rolling buffer: keeps at most the CURRENT + PREVIOUS local date of samples.
    final secs = <int, _Sec>{}; // ts(sec) → channels
    final rrTs = <double>[]; // beat end time (epoch ms)
    final rrMs = <double>[];
    String? curDate;
    var totalRows = 0, daysDone = 0;

    Future<void> deriveAndPrune(String date) async {
      // Build a Substrate from everything buffered (prev + current date) and
      // derive ONLY [date]; calendarDays gives [date] its prior-evening context.
      final sub = _buildSubstrate(secs, rrTs, rrMs);
      final n = await engine.deriveImportedDays(sub, profile, {date});
      daysDone += n;
      onProgress?.call(daysDone);
      // Keep [date]'s samples as the prior evening for the NEXT date; drop older.
      secs.removeWhere((ts, _) => localDateLabel(ts) != date);
      var w = 0;
      for (var i = 0; i < rrMs.length; i++) {
        if (localDateLabel((rrTs[i] / 1000).floor()) == date) {
          rrTs[w] = rrTs[i];
          rrMs[w] = rrMs[i];
          w++;
        }
      }
      rrTs.length = w;
      rrMs.length = w;
    }

    // Column name → index, parsed from the header row. Reading by NAME (not fixed
    // position) means added/reordered columns in a future export don't misparse —
    // as long as the known column names persist. Falls back to the documented
    // default layout if a header is somehow absent.
    var col = _defaultCols;
    int? idx(String name) => col[name];
    String at(List<String> f, String name) {
      final i = idx(name);
      return (i != null && i < f.length) ? f[i] : '';
    }

    final lines =
        file.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('unix_s,')) {
        // Header → (re)build the name→index map and skip.
        final h = line.split(',');
        col = {for (var i = 0; i < h.length; i++) h[i].trim(): i};
        continue;
      }
      final f = line.split(',');
      final ts = int.tryParse(at(f, 'unix_s'));
      if (ts == null) continue;
      final stream = at(f, 'stream');

      final date = localDateLabel(ts);
      // Date advanced → the previous date is complete; derive it from the window.
      if (curDate != null && date != curDate && _after(date, curDate)) {
        await deriveAndPrune(curDate);
      }
      curDate = date;
      totalRows++;

      switch (stream) {
        case 'hr':
          final v = int.tryParse(at(f, 'hr_bpm'));
          if (v != null) (secs[ts] ??= _Sec()).hr = v;
          break;
        case 'rr':
          final v = double.tryParse(at(f, 'rr_ms'));
          if (v != null && v > 0) {
            rrTs.add(ts * 1000.0);
            rrMs.add(v);
          }
          break;
        case 'gravity':
          final s = secs[ts] ??= _Sec();
          s.ax = double.tryParse(at(f, 'grav_x'));
          s.ay = double.tryParse(at(f, 'grav_y'));
          s.az = double.tryParse(at(f, 'grav_z'));
          break;
        case 'spo2':
          final s = secs[ts] ??= _Sec();
          s.spo2Red = int.tryParse(at(f, 'spo2_red'));
          s.spo2Ir = int.tryParse(at(f, 'spo2_ir'));
          break;
        case 'skintemp':
          (secs[ts] ??= _Sec()).skinTemp = int.tryParse(at(f, 'skintemp_raw'));
          break;
        // resp / event / step / ppg: not part of the Substrate — resp rate is
        // derived from RR downstream, so resp_raw is intentionally ignored. An
        // unknown future `stream` value also lands here and is skipped safely.
        default:
          break;
      }
    }
    // EOF — derive the final buffered date.
    if (curDate != null && secs.isNotEmpty) {
      final sub = _buildSubstrate(secs, rrTs, rrMs);
      daysDone += await engine.deriveImportedDays(sub, profile, {curDate});
      onProgress?.call(daysDone);
    }

    await engine.finalizeImport(profile);
    return NoopImportResult(daysDone, totalRows);
  }

  /// Build a Substrate from the buffered seconds + RR beats. Gravity / SpO₂ /
  /// skin-temp are forward-filled across seconds that lack their stream (the real
  /// 1 Hz substrate carries a value every second); HR stays 0 when absent
  /// (off-wrist semantics — meaningful, never forward-filled).
  static Substrate _buildSubstrate(
      Map<int, _Sec> secs, List<double> rrTs, List<double> rrMs) {
    final tsList = secs.keys.toList()..sort();
    final n = tsList.length;
    final tsSec = List<int>.filled(n, 0);
    final hr = List<int>.filled(n, 0);
    final ax = List<double>.filled(n, 0);
    final ay = List<double>.filled(n, 0);
    final az = List<double>.filled(n, 0);
    final spo2Red = List<int>.filled(n, 0);
    final spo2Ir = List<int>.filled(n, 0);
    final skinTemp = List<int>.filled(n, 0);

    double fax = 0, fay = 0, faz = 0; // forward-fill carry
    int fRed = 0, fIr = 0, fTemp = 0;
    for (var i = 0; i < n; i++) {
      final t = tsList[i];
      final s = secs[t]!;
      tsSec[i] = t;
      hr[i] = s.hr ?? 0;
      if (s.ax != null) {
        fax = s.ax!;
        fay = s.ay ?? fay;
        faz = s.az ?? faz;
      }
      ax[i] = fax;
      ay[i] = fay;
      az[i] = faz;
      if (s.spo2Red != null) fRed = s.spo2Red!;
      if (s.spo2Ir != null) fIr = s.spo2Ir!;
      if (s.skinTemp != null) fTemp = s.skinTemp!;
      spo2Red[i] = fRed;
      spo2Ir[i] = fIr;
      skinTemp[i] = fTemp;
    }

    // RR beats sorted by time.
    final order = List<int>.generate(rrMs.length, (i) => i)
      ..sort((a, b) => rrTs[a].compareTo(rrTs[b]));
    return Substrate(
      tsSec: tsSec,
      hr: hr,
      rrTsMs: [for (final i in order) rrTs[i]],
      rrMs: [for (final i in order) rrMs[i]],
      ax: ax,
      ay: ay,
      az: az,
      spo2Red: spo2Red,
      spo2Ir: spo2Ir,
      skinTemp: skinTemp,
    );
  }

  /// String date compare 'YYYY-MM-DD' — true when [a] is strictly after [b].
  static bool _after(String a, String b) => a.compareTo(b) > 0;
}
