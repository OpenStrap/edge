// The BYOK key must survive a background relaunch on a locked phone.
//
// Two TestFlight reports: "I enter my AI API key, it works for a few minutes,
// then after the phone sleeps and wakes it's gone." The key was written with the
// plugin's default `whenUnlocked` accessibility, and this app is relaunched in
// the background constantly (BGProcessingTask, the BLE restore central) — often
// while the phone is locked, when that item cannot be read. `load()` cached the
// empty read as "no key", so the app asked the user to set one up again.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the keychain: records the options every write asks for, and
/// can be told to behave like a locked device.
class _FakeKeychain {
  final Map<String, String> items = {};
  final List<Map<Object?, Object?>> writeOptions = [];
  bool locked = false;
  bool throwOnRead = false;
  bool throwOnWrite = false;
  bool hangReads = false;
  bool hangWrites = false;

  /// Number of upcoming `write` calls that should fail with the real iOS
  /// errSecDuplicateItem shape, before writes start succeeding again.
  int throwDuplicateOnWriteCount = 0;
  final List<Completer<void>> _hungReads = [];
  final List<Completer<void>> _hungWrites = [];

  /// Reads and writes release SEPARATELY, so a test can land a save while a
  /// read that started before it is still parked inside the plugin — the one
  /// ordering the generation counter has to survive.
  void releaseHung({bool reads = true, bool writes = true}) {
    for (final l in [if (reads) _hungReads, if (writes) _hungWrites]) {
      for (final c in l) {
        if (!c.isCompleted) c.complete();
      }
      l.clear();
    }
  }

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        if (throwOnRead) throw PlatformException(code: 'keychain');
        if (hangReads) {
          final c = Completer<void>();
          _hungReads.add(c);
          await c.future;
        }
        // A locked keychain does not error — it simply returns nothing, which
        // is indistinguishable from "no key" without the marker.
        if (locked) return null;
        return items[args['key'] as String];
      case 'write':
        if (throwOnWrite) throw PlatformException(code: 'keychain');
        if (throwDuplicateOnWriteCount > 0) {
          throwDuplicateOnWriteCount--;
          // The real shape iOS/the plugin surfaces for errSecDuplicateItem —
          // matched by earlier field name in the raw string reported by users:
          // "PlatformException(Unexpected security result code, Code: -25299,
          // Message: The specified item already exists in the keychain.,
          // -25299, null)".
          throw PlatformException(
            code: 'Unexpected security result code',
            message: 'Code: -25299, Message: The specified item already '
                'exists in the keychain.',
            details: -25299,
          );
        }
        if (hangWrites) {
          final c = Completer<void>();
          _hungWrites.add(c);
          await c.future;
        }
        items[args['key'] as String] = args['value'] as String;
        writeOptions.add((args['options'] as Map?) ?? const {});
        return null;
      case 'delete':
        items.remove(args['key'] as String);
        return null;
      case 'containsKey':
        return !locked && items.containsKey(args['key'] as String);
      case 'readAll':
        return locked ? <String, String>{} : items;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late _FakeKeychain keychain;

  setUp(() {
    keychain = _FakeKeychain();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, keychain.handle);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a key is stored so it survives a locked-device relaunch', () async {
    // The accessibility attribute is an Apple-keychain concept, and the plugin
    // picks its option set off defaultTargetPlatform (android under test).
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test', model: 'gpt-4o');

    expect(keychain.writeOptions, isNotEmpty);
    // `first_unlock`, not the plugin default of `unlocked`: readable from the
    // first unlock after boot, which is what a background relaunch needs.
    expect(
      keychain.writeOptions.last['accessibility'],
      'first_unlock',
      reason: 'a whenUnlocked item is unreadable during a locked relaunch',
    );
  });

  test('a locked keychain does not report the key as missing', () async {
    final saved = CoachConfig();
    await saved.save(apiKey: 'sk-test', model: 'gpt-4o');

    // A fresh process — the background relaunch — with the phone locked.
    keychain.locked = true;
    final relaunched = CoachConfig();
    await relaunched.load();

    expect(relaunched.hasKey, isFalse, reason: 'it genuinely could not read it');
    expect(relaunched.keyUnreadable, isTrue,
        reason: 'but it must not be reported as "no key configured"');

    // The user unlocks and opens the app.
    keychain.locked = false;
    await relaunched.refreshKeyOnResume();
    expect(relaunched.apiKey, 'sk-test');
    expect(relaunched.keyUnreadable, isFalse);
  });

  test('a read that throws does not erase a key already in memory', () async {
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test', model: 'gpt-4o');
    expect(cfg.apiKey, 'sk-test');

    keychain.throwOnRead = true;
    await cfg.load();

    expect(cfg.apiKey, 'sk-test',
        reason: 'a failed read says nothing about what is stored');
    expect(cfg.keyUnreadable, isTrue);
  });

  test('no key configured still reads as no key, not as unreadable', () async {
    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.hasKey, isFalse);
    expect(cfg.keyUnreadable, isFalse,
        reason: 'nothing was ever saved — the setup prompt is correct here');
  });

  test('clearing the key clears the marker with it', () async {
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test');
    await cfg.save(apiKey: '');

    keychain.locked = true;
    final relaunched = CoachConfig();
    await relaunched.load();
    expect(relaunched.keyUnreadable, isFalse,
        reason: 'a deleted key must not leave the app claiming one exists');
  });

  test('a key written before the marker existed is upgraded once', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Legacy state: an item in the keychain, no marker in prefs.
    keychain.items['coach_api_key'] = 'sk-legacy';
    SharedPreferences.setMockInitialValues({});

    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.apiKey, 'sk-legacy');
    expect(keychain.writeOptions.length, 1,
        reason: 'rewritten once to carry the new accessibility');
    expect(keychain.writeOptions.single['accessibility'], 'first_unlock');

    // A second load must NOT write again — the Android Keystore is the
    // documented Samsung hang, and it has no business on every startup.
    await cfg.load();
    expect(keychain.writeOptions.length, 1);
  });

  test('a legacy key with no marker survives a LOCKED relaunch', () async {
    // The population this whole fix exists for: a key saved by an older build,
    // so there is no marker beside it, whose first launch on this build is a
    // background relaunch on a locked phone. Concluding "no key" here and never
    // retrying is exactly the old bug.
    keychain.items['coach_api_key'] = 'sk-legacy';
    keychain.locked = true;

    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.hasKey, isFalse);
    expect(cfg.keyUndetermined, isTrue,
        reason: 'nothing is established yet, so the retry must stay armed');

    keychain.locked = false;
    await cfg.refreshKeyOnResume();
    expect(cfg.apiKey, 'sk-legacy');
  });

  test('a legacy key whose read THROWS while locked still retries', () async {
    // iOS reports a locked whenUnlocked item as an error rather than an empty
    // read, which is the legacy item's actual behaviour before it is upgraded.
    keychain.items['coach_api_key'] = 'sk-legacy';
    keychain.throwOnRead = true;

    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.keyUndetermined, isTrue);

    keychain.throwOnRead = false;
    await cfg.refreshKeyOnResume();
    expect(cfg.apiKey, 'sk-legacy');
  });

  test('a foreground read settles "no key" so the retry stops', () async {
    final cfg = CoachConfig();
    await cfg.load(trusted: true);
    expect(cfg.keyUndetermined, isFalse);
    expect(cfg.hasKey, isFalse);
  });

  test('a marker outliving its item is cleared by a foreground read', () async {
    // A device-to-device restore carries SharedPreferences across but not the
    // keychain payload. Without this the app insists forever that a key it
    // cannot produce is still saved, and Retry is the only thing on offer.
    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-test');
    keychain.items.clear(); // restored onto a new device

    await cfg.load(trusted: true);
    expect(cfg.keyUnreadable, isFalse);
    expect(cfg.hasKey, isFalse, reason: 'it really is gone — offer setup');
  });

  test('a hung read leaves the retry armed rather than "no key"', () async {
    final saved = CoachConfig();
    await saved.save(apiKey: 'sk-test');

    // A read that never returns (the Samsung Knox keystore hang the startup
    // path is wrapped in a timeout for — a timeout that cannot cancel the call).
    keychain.hangReads = true;
    final relaunched = CoachConfig();
    unawaited(relaunched.load());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(relaunched.keyUnreadable, isTrue,
        reason: 'the state must be pending BEFORE the read, not after it');
  });

  test('a save during an in-flight load is not clobbered by it', () async {
    keychain.hangReads = true;
    final cfg = CoachConfig();
    unawaited(cfg.load());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    keychain.hangReads = false;
    await cfg.save(apiKey: 'sk-new', model: 'gpt-4o');
    expect(cfg.apiKey, 'sk-new');

    // The stale read finally lands, having started before the save.
    keychain.releaseHung();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cfg.apiKey, 'sk-new',
        reason: 'a read that predates the save must not apply its result');
  });

  // #241 reported `PlatformException(-25299)` and blamed the plugin for adding
  // without checking. It does check (check → update → delete + add). What was
  // ours is this: `load` writes the key back to upgrade its accessibility, and
  // an unawaited startup `load` could have that write in flight while the user
  // saved a new one.
  test('an in-flight upgrade write never puts the old key back', () async {
    // A legacy item: a key in the keychain with no marker beside it, so the
    // next load takes the accessibility-upgrade branch — the WRITE inside
    // `load` that this is about.
    keychain.items['coach_api_key'] = 'sk-old';
    SharedPreferences.setMockInitialValues({'coach_model': 'gpt-4o'});

    final cfg = CoachConfig();
    // The read returns, the generation check passes, and the upgrade write is
    // then in flight — which is the window the generation counter cannot close.
    keychain.hangWrites = true;
    unawaited(cfg.load());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The user pastes a new key right there.
    keychain.hangWrites = false;
    final saving = cfg.save(apiKey: 'sk-new', model: 'gpt-4o');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    keychain.releaseHung();
    await saving;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(keychain.items['coach_api_key'], 'sk-new',
        reason: 'the upgrade write must not resurrect the superseded key');
    expect(cfg.apiKey, 'sk-new');
  });

  // The other half of the same race, and the one the single generation bump
  // could not see: a load that starts DURING a save captures the already-
  // incremented generation, so its check passes — and its read, taken while
  // the write was still inside the plugin, comes back empty. Trusted, that
  // empty is treated as proof there is no key.
  test('a trusted load straddling a save does not erase the key', () async {
    final cfg = CoachConfig();

    // The save's write parks inside the plugin.
    keychain.hangWrites = true;
    final saving = cfg.save(apiKey: 'sk-new', model: 'gpt-4o');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Resume brings the app forward and re-reads the key. It starts here —
    // after the save began — and its read parks too. `locked` so it comes back
    // empty rather than seeing the key the save is about to land.
    keychain.hangReads = true;
    keychain.locked = true;
    final loading = cfg.load(trusted: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The save lands FIRST, completely: key in the keychain, marker true.
    keychain.releaseHung(reads: false);
    await saving;
    expect(cfg.apiKey, 'sk-new');

    // Now the straddling read finally answers, and it answers "nothing".
    keychain.releaseHung();
    await loading;

    expect(cfg.apiKey, 'sk-new',
        reason: 'a read taken before the write landed proves nothing about it');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('coach_api_key_present'), isTrue,
        reason: 'a false marker files a stored key as ABSENT, not unreadable, '
            'and puts the resume retry to sleep with it');
  });

  test('a hung keychain read does not block a save', () async {
    final cfg = CoachConfig();
    keychain.hangReads = true;
    unawaited(cfg.load());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // A keystore read can hang outright. Save has to get through anyway — this
    // is why only the writes are serialized and not the whole of `load`.
    await cfg.save(apiKey: 'sk-new', model: 'gpt-4o').timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('save blocked behind a hung read'),
        );
    expect(cfg.apiKey, 'sk-new');
    keychain.releaseHung();
  });

  test('a keychain that refuses the write does not report success', () async {
    final cfg = CoachConfig();
    keychain.throwOnWrite = true;
    await expectLater(cfg.save(apiKey: 'sk-test'), throwsA(anything));
    expect(cfg.hasKey, isFalse,
        reason: 'memory must not hold a key that was never persisted');
  });

  // A leftover item from a prior install can collide with a fresh Save even
  // though nothing in this Dart process raced itself — Keychain items often
  // outlive an app uninstall, unlike everything else the app stores. Reported
  // live: Save on a fresh install threw exactly this shape and never
  // recovered on retry, because retrying just replayed the same add-over-an-
  // existing-item call.
  test('a stale item colliding with Save is cleared and the write recovers',
      () async {
    keychain.items['coach_api_key'] = 'sk-orphaned-from-a-prior-install';
    keychain.throwDuplicateOnWriteCount = 1;

    final cfg = CoachConfig();
    await cfg.save(apiKey: 'sk-new', model: 'gpt-4o');

    expect(cfg.apiKey, 'sk-new',
        reason: 'the duplicate-item error must not surface as a failed save');
    expect(keychain.items['coach_api_key'], 'sk-new');
  });

  test('a write that keeps refusing as duplicate still reports failure',
      () async {
    keychain.items['coach_api_key'] = 'sk-orphaned';
    // Every write refuses, even the retry after the delete — the recovery
    // must not paper over a keychain that is genuinely stuck.
    keychain.throwDuplicateOnWriteCount = 999;

    final cfg = CoachConfig();
    await expectLater(cfg.save(apiKey: 'sk-new'), throwsA(anything));
    expect(cfg.hasKey, isFalse,
        reason: 'memory must not hold a key that was never persisted');
  });
}
