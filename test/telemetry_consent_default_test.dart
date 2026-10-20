// ZERO COLLECTION BEFORE CONSENT.
//
// Locus's store builds collect nothing, ever. The Firebase SDKs, however,
// auto-collect from process start unless the PLATFORM config says otherwise:
// Analytics logs first_open/session_start, Performance opens app-start and
// network traces, Crashlytics uploads any startup crash. All of that happens
// before Dart has read the user's stored telemetry consent (an async
// SharedPreferences load that is deliberately off the startup critical path),
// so the runtime setters alone were not a gate at all.
//
// Two things are asserted here:
//   1. the native config in BOTH platforms disables auto-collection, and does
//      it with the runtime-overridable "…_enabled = false" keys rather than the
//      permanent "…deactivated" ones (which consent could never re-enable);
//   2. the Dart seam only ever switches collection ON from loaded consent.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/telemetry/telemetry_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platform config: Firebase auto-collection is off by default', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    /// The Info.plist value immediately following [key].
    String? plistValueAfter(String key) {
      final i = plist.indexOf('<key>$key</key>');
      if (i < 0) return null;
      final rest = plist.substring(i + '<key>$key</key>'.length);
      final m = RegExp(r'<(true|false|string|integer)\s*/?>').firstMatch(rest);
      return m?.group(1);
    }

    for (final key in const [
      'FIREBASE_ANALYTICS_COLLECTION_ENABLED',
      'FirebaseCrashlyticsCollectionEnabled',
      'firebase_performance_collection_enabled',
    ]) {
      test('Info.plist sets $key to false', () {
        expect(plistValueAfter(key), 'false',
            reason: 'iOS would auto-collect before consent exists');
      });
    }

    test('Info.plist does not use the PERMANENT deactivation keys', () {
      // Those cannot be re-enabled at runtime, which would break the opt-in
      // path entirely rather than gate it.
      expect(plist, isNot(contains('FIREBASE_ANALYTICS_COLLECTION_DEACTIVATED')));
      expect(plist,
          isNot(contains('firebase_performance_collection_deactivated')));
    });

    for (final key in const [
      'firebase_analytics_collection_enabled',
      'firebase_crashlytics_collection_enabled',
      'firebase_performance_collection_enabled',
    ]) {
      test('AndroidManifest sets $key to false', () {
        final m = RegExp(
          '<meta-data\\s+android:name="$key"\\s+android:value="(\\w+)"',
          multiLine: true,
        ).firstMatch(manifest);
        expect(m, isNotNull, reason: '$key meta-data missing entirely');
        expect(m!.group(1), 'false',
            reason: 'Android would auto-collect before consent exists');
      });
    }

    test('AndroidManifest does not use firebase_performance_collection_deactivated',
        () {
      expect(manifest,
          isNot(contains('firebase_performance_collection_deactivated')));
    });
  });

  group('TelemetryService consent seam', () {
    final applied = <bool>[];

    setUp(() {
      applied.clear();
      TelemetryService.debugCollectionSink = applied.add;
      TelemetryService.instance.debugResetConsent(); // fresh-install state
    });
    tearDown(() {
      TelemetryService.debugCollectionSink = null;
      TelemetryService.instance.debugResetConsent();
    });

    test('a fresh install starts disabled with consent unresolved', () {
      final t = TelemetryService.instance;
      expect(t.enabled, isFalse);
      expect(t.consentResolved, isFalse);
    });

    test('enforceCollectionOffUntilConsent pushes false to every SDK', () {
      final t = TelemetryService.instance;
      t.enforceCollectionOffUntilConsent(); // what main() calls at startup
      expect(applied, [false]);
      expect(t.enabled, isFalse);
      expect(t.consentResolved, isFalse); // still unresolved — it is not consent
    });

    test('enforceCollectionOffUntilConsent never revokes a loaded opt-in', () {
      final t = TelemetryService.instance;
      t.applyConsent(true);
      applied.clear();
      t.enforceCollectionOffUntilConsent();
      expect(applied, isEmpty);
      expect(t.enabled, isTrue);
    });

    test('applyConsent(false) keeps every SDK off', () {
      final t = TelemetryService.instance;
      applied.clear();
      t.applyConsent(false);
      expect(applied, [false]);
      expect(t.enabled, isFalse);
      expect(t.consentResolved, isTrue);
    });

    test('applyConsent(true) is the ONLY thing that enables collection', () {
      final t = TelemetryService.instance;
      applied.clear();
      t.applyConsent(true);
      expect(applied, [true]);
      expect(t.enabled, isTrue);
      // …and it can be revoked again.
      applied.clear();
      t.applyConsent(false);
      expect(applied, [false]);
      expect(t.enabled, isFalse);
    });

    test('a consent-less session never transmits: flush() is a no-op', () async {
      final t = TelemetryService.instance;
      t.applyConsent(false);
      t.deviceId = 'test-device';
      t.record(kind: 'event', level: 'info', message: 'unit_test_event');
      // No network client is configured in tests; flush must return without
      // attempting anything rather than throwing.
      await expectLater(t.flush(), completes);
      expect(t.enabled, isFalse);
    });
  });
}
