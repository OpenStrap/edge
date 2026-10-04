// The F-Droid recipe swaps lib/telemetry/firebase_bridge.dart and
// lib/scan/barcode_reader.dart and deletes lib/firebase_options.dart, so no
// other file may import firebase, mobile_scanner or firebase_options.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('google-backed imports stay behind the f-droid seams', () {
    const seams = {
      'lib/telemetry/firebase_bridge.dart',
      'lib/scan/barcode_reader.dart',
      'lib/firebase_options.dart',
    };
    final bad = RegExp(r'''import\s+['"](package:(firebase_|mobile_scanner)|.*firebase_options\.dart)''');
    final offenders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            !seams.contains(f.path) &&
            bad.hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
  });
}
