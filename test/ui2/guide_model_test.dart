// Guide model: variant selection by band generation. A guide with no variant
// for the user's band must SAY so (GuideNoVariant), not render an empty guide.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import '../support/guide_text.dart';

GuideStep _step(String id) => GuideStep(
      id: id,
      target: GuideTarget.key(ValueKey(id)),
      anchor: GuideTarget.key(ValueKey('anchor-$id')),
      action: GuideAction.tap,
      caption: fnText((_) => id),
    );

GuideVariant _v(String id, [Set<BandGeneration> devices = const {}]) =>
    GuideVariant(devices: devices, steps: [_step(id)]);

Guide _guide(List<GuideVariant> vs) => Guide(id: 'g', title: fnText((_) => 'G'), start: GuideStart.today, variants: vs);

BandGeneration? _unknown;

GuideVariant _found(GuideVariantResult r) => switch (r) {
      GuideVariantFound(:final variant) => variant,
      GuideNoVariant() => fail('expected a variant, got $r'),
    };

void main() {
  group('variantFor', () {
    test('an exact-band variant beats the "any" variant; unknown band gets "any"', () {
      // why: WHOOP 4 and 5 differ in pairing and alarm paths; a WHOOP 5 owner
      // must not be shown the 4 steps just because "any" came first in the list.
      final any = _v('any'), w4 = _v('w4', {BandGeneration.whoop4}), w5 = _v('w5', {BandGeneration.whoop5});
      final g = _guide([any, w4, w5]);
      expect(_found(g.variantFor(BandGeneration.whoop4)), same(w4));
      expect(_found(g.variantFor(BandGeneration.whoop5)), same(w5));
      expect(_found(g.variantFor(_unknown)), same(any));
    });

    test('an "any"-only guide serves every band, known or not', () {
      // why: guide #1 has one path for both bands.
      final any = _v('any');
      final g = _guide([any]);
      for (final b in [BandGeneration.whoop4, BandGeneration.whoop5, _unknown]) {
        expect(_found(g.variantFor(b)), same(any), reason: '$b');
      }
    });

    test('a variant listing both bands serves each', () {
      // why: a Set of devices, not a single one.
      final both = _v('both', {BandGeneration.whoop4, BandGeneration.whoop5});
      final g = _guide([both]);
      expect(_found(g.variantFor(BandGeneration.whoop4)), same(both));
      expect(_found(g.variantFor(BandGeneration.whoop5)), same(both));
    });

    test('no variant for the band: GuideNoVariant names the guide, the band and what IS covered', () {
      // why: "a guide with no variant for the user's band says so" - the Help
      // list needs the reason and the bands to offer instead.
      final g = _guide([_v('w4', {BandGeneration.whoop4})]);
      final r = g.variantFor(BandGeneration.whoop5);
      expect(r, isA<GuideNoVariant>());
      final n = r as GuideNoVariant;
      expect(n.guideId, 'g');
      expect(n.band, BandGeneration.whoop5);
      expect(n.available, {BandGeneration.whoop4});
    });

    test('an unknown band with only band-specific variants is also "no variant"', () {
      // why: guessing a generation would show the wrong steps.
      final g = _guide([_v('w4', {BandGeneration.whoop4})]);
      final r = g.variantFor(_unknown);
      expect(r, isA<GuideNoVariant>());
      expect((r as GuideNoVariant).band, isNull);
    });

    test('a guide with no variants at all is "no variant", never an empty guide', () {
      // why: the empty-list degenerate case.
      final r = _guide(const []).variantFor(BandGeneration.whoop4);
      expect(r, isA<GuideNoVariant>());
      expect((r as GuideNoVariant).available, isEmpty);
    });
  });

  group('GuideStep', () {
    test('keeps its stable id, anchor and extra kept targets', () {
      // why: item 2/1: ids key progress and phase-4 matching and must be the
      // value given, not derived from the (translated) caption; alsoKeep
      // defaults to none and carries step 3's "Your zones".
      final extra = GuideTarget.key(const ValueKey('extra'));
      final plain = _step('open');
      expect(plain.id, 'open');
      expect(plain.alsoKeep, isEmpty);
      final withExtra = GuideStep(
        id: 'set',
          target: GuideTarget.key(const ValueKey('t')),
        anchor: GuideTarget.key(const ValueKey('a')),
        alsoKeep: [extra],
        action: GuideAction.tap,
        caption: fnText((_) => 'c'),
      );
      expect(withExtra.alsoKeep, [extra]);
      expect(withExtra.id, 'set');
    });
  });

  group('Guide.devices', () {
    test('is the union of the variants; "any" covers both generations', () {
      // why: the Help list filters guides by band; an "any" guide must not be
      // hidden from a WHOOP 5 owner.
      expect(_guide([_v('a', {BandGeneration.whoop4})]).devices, {BandGeneration.whoop4});
      expect(_guide([_v('a')]).devices, {BandGeneration.whoop4, BandGeneration.whoop5});
      expect(
        _guide([_v('a', {BandGeneration.whoop4}), _v('b', {BandGeneration.whoop5})]).devices,
        {BandGeneration.whoop4, BandGeneration.whoop5},
      );
      expect(_guide(const []).devices, isEmpty);
    });
  });
}
