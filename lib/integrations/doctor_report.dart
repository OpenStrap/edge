// Doctor report: a plain PDF health summary built from the local derived
// series. Pure render in [renderDoctorReport]; DB reads in [buildDoctorReport].
// A metric with no days prints "not measured". Nothing is filled or estimated.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/day_label.dart';
import '../data/db.dart';
import '../data/med_store.dart';
import '../sync/reset_gate.dart';

class DoctorMetric {
  const DoctorMetric(this.label, this.unit, this.points, {this.decimals = 0});
  final String label;
  final String unit;

  /// (yyyy-MM-dd, value), oldest first, only days that have a value.
  final List<({String date, double v})> points;
  final int decimals;
}

class DoctorEvent {
  const DoctorEvent(this.date, this.text);
  final String date;
  final String text;
}

class DoctorMed {
  const DoctorMed(this.name, this.dose, this.taken, this.of);
  final String name;
  final String dose;
  final int taken;
  final int of;
}

class DoctorReportData {
  const DoctorReportData({
    required this.from,
    required this.to,
    required this.generated,
    this.age,
    this.sex,
    this.heightCm,
    this.weightKg,
    this.metrics = const [],
    this.events = const [],
    this.meds = const [],
  });
  final String from, to, generated; // yyyy-MM-dd
  final int? age;
  final String? sex;
  final double? heightCm, weightKg;
  final List<DoctorMetric> metrics;
  final List<DoctorEvent> events;
  final List<DoctorMed> meds;
}

// metric_series keys, as pivoted by v_daily in data/db.dart.
const _specs = <(String key, String label, String unit, int dec, double scale)>[
  ('rhr', 'Resting heart rate', 'bpm', 0, 1),
  ('rmssd', 'Overnight HRV (RMSSD)', 'ms', 0, 1),
  ('tst_min', 'Sleep duration', 'h', 1, 1 / 60),
  ('resp_rate', 'Respiratory rate', 'br/min', 1, 1),
  ('spo2', 'Blood oxygen', '%', 0, 1),
  ('skin_temp_z', 'Skin temperature vs baseline', 'z-score', 1, 1),
  ('readiness', 'Readiness', '/100', 0, 1),
  ('strain', 'Strain', '', 1, 1),
  ('steps', 'Steps', '', 0, 1),
];

Future<File> buildDoctorReport({int days = 90, DateTime? now}) async {
  final gen = ResetGate.generation;
  final at = now ?? DateTime.now();
  final to = dayLabelOf(at);
  // Calendar days, not 24 h steps: a DST change must not move the window.
  final from = dayLabelBefore(to, days - 1)!;
  final metrics = <DoctorMetric>[];
  for (final s in _specs) {
    // Own-measured days only: a vendor snapshot is not our measurement.
    final rows = await LocalDb.metricSeries(s.$1, from: from, measuredOnly: true);
    metrics.add(DoctorMetric(s.$2, s.$3, [
      for (final r in rows)
        if ((r['date'] as String).compareTo(to) <= 0)
          (date: r['date'] as String, v: (r['value'] as num).toDouble() * s.$5),
    ], decimals: s.$4));
  }

  Map<String, dynamic> prof = const {};
  try {
    final raw = (await SharedPreferences.getInstance())
        .getString('local_profile_json');
    if (raw != null) prof = (jsonDecode(raw) as Map).cast<String, dynamic>();
  } catch (_) {}

  final events = <DoctorEvent>[];
  for (final r in await LocalDb.metricSeries('irregular_rhythm_flag', from: from, measuredOnly: true)) {
    if ((r['value'] as num) == 1 && (r['date'] as String).compareTo(to) <= 0) {
      events.add(DoctorEvent(r['date'] as String,
          'Irregular heart rhythm screen flagged (overnight pulse timing)'));
    }
  }
  for (final e in await LocalDb.listEcgReadings(
      limit: 500,
      fromTs: localDayStartSec(from),
      toTs: localDayEndSec(to))) {
    final d = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
        (e['start_ts'] as int) * 1000));
    if (d.compareTo(from) < 0 || d.compareTo(to) > 0) continue;
    events.add(DoctorEvent(d, 'ECG reading, band category: ${e['category']}'
        '${e['avg_hr'] != null ? ', avg HR ${e['avg_hr']} bpm' : ''}'));
  }
  events.sort((a, b) => a.date.compareTo(b.date));

  final db = await LocalDb.instance;
  final defs = await MedDb.defs(db);
  final doses = await MedDb.doses(db, from: from, to: to);
  final meds = <DoctorMed>[];
  for (final d in defs) {
    var taken = 0, of = 0;
    for (var i = 0; i < days; i++) {
      final lbl = dayLabelBefore(to, i)!;
      final slots = slotsForDay(
        [d],
        lbl,
        {d.key: doses['${d.key}|$lbl'] ?? const {}},
        now: at,
      );
      final a = adherence(slots);
      taken += a.taken;
      of += a.of;
    }
    meds.add(DoctorMed(d.label, d.doseLabel, taken, of));
  }

  final data = DoctorReportData(
    from: from,
    to: to,
    generated: to,
    age: (prof['age'] as num?)?.round(),
    sex: prof['sex'] as String?,
    heightCm: (prof['height_cm'] as num?)?.toDouble(),
    weightKg: (prof['weight_kg'] as num?)?.toDouble(),
    metrics: metrics,
    events: events,
    meds: meds,
  );
  final bytes = await renderDoctorReport(data);
  // A reset that began while this was built must not leave a copy of the
  // record behind, so refuse before and after the write.
  if (ResetGate.changedSince(gen)) throw StateError('Data was deleted while the report was being built.');
  final file = File('${(await getTemporaryDirectory()).path}/openstrap-report-$to.pdf');
  await file.writeAsBytes(bytes, flush: true);
  if (ResetGate.changedSince(gen)) {
    try {
      await file.delete();
    } catch (_) {}
    throw StateError('Data was deleted while the report was being built.');
  }
  return file;
}

String _fmt(double v, int dec) => v.toStringAsFixed(dec);

double? _mean(Iterable<double> v) =>
    v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

List<String> _row(DoctorMetric m, DoctorReportData d) {
  final p = m.points;
  if (p.isEmpty) {
    return [m.label, 'not measured', '', '', '', '', '', '0'];
  }
  String cut(int days) {
    final lo = dayLabelBefore(d.to, days - 1) ?? d.to;
    final x = _mean([for (final e in p) if (e.date.compareTo(lo) >= 0) e.v]);
    return x == null ? '-' : _fmt(x, m.decimals);
  }

  final vs = [for (final e in p) e.v];
  vs.sort();
  return [
    m.label,
    m.unit,
    cut(7),
    cut(30),
    _fmt(_mean(vs)!, m.decimals),
    _fmt(vs.first, m.decimals),
    _fmt(vs.last, m.decimals),
    '${p.length}',
  ];
}

pw.Widget _chart(DoctorMetric m) {
  final p = m.points;
  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('${m.label} (${m.unit})', style: const pw.TextStyle(fontSize: 9)),
      if (p.length < 2)
        pw.Text('not measured', style: const pw.TextStyle(fontSize: 9))
      else
        pw.SizedBox(
          height: 60,
          child: pw.CustomPaint(
            size: const PdfPoint(500, 60),
            painter: (canvas, size) {
              final lo = p.map((e) => e.v).reduce((a, b) => a < b ? a : b);
              final hi = p.map((e) => e.v).reduce((a, b) => a > b ? a : b);
              final span = hi == lo ? 1.0 : hi - lo;
              final t0 = DateTime.parse(p.first.date).millisecondsSinceEpoch;
              final tSpan = (DateTime.parse(p.last.date).millisecondsSinceEpoch - t0)
                  .clamp(1, 1 << 62);
              canvas
                ..setStrokeColor(PdfColors.grey500)
                ..setLineWidth(0.5)
                ..drawRect(0, 0, size.x, size.y)
                ..strokePath()
                ..setStrokeColor(PdfColors.blue800)
                ..setLineWidth(1);
              for (var i = 0; i < p.length; i++) {
                final x = (DateTime.parse(p[i].date).millisecondsSinceEpoch - t0) /
                    tSpan * size.x;
                final y = (p[i].v - lo) / span * (size.y - 4) + 2;
                i == 0 ? canvas.moveTo(x, y) : canvas.lineTo(x, y);
              }
              canvas.strokePath();
            },
          ),
        ),
      pw.Text(
        p.length < 2
            ? ''
            : 'range ${_fmt(p.map((e) => e.v).reduce((a, b) => a < b ? a : b), m.decimals)}'
                ' to ${_fmt(p.map((e) => e.v).reduce((a, b) => a > b ? a : b), m.decimals)},'
                ' ${p.first.date} to ${p.last.date}',
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
      ),
    ]),
  );
}

Future<Uint8List> renderDoctorReport(DoctorReportData d) async {
  final doc = pw.Document(title: 'Health summary');
  final prof = [
    if (d.age != null) 'age ${d.age}',
    if (d.sex != null) 'sex ${d.sex!.toUpperCase()}',
    if (d.heightCm != null) 'height ${d.heightCm!.round()} cm',
    if (d.weightKg != null) 'weight ${_fmt(d.weightKg!, 1)} kg',
  ];
  const small = pw.TextStyle(fontSize: 9);
  pw.Widget h(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
        child: pw.Text(t,
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      );
  final trend = {'Resting heart rate', 'Overnight HRV (RMSSD)', 'Sleep duration'};
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(36),
    build: (_) => [
      pw.Text('Health summary',
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      pw.Text('Period ${d.from} to ${d.to}. Generated ${d.generated}.', style: small),
      if (prof.isNotEmpty) pw.Text(prof.join(', '), style: small),
      h('Daily measures'),
      pw.TableHelper.fromTextArray(
        headers: ['Metric', 'Unit', '7-day', '30-day', 'Mean', 'Min', 'Max', 'Days'],
        data: [for (final m in d.metrics) _row(m, d)],
        cellStyle: const pw.TextStyle(fontSize: 8),
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellAlignment: pw.Alignment.centerLeft,
      ),
      h('Trends'),
      for (final m in d.metrics)
        if (trend.contains(m.label)) _chart(m),
      h('Flagged events'),
      if (d.events.isEmpty)
        pw.Text('None in this period.', style: small)
      else
        for (final e in d.events) pw.Text('${e.date}  ${e.text}', style: small),
      h('Medications'),
      if (d.meds.isEmpty)
        pw.Text('None recorded.', style: small)
      else
        for (final m in d.meds)
          pw.Text(
            '${m.name}${m.dose.isEmpty ? '' : ', ${m.dose}'}: '
            '${m.of == 0 ? 'no scheduled doses in period' : '${m.taken} of ${m.of} scheduled doses taken'}',
            style: small,
          ),
      pw.SizedBox(height: 16),
      pw.Text(
        'Values come from a consumer wearable. HRV is derived from pulse timing. '
        'This is not a diagnosis.',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      ),
    ],
  ));
  return doc.save();
}
