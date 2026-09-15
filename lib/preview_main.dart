import 'package:flutter/material.dart';

import 'ui2/charts.dart';
import 'ui2/grammar.dart' show Scrubber;

/// A safe, offline UI harness for chart work.
///
/// This entrypoint deliberately does not initialize AppState, BLE, Firebase,
/// WorkManager, notifications, or the production database. It uses the real
/// chart painter and scrubber with deterministic data so the debug APK can be
/// installed beside the production app without pairing or shared state.
void main() => runApp(const EdgePreviewApp());

class EdgePreviewApp extends StatelessWidget {
  const EdgePreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Edge UI Preview',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xff101214),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff70d6ff),
          brightness: Brightness.dark,
        ),
      ),
      home: const ChartPreviewScreen(),
    );
  }
}

class ChartPreviewScreen extends StatefulWidget {
  const ChartPreviewScreen({super.key});

  @override
  State<ChartPreviewScreen> createState() => _ChartPreviewScreenState();
}

class _ChartPreviewScreenState extends State<ChartPreviewScreen> {
  // Deliberately includes a gap so the chart's missing-data behavior is also
  // visible while testing the cursor.
  static const _values = <double?>[
    58,
    61,
    60,
    null,
    63,
    62,
    65,
    64,
    66,
    63,
    67,
    68,
    66,
    69,
  ];
  static const _dates = <String>[
    'Sep 2',
    'Sep 3',
    'Sep 4',
    'Sep 5',
    'Sep 6',
    'Sep 7',
    'Sep 8',
    'Sep 9',
    'Sep 10',
    'Sep 11',
    'Sep 12',
    'Sep 13',
    'Sep 14',
    'Sep 15',
  ];

  double? _selected;

  String _describe(double position) {
    final index = (position * (_values.length - 1)).round();
    final value = _values[index];
    return '${_dates[index]}, ${value == null ? 'no data' : '${value.toStringAsFixed(0)} bpm'}';
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = _selected == null
        ? null
        : (_selected! * (_values.length - 1)).round();
    final selectedValue = selectedIndex == null ? null : _values[selectedIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edge UI Preview'),
        actions: [
          IconButton(
            tooltip: 'Clear selection',
            onPressed: _selected == null
                ? null
                : () => setState(() => _selected = null),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Chart interaction test',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Offline fake data · no Bluetooth pairing · production app untouched',
            style: TextStyle(color: Colors.grey.shade400),
          ),
          const SizedBox(height: 28),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Resting heart rate',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'bpm · 14-day test series',
                    style: TextStyle(color: Colors.grey.shade400),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 220,
                    child: Scrubber(
                      value: _selected,
                      label: 'Resting heart rate chart',
                      describe: _describe,
                      onChanged: (value) => setState(() => _selected = value),
                      child: CustomPaint(
                        painter: LineChart(
                          _values,
                          const Color(0xffff6b7a),
                          fill: true,
                          dots: true,
                          selectedX: _selected,
                          axis: AxisSpec(
                            min: 55,
                            max: 72,
                            ticks: 4,
                            format: (value) => value.toStringAsFixed(0),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text(_dates.first), Text(_dates.last)],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: selectedIndex == null
                  ? const Text('Tap or drag across the chart to select a date.')
                  : Text(
                      '${_dates[selectedIndex]} · ${selectedValue == null ? 'No measurement' : '${selectedValue.toStringAsFixed(0)} bpm'}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
