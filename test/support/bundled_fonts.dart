// Same bundled-font approach as test/ui2_sync_alerts_views_test.dart, copied
// rather than imported so this suite stays independent of that file.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

Future<void> loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  for (final entry in {
    'Manrope': 'Manrope',
    '.SF Pro Text': 'Manrope',
    'Barlow Condensed': 'BarlowCondensed',
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final file in Directory('assets/fonts/${entry.value}').listSync().whereType<File>()) {
      if (file.path.endsWith('.ttf')) {
        loader.addFont(file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
      }
    }
    await loader.load();
  }
}
