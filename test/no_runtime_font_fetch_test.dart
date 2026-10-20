// The app is local-first and PRIVACY.md says so. google_fonts resolves a
// missing family over HTTP to fonts.gstatic.com on first launch — before the
// user has seen the consent screen. Both families are bundled instead; these
// tests fail if that regresses.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('no source file imports google_fonts', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.readAsStringSync().contains("package:google_fonts/")) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'bundle the family under assets/fonts/ instead');
  });

  test('google_fonts is not a dependency', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    expect((pubspec['dependencies'] as Map).containsKey('google_fonts'), isFalse);
  });

  test('every family the type scale uses is bundled', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    final families = <String>{
      for (final f in (pubspec['flutter']['fonts'] as YamlList))
        (f as Map)['family'] as String
    };
    expect(families, containsAll(<String>['Outfit', 'Manrope']));

    for (final f in (pubspec['flutter']['fonts'] as YamlList)) {
      for (final a in ((f as Map)['fonts'] as YamlList)) {
        final asset = (a as Map)['asset'] as String;
        expect(File(asset).existsSync(), isTrue, reason: 'missing $asset');
      }
    }
  });
}
