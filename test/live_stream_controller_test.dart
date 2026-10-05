import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/live_stream_controller.dart';

void main() {
  late bool background;
  late String? workoutType;
  late bool breathing;
  late int nudges;
  late List<(bool, bool)> seen;
  late LiveStreamController controller;

  setUp(() {
    background = false;
    workoutType = null;
    breathing = false;
    nudges = 0;
    seen = [];
    controller = LiveStreamController(
      background: () => background,
      activeWorkoutType: () => workoutType,
      breathing: () => breathing,
      // The engine reads the owner set synchronously inside its loop, so
      // record what it would see at the moment of each nudge.
      reconcileLiveStreams: () async {
        nudges++;
        final o = controller.owners;
        seen.add((o.visibleLiveHrView, o.movementSampling));
      },
    );
  });

  test('updates the owner set for each host transition', () {
    expect(controller.owners.foreground, isTrue);
    expect(controller.owners.activeWorkout, isFalse);
    expect(controller.owners.foregroundGaitWorkout, isFalse);
    expect(controller.owners.breathing, isFalse);

    workoutType = 'running';
    expect(controller.owners.activeWorkout, isTrue);
    expect(controller.owners.foregroundGaitWorkout, isTrue);

    breathing = true;
    expect(controller.owners.breathing, isTrue);

    background = true;
    expect(controller.owners.foreground, isFalse);
    expect(controller.owners.foregroundGaitWorkout, isFalse);
    expect(controller.owners.activeWorkout, isTrue);
  });

  test('counts viewers without letting release go below zero', () async {
    controller.releaseLiveHrView();
    await settle();
    expect(controller.owners.visibleLiveHrView, isFalse);
    expect(nudges, 1);

    controller.retainLiveHrView();
    controller.retainLiveHrView();
    controller.releaseLiveHrView();
    await settle();
    expect(controller.owners.visibleLiveHrView, isTrue);

    controller.releaseLiveHrView();
    controller.releaseLiveHrView();
    await settle();
    expect(controller.owners.visibleLiveHrView, isFalse);
    expect(nudges, 6);
  });

  test('makes movement windows idempotent and nudges only on changes',
      () async {
    controller.setMovementSamplingWindow(false);
    await settle();
    expect(controller.owners.movementSampling, isFalse);
    expect(nudges, 0);

    controller.setMovementSamplingWindow(true);
    await settle();
    expect(controller.owners.movementSampling, isTrue);
    expect(nudges, 1);

    controller.setMovementSamplingWindow(true);
    await settle();
    expect(nudges, 1);

    controller.setMovementSamplingWindow(false);
    await settle();
    expect(controller.owners.movementSampling, isFalse);
    expect(nudges, 2);
  });

  test('background views do not own HR, while workouts and breathing do', () {
    controller.retainLiveHrView();
    expect(controller.owners.visibleLiveHrView, isTrue);

    background = true;
    expect(controller.owners.visibleLiveHrView, isFalse);
    expect(controller.owners.activeWorkout, isFalse);

    workoutType = 'Strength';
    expect(controller.owners.activeWorkout, isTrue);
    expect(controller.owners.foregroundGaitWorkout, isFalse);

    breathing = true;
    expect(controller.owners.breathing, isTrue);
  });

  test('every nudge already sees the ownership it announces', () {
    controller.retainLiveHrView();
    controller.setMovementSamplingWindow(true);
    controller.releaseLiveHrView();
    controller.setMovementSamplingWindow(false);
    expect(seen, [(true, false), (true, true), (false, true), (false, false)]);
  });
}

Future<void> settle() => Future<void>.delayed(Duration.zero);
