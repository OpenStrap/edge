// Reset-steps guard: a user whose device will not pair must always get steps,
// in their language, and a device without sourced steps must be visibly queued
// for a human. Three states: specific / unverified / noOfficialSite.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/reset_url.dart';

import 'support/pairing_reset_fixtures.dart';

Map<String, dynamic> _arb(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

List<File> _arbs() => Directory('lib/l10n')
    .listSync()
    .whereType<File>()
    .where((f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

/// Null when an unverified [r] for [id] is acceptable: a pinned host exists
/// for the id and the URL is on it.
String? _unverifiedProblem(String id, ResetSteps r) {
  final host = kPinnedOfficialHost[id];
  if (host == null) return 'no pinned host';
  final url = r.officialUrl;
  if (url == null) return 'unverified needs a URL';
  return resetUrlProblem(url, pinnedHost: host);
}

Iterable<BandEntry> _of(ResetKind k) =>
    kBandRegistry.where((e) => e.resetSteps?.kind == k);

/// Every key in every locale must exist AND have non-blank text.
void _expectTexted(Iterable<String> keys) {
  for (final f in _arbs()) {
    final arb = _arb(f);
    final bad = [
      for (final k in keys)
        if (arb[k] is! String || (arb[k] as String).trim().isEmpty) k,
    ];
    expect(bad, isEmpty, reason: '${f.path} missing or blank: $bad');
  }
}

void main() {
  test('locale files are found (positive control for the loops below)', () {
    // WHY: an empty locale list would make every key check vacuous.
    final names = _arbs().map((f) => f.uri.pathSegments.last).toList();
    expect(names, containsAll(<String>[
      'app_en.arb', 'app_de.arb', 'app_es.arb', 'app_fr.arb',
      'app_hi.arb', 'app_ru.arb', 'app_th.arb', 'app_zh.arb',
    ]));
  });

  test('reviewed help links point to the right products', () {
    // WHY: review found a Polar H9/H10 page behind an OH1/Verity Sense entry, a
    // different Xiaomi product's FAQ behind the body-composition scale.
    for (final m in kPinnedOfficialUrl.entries) {
      final e = kBandRegistry.firstWhere((e) => e.id == m.key);
      expect(e.resetSteps?.officialUrl, m.value, reason: m.key);
      expect(Uri.parse(m.value).host, kPinnedOfficialHost[m.key], reason: m.key);
    }
  });

  test('Hindi physical strain is distinct from stress', () {
    // WHY: the comparison table must not label physical strain as stress.
    final hi = _arb(File('lib/l10n/app_hi.arb'));
    expect(hi['capLabelStrain'], 'शारीरिक परिश्रम');
  });

  test('every registry entry declares reset steps', () {
    // WHY: an undeclared device would show a user stuck at pairing nothing.
    final missing = [
      for (final e in kBandRegistry)
        if (e.resetSteps == null) e.id,
    ];
    expect(missing, isEmpty, reason: 'entries without resetSteps: $missing');
  });

  test('WHOOP 5 is device-specific, with step keys', () {
    // WHY: owner-confirmed tap-until-blue reset is the only sourced procedure.
    final r = kWhoopGen5.resetSteps;
    expect(r, isNotNull);
    expect(r!.kind, ResetKind.specific);
    expect(r.keys, isNotEmpty);
  });

  test('a specific procedure has at least one step', () {
    // WHY: a "specific" entry with zero steps shows the user an empty list.
    final specific = _of(ResetKind.specific).toList();
    expect(specific, isNotEmpty, reason: 'positive control: gen5 is specific');
    for (final e in specific) {
      expect(e.resetSteps!.keys, isNotNull, reason: e.id);
      expect(e.resetSteps!.keys, isNotEmpty, reason: '${e.id}: zero steps');
    }
  });

  test('every specific step key has non-blank text in EVERY locale', () {
    // WHY: a missing or "" value renders blank text for that language.
    final keys = [
      for (final e in _of(ResetKind.specific)) ...?e.resetSteps!.keys,
    ];
    expect(keys, isNotEmpty, reason: 'at least WHOOP 5 is specific');
    _expectTexted(keys);
  });

  test('generic fallback keys have non-blank text in EVERY locale', () {
    // WHY: unverified / no-site devices rely on these; a gap strands that user.
    expect(kGenericResetStepKeys, isNotEmpty);
    _expectTexted(kGenericResetStepKeys);
  });

  group('unverified', () {
    test('an unverified entry carries an officialUrl on its pinned host', () {
      // WHY: unsourced steps point at the vendor's own help page, never a
      // search engine or a look-alike host. zero unverified entries is
      // allowed (the goal), so the registry loop may be empty; the fixture
      // controls below prove the check can bite.
      for (final e in _of(ResetKind.unverified)) {
        expect(_unverifiedProblem(e.id, e.resetSteps!), isNull, reason: e.id);
      }
    });

    test('control: the unverified check passes a good fixture and fails bad ones', () {
      // WHY: a fixture, not a real registry entry, is the positive control.
      const good = ResetSteps.unverified(officialUrl: 'https://support.whoop.com/x');
      const search = ResetSteps.unverified(
          officialUrl: 'https://www.google.com/search?q=whoop');
      const other = ResetSteps.unverified(officialUrl: 'https://evil.example/x');
      expect(_unverifiedProblem('gen4', good), isNull);
      expect(_unverifiedProblem('gen4', search), isNotNull);
      expect(_unverifiedProblem('gen4', other), isNotNull);
      expect(_unverifiedProblem('not_in_fixture', good), isNotNull,
          reason: 'no pinned host for the id');
    });

    test('a specific entry that has a URL has it on the pinned host', () {
      // WHY: the optional link on a specific procedure is held to the same rule.
      for (final e in _of(ResetKind.specific)) {
        final url = e.resetSteps!.officialUrl;
        if (url == null) continue;
        expect(resetUrlProblem(url, pinnedHost: kPinnedOfficialHost[e.id] ?? ''),
            isNull, reason: '${e.id}: $url');
      }
      // Positive control that the loop above can bite: WHOOP 4 and 5 share a
      // pinned host and at least the model declares one.
      expect(kPinnedOfficialHost['gen5'], 'www.community.whoop.com');
    });
  });

  group('noOfficialSite', () {
    test('needs a non-blank reason and no URL', () {
      // WHY: "no official site" without a why is a silent gap.
      for (final e in _of(ResetKind.noOfficialSite)) {
        expect(e.resetSteps!.reason?.trim() ?? '', isNotEmpty, reason: e.id);
        expect(e.resetSteps!.officialUrl, isNull, reason: e.id);
      }
      expect(_of(ResetKind.noOfficialSite), isNotEmpty,
          reason: 'positive control: the thermometer is NONE in the research');
    });

    test('the research pins 13 NONE devices', () {
      // WHY: vendor-urls.md lists 13; losing one from the fixture unpins it.
      expect(kResearchNoneDevices, hasLength(13));
    });

    test('the noOfficialSite entries are exactly the research NONE set', () {
      // WHY: a device with a vendor site must not be filed as having none, and
      // a NONE device must not be given an invented link.
      final expected = {
        for (final id in kResearchNoneDevices.values) ?id,
      };
      final actual = {for (final e in _of(ResetKind.noOfficialSite)) e.id};
      expect(expected, {'thermometer'},
          reason: 'only the thermometer is a registry entry on this branch');
      // the generic HR profile has no maker either (no research row).
      expect(actual, {...expected, 'ble_hrs'});
      expect(kBleHrs.resetSteps?.reason, 'Generic Bluetooth heart-rate profile; maker unknown');
    });
  });

  test('fixtures cover the registry exactly (control)', () {
    // WHY: a new registry entry must get a reviewed host or a NONE verdict
    // before it ships; ble_hrs is the research gap, pinned by name.
    final covered = {
      ...kPinnedOfficialHost.keys,
      for (final id in kResearchNoneDevices.values) ?id,
      ...kResearchGapIds,
    };
    expect(covered, {for (final e in kBandRegistry) e.id});
    expect(kPinnedOfficialHost.keys.toSet().intersection(kResearchGapIds), isEmpty);
  });

  group('resetUrlProblem (validator, direct)', () {
    const host = 'support.whoop.com';
    test('accepts an https URL on the pinned host (any case, any path)', () {
      // WHY: positive control; without it every rejection below could be an always-throw.
      expect(
          resetUrlProblem('https://support.whoop.com/hc/en-us/articles/1',
              pinnedHost: host),
          isNull);
      expect(resetUrlProblem('https://SUPPORT.whoop.com/x?language=en_US',
          pinnedHost: host), isNull);
    });

    for (final bad in <String, String>{
      'search engine': 'https://www.google.com/search?q=whoop+pairing',
      'another engine': 'https://duckduckgo.com/?q=whoop',
      'unrelated https host': 'https://evil.example/whoop',
      'plain http': 'http://support.whoop.com/x',
      'pinned host as a subdomain prefix of another site':
          'https://support.whoop.com.evil.example/x',
      'pinned host as a suffix of another host': 'https://evilsupport.whoop.com/x',
      'userinfo trick': 'https://support.whoop.com@evil.example/x',
      'a sibling subdomain': 'https://community.whoop.com/x',
      'no host': 'https:///path',
      'not a URL': 'not a url',
      'empty': '',
    }.entries) {
      test('rejects ${bad.key}', () {
        // WHY: only the reviewed official host may be linked.
        expect(resetUrlProblem(bad.value, pinnedHost: host), isNotNull);
      });
    }
  });

  group('follow-up list', () {
    test('lists exactly the entries whose help is not device-specific', () {
      // WHY: exact membership; an unverified/no-site device must be queued, a
      // specific one must not be. Zero is allowed (no isNotEmpty on the list).
      final ids = kBandRegistry.map((e) => e.id).toSet();
      expect(kPairingFollowUp.where((i) => !ids.contains(i)), isEmpty,
          reason: 'listed ids not in the registry');
      final actual = {
        for (final e in kBandRegistry)
          if (e.resetSteps != null && e.resetSteps!.kind != ResetKind.specific)
            e.id,
      };
      expect(kBandRegistry.every((e) => e.resetSteps != null), isTrue,
          reason: 'every entry must declare reset steps first');
      expect(actual, kPairingFollowUp);
    });
  });
}
