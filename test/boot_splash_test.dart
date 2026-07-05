// BootSplash — the cold-start splash overlay (lib/ui/splash/boot_splash.dart).
//
// In widget tests the video_player platform channel isn't available, so the
// real asset controller can never come up — which is exactly the static-
// fallback path. The behavioral contract under test is the gate logic itself:
// visible while loading, cross-fades out the moment ready flips, safety cap,
// injected-failure fallback, and no-splash-when-already-ready.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'package:openstrap_edge/ui/splash/boot_splash.dart';

const _splash = Key('boot-splash');
const _fallback = Key('boot-splash-fallback');
const _child = Key('under-splash-child');

Widget _host({required bool ready, VideoPlayerController Function()? factory}) {
  return MaterialApp(
    home: BootSplash(
      ready: ready,
      controllerFactory: factory,
      child: const Scaffold(body: Center(child: Text('APP', key: _child))),
    ),
  );
}

void main() {
  testWidgets('splash shows during loading and cross-fades out on ready',
      (tester) async {
    await tester.pumpWidget(_host(ready: false));
    await tester.pump(); // let the (failing-in-test) controller init settle

    // Loading phase: overlay present at full opacity, over the child.
    expect(find.byKey(_splash), findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(find.byKey(_splash)).opacity, 1.0);
    expect(find.byKey(_child), findsOneWidget); // underlay is built

    // Ready flips (route left `loading`) → cross-fade starts immediately.
    await tester.pumpWidget(_host(ready: true));
    expect(tester.widget<AnimatedOpacity>(find.byKey(_splash)).opacity, 0.0);

    // After the fade (+ its small removal delay) the overlay leaves the tree.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(_splash), findsNothing);
    expect(find.byKey(_child), findsOneWidget);
  });

  testWidgets('failed controller init falls back to the static brand surface',
      (tester) async {
    await tester.pumpWidget(_host(
      ready: false,
      factory: () => throw StateError('video unsupported'),
    ));
    await tester.pump();

    // No crash; splash overlay still shown, with the static fallback surface.
    expect(find.byKey(_splash), findsOneWidget);
    expect(find.byKey(_fallback), findsOneWidget);
    expect(find.byKey(const Key('boot-splash-video')), findsNothing);

    // Still dismisses cleanly on ready.
    await tester.pumpWidget(_host(ready: true, factory: () => throw StateError('x')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(_splash), findsNothing);
  });

  testWidgets('safety cap dismisses the splash even if ready never fires',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: BootSplash(
        ready: false,
        maxHold: const Duration(seconds: 2),
        child: const Scaffold(body: Center(child: Text('APP', key: _child))),
      ),
    ));
    await tester.pump();
    expect(find.byKey(_splash), findsOneWidget);

    // Past the cap: fade runs, overlay removed, underlay (what _Gate would
    // show) remains.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(_splash), findsNothing);
    expect(find.byKey(_child), findsOneWidget);
  });

  testWidgets('no splash when the app is already ready at first build',
      (tester) async {
    await tester.pumpWidget(_host(ready: true));
    expect(find.byKey(_splash), findsNothing);
    expect(find.byKey(_child), findsOneWidget);
  });
}
