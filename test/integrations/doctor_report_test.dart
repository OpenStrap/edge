import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/integrations/doctor_report.dart';

void main() {
  test('renders a PDF, including a metric with no data', () async {
    final d = DoctorReportData(
      from: '2026-08-24',
      to: '2026-11-21',
      generated: '2026-11-21',
      age: 34,
      sex: 'm',
      metrics: [
        DoctorMetric('Resting heart rate', 'bpm', [
          for (var i = 0; i < 20; i++)
            (date: '2026-11-${(i + 1).toString().padLeft(2, '0')}', v: 55.0 + i % 4),
        ]),
        const DoctorMetric('Blood oxygen', '%', []),
      ],
      events: const [DoctorEvent('2026-11-03', 'ECG reading, band category: sinus')],
      meds: const [DoctorMed('Vitamin D', '1000 IU', 18, 20)],
    );
    final bytes = await renderDoctorReport(d);
    expect(ascii.decode(bytes.sublist(0, 4)), '%PDF');
    expect(bytes.length, greaterThan(1000));
  });
}
