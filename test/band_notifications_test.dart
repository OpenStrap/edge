import 'dart:async';
// THE STRAP-BUZZ RELAY, RENDERED — and the label it has to derive.
//
// The point of this screen is that the app ships a notification-listener
// permission (AndroidManifest.xml declares BIND_NOTIFICATION_LISTENER_SERVICE)
// with no way to reach the feature it exists for. So the assertions are about
// reachability and honesty rather than pixels: every state has a control or a
// reason, the permission is explained where it is asked for, and the empty app
// list says why it is empty instead of looking broken.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget w, {double scale = 1}) async {
  t.view.physicalSize = Size(390 * 3, 2400 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('the relay screen', () {
    testWidgets('off is one tap from on, and says what it will do', (t) async {
      // Typed + initialized: `var toggled;` tripped
      // prefer_typing_uninitialized_variables, which plain `flutter analyze`
      // treats as fatal — the reason CI went red on a test that passes.
      var toggled = false;
      await _pump(
        t,
        BandNotificationsView(onEnabled: (v) => toggled = v),
      );
      expect(find.text('Buzz on app notifications'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      await t.tap(find.text('Buzz on app notifications'));
      expect(toggled, isTrue);
    });

    testWidgets('on-but-ungranted asks for the permission and says why', (
      t,
    ) async {
      var asked = false;
      await _pump(
        t,
        BandNotificationsView(enabled: true, onGrant: () => asked = true),
      );
      expect(find.text('Grant notification access'), findsOneWidget);
      // The claim that has to be on the same card as the request — and it has
      // to be the TRUE one. The relay keeps the package names locally, so
      // "nothing is stored" was a promise the code did not keep.
      expect(find.textContaining('stay on this phone'), findsOneWidget);
      expect(find.textContaining('nothing leaves it'), findsOneWidget);
      await t.tap(find.text('Grant notification access'));
      expect(asked, isTrue);
    });

    testWidgets('an empty app list states its reason, not a bare emptiness', (
      t,
    ) async {
      await _pump(t, const BandNotificationsView(enabled: true, granted: true));
      expect(find.text('No app has notified you yet'), findsOneWidget);
      expect(find.textContaining('the first time each one notifies'),
          findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('each seen app is a row you can arm, with its package under it',
        (t) async {
      final calls = <(String, bool)>[];
      await _pump(
        t,
        BandNotificationsView(
          enabled: true,
          granted: true,
          apps: const [
            RelayApp('com.whatsapp', on: true),
            RelayApp('org.telegram.messenger'),
          ],
          onApp: (p, v) => calls.add((p, v)),
        ),
      );
      expect(find.text('Whatsapp'), findsOneWidget);
      expect(find.text('com.whatsapp'), findsOneWidget);
      expect(find.text('Buzzes'), findsOneWidget);
      // The count is the one number that says whether this does anything.
      expect(find.text('Apps armed'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      await t.tap(find.text('Messenger'));
      expect(calls, [('org.telegram.messenger', true)]);
    });

    testWidgets('iOS gets a reason, not a dead switch', (t) async {
      await _pump(t, const BandNotificationsView(supported: false));
      expect(find.text('This phone cannot do it'), findsOneWidget);
      expect(find.text('Buzz on app notifications'), findsNothing);
    });

    testWidgets('nothing overflows at 2x text', (t) async {
      await _pump(
        t,
        const BandNotificationsView(
          enabled: true,
          granted: true,
          apps: [
            RelayApp('com.google.android.apps.messaging', on: true),
            RelayApp('com.whatsapp'),
          ],
        ),
        scale: 2,
      );
      expect(t.takeException(), isNull);
    });
  });

  // The picker draws one row per SEEN package, so what falls out of that list
  // is what the user can no longer reach.
  group('the seen list', () {
    test('an armed app is never evicted out of the picker', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(const {});
      final relay =
          NotificationRelay(buzz: () async {}, isConnected: () => false);
      relay.packages.add('com.armed');
      relay.noteSeen('com.armed', null);
      // A week of a chatty phone on top of it. The armed one is now the
      // OLDEST, which is exactly the entry the old cap threw away — leaving an
      // app that still buzzes the strap with no row to turn it off from.
      for (var i = 0; i < NotificationRelay.maxSeen + 20; i++) {
        relay.noteSeen('com.chatty.$i', null);
      }
      expect(relay.seenPackages, contains('com.armed'));
      // And the cap still holds — an unarmed neighbour went instead.
      expect(relay.seenPackages.length, NotificationRelay.maxSeen);
    });

    test('unarmed apps are still capped', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(const {});
      final relay =
          NotificationRelay(buzz: () async {}, isConnected: () => false);
      for (var i = 0; i < NotificationRelay.maxSeen + 20; i++) {
        relay.noteSeen('com.chatty.$i', null);
      }
      expect(relay.seenPackages.length, NotificationRelay.maxSeen);
      expect(relay.seenPackages.first, 'com.chatty.79');
    });
  });

  group('quiet hours', () {
    ServiceNotificationEvent post(String pkg) => ServiceNotificationEvent(
          id: 1,
          title: '',
          canReply: false,
          haveExtraPicture: false,
          hasRemoved: false,
          packageName: pkg,
          content: '',
          onGoing: false,
          timestamp: 0,
          appIcon: null,
          extrasPicture: null,
          largeIcon: null,
        );

    test('a post inside quiet hours does not buzz the strap', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(const {});
      var buzzes = 0;
      final relay = NotificationRelay(
        buzz: () async {
          buzzes++;
        },
        isConnected: () => true,
        quietNow: () async => true,
      );
      relay.packages.add('com.whatsapp');
      relay.debugOnNotification(post('com.whatsapp'));
      await Future<void>.delayed(Duration.zero);
      expect(buzzes, 0);
    });

    test('outside quiet hours it still buzzes', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(const {});
      var buzzes = 0;
      final relay = NotificationRelay(
        buzz: () async {
          buzzes++;
        },
        isConnected: () => true,
        quietNow: () async => false,
      );
      relay.packages.add('com.whatsapp');
      relay.debugOnNotification(post('com.whatsapp'));
      await Future<void>.delayed(Duration.zero);
      expect(buzzes, 1);
    });

    test('an app switched off during the quiet-hours read does not buzz',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(const {});
      var buzzes = 0;
      final read = Completer<bool>();
      final relay = NotificationRelay(
        buzz: () async {
          buzzes++;
        },
        isConnected: () => true,
        quietNow: () => read.future,
      );
      relay.packages.add('com.whatsapp');
      relay.debugOnNotification(post('com.whatsapp'));
      relay.packages.remove('com.whatsapp');
      read.complete(false);
      await Future<void>.delayed(Duration.zero);
      expect(buzzes, 0);
    });

    test('the default reads the app quiet-hours setting', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final t = DateTime.now();
      final m = t.hour * 60 + t.minute;
      // A window covering every minute but the one before now, so now is inside
      // it even if the clock ticks over before the check.
      SharedPreferences.setMockInitialValues({
        'notif_quiet_enabled': true,
        'notif_quiet_start': m,
        'notif_quiet_end': (m + 1439) % 1440,
      });
      var buzzes = 0;
      final relay = NotificationRelay(
        buzz: () async {
          buzzes++;
        },
        isConnected: () => true,
      );
      relay.packages.add('com.whatsapp');
      relay.debugOnNotification(post('com.whatsapp'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(buzzes, 0);
    });
  });

  group('appLabel', () {
    test('takes the last meaningful segment, capitalised', () {
      expect(appLabel('com.whatsapp'), 'Whatsapp');
      expect(appLabel('org.telegram.messenger'), 'Messenger');
      expect(appLabel('com.slack'), 'Slack');
    });

    test('steps over a platform or build segment', () {
      // "Android" under every second icon is not a name.
      expect(appLabel('com.foo.android'), 'Foo');
      expect(appLabel('com.foo.mobile.lite'), 'Foo');
    });

    test('never returns empty, whatever the package looks like', () {
      expect(appLabel('android'), 'Android');
      expect(appLabel('a'), 'A');
      expect(appLabel('com..bar.'), 'Bar');
      expect(appLabel(''), '');
    });
  });
}
