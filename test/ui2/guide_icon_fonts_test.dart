// skLoadAppFonts must register the icon fonts, or every review render shows
// hollow "tofu" boxes where icons belong.
//
// why: the guide review renders showed hollow squares for the tap-marker arrow
// and every screen icon, because flutter_test loads no icon font. These tests
// fail if either font stops being registered (Lucide under its package-scoped
// family, MaterialIcons under its bare name).

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/skeleton_fixture.dart';

const _boundaryKey = ValueKey('icon-boundary');

/// Renders [icon] black on white at 48 px and returns its alpha-free luminance
/// mask: one byte per pixel, 0 = background, 255 = ink.
Future<Uint8List> _inkMask(WidgetTester t, IconData icon) async {
  await t.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: _boundaryKey,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: SizedBox(width: 64, height: 64, child: Center(child: Icon(icon, size: 48, color: const Color(0xFF000000)))),
        ),
      ),
    ),
  ));
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
  final bytes = await t.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  });
  final mask = Uint8List(bytes!.length ~/ 4);
  for (var i = 0; i < mask.length; i++) {
    mask[i] = 255 - bytes[i * 4]; // red channel of black-on-white
  }
  return mask;
}

int _inkPixels(Uint8List mask) => mask.where((v) => v > 128).length;

bool _sameMask(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] > 128) != (b[i] > 128)) return false;
  }
  return true;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await skLoadAppFonts();
  });

  // A codepoint no icon font defines: what an unregistered family draws too.
  const missingLucide = IconData(0xF8FFF, fontFamily: 'Lucide', fontPackage: 'lucide_icons_flutter');
  const missingMaterial = IconData(0xF8FFF, fontFamily: 'MaterialIcons');

  testWidgets('Lucide glyphs paint as distinct shapes, not the missing-glyph box', (t) async {
    // why: oracle is the engine's own rendering of a codepoint the font does
    // not have (the tofu box). A registered font draws each icon differently,
    // and none of them like the box.
    final tofu = await _inkMask(t, missingLucide);
    final arrow = await _inkMask(t, LucideIcons.arrowRight);
    final search = await _inkMask(t, LucideIcons.search);
    final heart = await _inkMask(t, LucideIcons.heart);
    for (final (name, mask) in [('arrowRight', arrow), ('search', search), ('heart', heart)]) {
      expect(_inkPixels(mask), greaterThan(30), reason: '$name must paint ink');
      expect(_sameMask(mask, tofu), isFalse, reason: '$name must not equal the missing-glyph box');
    }
    expect(_sameMask(arrow, search), isFalse, reason: 'different icons, different shapes');
    expect(_sameMask(search, heart), isFalse, reason: 'different icons, different shapes');
    expect(_sameMask(arrow, heart), isFalse, reason: 'different icons, different shapes');
  });

  testWidgets('Material icons paint too (MaterialIcons registered by SDK path)', (t) async {
    // why: Switch, Checkbox and back arrows come from MaterialIcons.
    final tofu = await _inkMask(t, missingMaterial);
    final back = await _inkMask(t, Icons.arrow_back);
    final check = await _inkMask(t, Icons.check);
    for (final (name, mask) in [('arrow_back', back), ('check', check)]) {
      expect(_inkPixels(mask), greaterThan(30), reason: '$name must paint ink');
      expect(_sameMask(mask, tofu), isFalse, reason: '$name must not equal the missing-glyph box');
    }
    expect(_sameMask(back, check), isFalse);
  });

  testWidgets('positive control: the probe tells a glyph from an empty canvas', (t) async {
    // why: "a glyph differs from the box" proves nothing if the probe cannot
    // tell renders apart; an all-background mask must differ from a glyph.
    final small = await _inkMask(t, LucideIcons.heart);
    final blank = Uint8List(small.length);
    expect(_sameMask(small, blank), isFalse);
  });
}
