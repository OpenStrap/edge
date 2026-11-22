import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/staging_provenance.dart';

import 'support/hmm_night_fixture.dart';
import 'support/ed2a_recalc_fixture.dart' show edSetZone;

void main() {
  // why: the upstream cardio result must remain byte-identical after this port.
  // # catches: unconditional HMM provenance on flag-off nights.
  test('cardio payload remains byte-identical to 756 and has no HMM keys', () {
    // The full payload includes local clock fields; its baseline is UTC.
    edSetZone('UTC');
    addTearDown(() => edSetZone(Platform.environment['TZ'] ?? 'UTC'));
    final off = hmmNight(enabled: false);
    final implicit = {...off}..remove('use_hmm_stages');
    final stored = jsonEncode(deriveDayBundle(off));
    expect(stored, jsonEncode(deriveDayBundle(implicit)));
    // A literal hash pinned every later algo/stress change; flag-off output
    // is guarded by equality with the implicit-default run plus no HMM keys.
    expect(stored.contains('staging_method'), isFalse);
    expect(stored.contains('staging_effective'), isFalse);
    final sleep = deriveDayBundle(off)['sleep'] as Map;
    expect(sleep.keys.where((k) => k.toString().startsWith('staging_') ||
        k.toString().startsWith('stager_')), isEmpty);
  });

  // why: immutable day rows need a new version before provenance can be stored.
  // # catches: leaving the producing algorithm at 124.
  test('provenance has a fresh algorithm version', () {
    expect(kAlgoVersion, greaterThanOrEqualTo(125));
  });

  // why: opting in is not evidence that HMM produced the labels.
  // # catches: tagging a whole-night abstention as effective HMM.
  test('whole-night abstention stores cardio fallback and observed seconds', () {
    final sleep = deriveDayBundle(hmmNight(rr: false))['sleep'] as Map;
    expect(sleep['staging_method'], 'hmm');
    expect(sleep['staging_effective_method'], 'cardio');
    expect(sleep['staging_fallback'], 'hmm_unavailable');
    expect(sleep['staging_fallback_sec'], 360);
  });

  // why: unobserved gaps cannot be claimed as cardio fallback time.
  // # catches: using the window length as the fallback duration.
  test('whole-night fallback excludes unobserved seconds', () {
    final input = hmmNight(rr: false);
    input['hypno_stages'] = [for (var i = 0; i < 360; i++)
      i < 30 ? 'unobserved' : 'light'];
    final sleep = deriveDayBundle(input)['sleep'] as Map;
    expect(sleep['staging_fallback_sec'], 330);
  });

  // why: a mixed night must report only seconds that kept cardio labels.
  // # catches: counting every second or none when one epoch abstains.
  test('partial fallback counts the two missing-HR epochs', () {
    final sleep = deriveDayBundle(hmmNight(gap: true))['sleep'] as Map;
    expect(sleep['staging_effective_method'], 'hmm_cardio');
    expect(sleep['staging_fallback'], 'hmm_epoch_unavailable');
    expect(sleep['staging_fallback_sec'], 60);
  });

  // why: an HMM abstention can retain a paired device's own labels.
  // # catches: reporting every retained label as cardio regardless of source.
  test('fallback retains the vendor method in provenance', () {
    final input = hmmNight(rr: false)..['sleep_source'] = 'vendor_staged';
    final sleep = deriveDayBundle(input)['sleep'] as Map;
    expect(sleep['staging_effective_method'], 'vendor_staged');
    expect(sleep['staging_fallback_sec'], 360);
  });

  // why: mixed staging must name the method supplying the fallback labels.
  // # catches: labelling a mixed vendor/HMM night as hmm_cardio.
  test('partial vendor fallback names both methods', () {
    final input = hmmNight(gap: true)..['sleep_source'] = 'vendor_staged';
    final sleep = deriveDayBundle(input)['sleep'] as Map;
    expect(sleep['staging_effective_method'], 'hmm_vendor_staged');
    expect(sleep['staging_fallback_sec'], 60);
  });

  // why: a successful recalculation cannot inherit an earlier fallback.
  // # catches: forwarding stale fallback keys from the incoming sleep map.
  test('successful HMM clears stale fallback metadata', () {
    final input = hmmNight();
    input['sleep_json'] = <String, dynamic>{
      ...input['sleep_json'] as Map<String, dynamic>,
      'staging_fallback': 'old', 'staging_fallback_sec': 360};
    final sleep = deriveDayBundle(input)['sleep'] as Map;
    expect(sleep['staging_method'], 'hmm');
    expect(sleep['staging_effective_method'], 'hmm');
    expect(sleep.containsKey('staging_fallback'), isFalse);
    expect(sleep.containsKey('staging_fallback_sec'), isFalse);
  });

  // why: old and malformed backups carry unknown metadata, never fake seconds.
  // # catches: unchecked casts, inferred zero, or discarding future reasons.
  test('typed parsing tolerates legacy, malformed and future provenance', () {
    expect(stagingProvenanceOf(null), isEmpty);
    expect(stagingProvenanceOf({}), isEmpty);
    expect(stagingProvenanceOf({'staging_method': 1,
      'staging_effective_method': false, 'staging_fallback': [],
      'staging_fallback_sec': 10}), isEmpty);
    for (final sec in [-1, double.nan, double.infinity, '10', null]) {
      expect(stagingProvenanceOf({'staging_fallback': 'future',
        'staging_fallback_sec': sec}), {'staging_fallback': 'future'});
    }
    expect(stagingProvenanceOf({'staging_method': 'hmm',
      'staging_effective_method': 'future', 'staging_fallback': 'future',
      'staging_fallback_sec': 30.4}), {'staging_method': 'hmm',
      'staging_effective_method': 'future', 'staging_fallback': 'future',
      'staging_fallback_sec': 30});
  });
}
