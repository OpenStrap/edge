// The app's type family for widget tests.
//
// `F` sets every style in Outfit (assets/fonts/Outfit). The test harness
// knows no family it is not handed, so without this every glyph measures as
// the harness's block font and a layout test is measuring the wrong text.
// Manrope stays loaded where a test already loads it: it is Outfit's Cyrillic
// fallback.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:openstrap_edge/ui2/theme.dart';

Future<void> loadOutfit() async {
  final loader = FontLoader(F.family);
  for (final f in Directory('assets/fonts/Outfit')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'))) {
    loader.addFont(
        f.readAsBytes().then((b) => ByteData.sublistView(Uint8List.fromList(b))));
  }
  await loader.load();
}
