// Pairing filter for WHOOP 5.0 / MG — the leftover from #238 after the
// transport landed in protocol#27 + edge#97.
//
// The 128-bit vendor service `fd4b0001-cce1-…` is already on main. What was
// never settled is whether a real band puts that UUID in the *primary*
// advertisement or only the scan response. A 128-bit UUID often does not fit
// the 31-byte AD; iOS then hashes it in the overflow area and AccessorySetupKit
// never sees it. The SIG member UUID `0xFD4B` (2 bytes) and the advertised
// local name (`WHOOP MGB…` / `WHOOP 5A…`) are what still fit.
//
// This is not a second codec. Edge still holds no wire-format. These tests pin
// the discovery surface: Dart scan filter, Info.plist, and ASK descriptors.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

String _readRepoFile(String posixPath) {
  final file = File(posixPath.split('/').join(Platform.pathSeparator));
  expect(file.existsSync(), isTrue,
      reason: 'run from the package root; missing $posixPath');
  return file.readAsStringSync();
}

/// The argument text of every `name(...)` call in [source], with nested
/// parentheses balanced — so an argument that itself contains a call
/// (`known: ids.map((i) => i.x)`) does not truncate the result.
Iterable<String> _callArguments(String source, String name) sync* {
  final open = '$name(';
  for (var i = source.indexOf(open);
      i >= 0;
      i = source.indexOf(open, i + open.length)) {
    var depth = 0;
    for (var j = i + open.length - 1; j < source.length; j++) {
      final c = source[j];
      if (c == '(') {
        depth++;
      } else if (c == ')' && --depth == 0) {
        yield source.substring(i + open.length, j);
        break;
      }
    }
  }
}

/// The value of named argument [name] in an argument list, or null when it is
/// absent or is not a bare token. `allowGen4Retry: true && false` deliberately
/// does NOT match — the whole point is to pin the value, not a prefix of it.
String? _namedArgument(String arguments, String name) =>
    RegExp('\\b$name:\\s*(\\w+)\\s*(?:,|\$)')
        .firstMatch(arguments)
        ?.group(1);

void main() {
  group('16-bit member UUID is not the Bluetooth-base expansion', () {
    test('kWhoopMemberUuid16 is the short SIG assignment', () {
      expect(kWhoopMemberUuid16, 'fd4b');
      expect(kWhoopMemberUuid16, isNot('0000fd4b-0000-1000-8000-00805f9b34fb'));
      expect(GattProfile.gen5.service, isNot(startsWith('0000fd4b')));
      expect(GattProfile.gen5.service,
          'fd4b0001-cce1-4033-93ce-002d5875f58a');
    });
  });

  group('advertisementLooksLikeWhoop', () {
    test('matches gen4 and gen5 128-bit vendor prefixes', () {
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: [GattProfile.gen4.service],
        ),
        isTrue,
      );
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: [GattProfile.gen5.service],
        ),
        isTrue,
      );
    });

    test('matches the 16-bit member UUID in both platform spellings', () {
      // iOS reports 16-bit UUIDs short; Android expands them against the base.
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: const ['fd4b'],
        ),
        isTrue,
      );
      expect(
        advertisementLooksLikeWhoop(
          platformName: '',
          serviceUuids: const ['0000fd4b-0000-1000-8000-00805f9b34fb'],
        ),
        isTrue,
      );
    });

    test('matches a WHOOP MG advertised name with no service UUID yet', () {
      // Issue #237: the band shows up as WHOOP MGB… in system Bluetooth.
      expect(
        advertisementLooksLikeWhoop(
          platformName: 'WHOOP MGB1234',
          serviceUuids: const [],
        ),
        isTrue,
      );
    });

    test('rejects a Polar H10 advertising the standard HR service', () {
      expect(
        advertisementLooksLikeWhoop(
          platformName: 'Polar H10',
          serviceUuids: const ['0000180d-0000-1000-8000-00805f9b34fb'],
        ),
        isFalse,
      );
    });
  });

  group('whoopScanServiceUuids', () {
    test('filters on both 128-bit vendors and the 16-bit member UUID', () {
      final uuids = whoopScanServiceUuids().map((g) => g.str.toLowerCase());
      expect(uuids, contains(GattProfile.gen4.service));
      expect(uuids, contains(GattProfile.gen5.service));
      expect(
        uuids.any((u) => u == 'fd4b' || u.startsWith('0000fd4b')),
        isTrue,
        reason: '16-bit 0xFD4B must be its own scan filter — the 128-bit '
            'vendor UUID is a different value and will not match a band that '
            'only advertised the 2-byte form',
      );
    });
  });

  group('iOS ASK / Info.plist stay in lockstep with the Dart filter', () {
    late String plist;
    late String swift;
    late String engine;

    setUpAll(() {
      plist = _readRepoFile('ios/Runner/Info.plist');
      swift = _readRepoFile('ios/Runner/AccessorySetup.swift');
      // M2 §15: scan() moved from ble_engine.dart to transport.dart (a `part
      // of` extension, same library) — the literals this test pins moved
      // with it.
      engine = _readRepoFile('lib/ble/transport.dart');
    });

    test('Info.plist declares the 128-bit vendor service and 16-bit FD4B', () {
      expect(plist, contains('FD4B0001-CCE1-4033-93CE-002D5875F58A'));
      expect(plist, contains('<string>FD4B</string>'));
      // The Bluetooth-base expansion may be named in a comment as the thing
      // we must NOT declare. It must never be an actual ASK service string.
      expect(
        plist,
        isNot(contains('<string>0000FD4B-0000-1000-8000-00805F9B34FB</string>')),
      );
    });

    test('Info.plist declares the WHOOP name net for ASK', () {
      expect(plist, contains('<key>NSAccessorySetupBluetoothNames</key>'));
      expect(plist, contains('<string>WHOOP</string>'));
    });

    test('ASK has a separate 16-bit FD4B descriptor, not AND-combined', () {
      // The 128-bit gen5 vendor UUID is now sourced from Info.plist (generated
      // from kBandRegistry), checked above; this test pins the EXTRA 16-bit
      // fallback item that is layered on top in Swift.
      // A 16-bit CBUUID("FD4B") is its own picker item. Criteria inside one
      // ASDiscoveryDescriptor AND-combine, so folding this onto the 128-bit
      // item would match nothing if the band advertised only one form.
      expect(swift, contains('whoopMemberUUID16'));
      expect(
        swift,
        contains('CBUUID(string: AccessorySetup.whoopMemberUUID16)'),
      );
    });

    test(
        'no bare name-substring descriptor exists — it crashed every '
        '"search for devices" tap once (TestFlight v0.9.29, '
        'A3457926-FD0D-48A7-9C6B-DCC6958276BF)', () {
      // ASDiscoveryDescriptor requires bluetoothServiceUUID whenever
      // bluetoothNameSubstring is set; a name-only descriptor fails ASK's
      // validation with a FATAL, uncatchable trap in
      // -[ASAccessorySession _validateDiscoveryDescriptor:], not a
      // completion-handler error — the gen4-retry-on-rejection logic never
      // even runs. The fallback fix is the member-UUID item covered by the
      // adjacent 'ASK folds gen5's 16-bit member UUID...' test above; this
      // test only guards against the name-only descriptor's crash mode
      // being silently reintroduced. Re-add bluetoothNameSubstring only
      // paired with a bluetoothServiceUUID on the SAME descriptor.
      expect(swift, contains('dropped the name-substring-only fallback'),
          reason:
              'the ponytail comment recording why must survive alongside '
              'the code it explains');
      expect(swift, isNot(contains('bluetoothNameSubstring:')),
          reason: 'a live bluetoothNameSubstring assignment is the exact '
              'crash this test exists to catch');
    });

    test(
        'engine scan filters on the registry service list plus the '
        '16-bit member UUID fallback, not a second hand-written UUID list',
        () {
      expect(engine, contains('for (final e in kFramedBands) Guid(e.service)'));
      expect(engine, contains('Guid(kWhoopMemberUuid16)'));
      expect(engine, contains("s == kWhoopMemberUuid16"));
    });

    test(
        'the widened descriptor list retries once with the Gen 4 item alone '
        'so a rejected experiment can never take down 4.0 pairing', () {
      // The initial picker call must offer the retry, and the retry target
      // must be items[0] — the WHOOP 4.0 (gen4) descriptor built first in
      // `items`, so a rejection of the widened list falls back to exactly
      // what already ships.
      // Matched by shape, not by full line. This assertion has already drifted
      // once — `present` gained a `known:` parameter and the pinned literal
      // stopped guarding anything until the test failed. What matters is the
      // argument the retry hinges on, whatever else rides along. So read the
      // call's balanced argument list and check that one value as a COMPLETE
      // token: a prefix match would accept `true && false`, and a
      // parenthesis-blind scan would break the moment an intervening argument
      // contained a call of its own.
      final presentArgs = _callArguments(swift, 'present').toList();
      final widened =
          presentArgs.where((a) => a.trimLeft().startsWith('items,')).toList();
      final gen4Retry = presentArgs
          .where((a) => a.trimLeft().startsWith('[items[0]],'))
          .toList();
      expect(widened, hasLength(1),
          reason: 'exactly one call presents the widened list');
      expect(gen4Retry, hasLength(1),
          reason: 'the retry must target items[0] — the gen4 descriptor');
      expect(
        _namedArgument(widened.single, 'allowGen4Retry'),
        'true',
        reason: 'the widened list must be presented WITH the Gen 4 retry armed',
      );
      expect(
        _namedArgument(gen4Retry.single, 'allowGen4Retry'),
        'false',
        reason: 'the single-item retry must NOT retry again, or a rejected '
            'list loops',
      );
      // items[0] must be the FIRST registry-driven item (gen4 — kBandRegistry
      // lists it before gen5, see _registry.dart), not the appended gen5-only
      // fallback items (member UUID / name substring).
      final itemsStart = swift.indexOf('var items = services.map');
      expect(itemsStart, greaterThanOrEqualTo(0));
      final fallbackAppendStart = swift.indexOf(
        'items.append(makeItem("WHOOP 5.0 / MG")',
        itemsStart,
      );
      expect(fallbackAppendStart, greaterThan(itemsStart),
          reason: 'the two gen5-only fallback items must be appended AFTER '
              'the registry-driven items, so items[0] stays gen4');
    });

    test(
        'a dismissal of the rejected sheet during the Gen 4 retry is '
        'suppressed, so a provisioned accessory cannot be reported cancelled',
        () {
      expect(swift, contains('retryInFlight'));
      expect(swift, contains('guard !retryInFlight else { return }'));
      expect(swift, contains('self.retryInFlight = true'));
      expect(swift, contains('self.retryInFlight = false'));
    });
  });
}
