// device_action.dart — the platform-agnostic catalogue of things a band gesture
// (today: double-tap) can trigger. The enum is the single source of truth shared by
// the settings UI, the persisted mapping, and the native dispatch channel.
//
// Adding a new action is one entry here + one `case` in the native handlers
// (ActionHandler.kt / ActionBridge.swift). Whether a platform actually SUPPORTS an
// action is reported at runtime by DeviceActions.capabilities() — the UI only offers
// what the current OS can do, so e.g. volume control simply doesn't appear on iOS.
//
// FUTURE (deliberately not wired yet — each needs more than a no-risk API or a
// product decision): answer/reject call (Android ANSWER_PHONE_CALLS; impossible on
// iOS), "mark a moment" journal tag, workout lap/stop, torch (camera permission).

enum DeviceAction {
  none,
  mediaPlayPause,
  mediaNext,
  mediaPrev,
  volumeUp,
  volumeDown,
  ringPhone,
  torch,
  // In-app actions — act on our own app/backend, so they work on every platform
  // (iOS can't reach other apps, but it can always do these).
  markMoment,
  workoutToggle,
  // Native broadcast — sends an Android broadcast intent for Tasker to subscribe
  // to (see NativeChannels.kt). Only offered on Android.
  broadcastToTasker,
}

extension DeviceActionX on DeviceAction {
  /// Stable wire id — used as the SharedPreferences value AND the `action` arg sent
  /// over the method channel. Never change these once shipped (persisted).
  String get id {
    switch (this) {
      case DeviceAction.none:
        return 'none';
      case DeviceAction.mediaPlayPause:
        return 'media_play_pause';
      case DeviceAction.mediaNext:
        return 'media_next';
      case DeviceAction.mediaPrev:
        return 'media_prev';
      case DeviceAction.volumeUp:
        return 'volume_up';
      case DeviceAction.volumeDown:
        return 'volume_down';
      case DeviceAction.ringPhone:
        return 'ring_phone';
      case DeviceAction.torch:
        return 'torch';
      case DeviceAction.markMoment:
        return 'mark_moment';
      case DeviceAction.workoutToggle:
        return 'workout_toggle';
      case DeviceAction.broadcastToTasker:
        return 'broadcast_to_tasker';
    }
  }

  /// Short label for the settings picker.
  String get label {
    switch (this) {
      case DeviceAction.none:
        return 'Do nothing';
      case DeviceAction.mediaPlayPause:
        return 'Play / pause music';
      case DeviceAction.mediaNext:
        return 'Next track';
      case DeviceAction.mediaPrev:
        return 'Previous track';
      case DeviceAction.volumeUp:
        return 'Volume up';
      case DeviceAction.volumeDown:
        return 'Volume down';
      case DeviceAction.ringPhone:
        return 'Ring my phone';
      case DeviceAction.torch:
        return 'Flashlight';
      case DeviceAction.markMoment:
        return 'Mark a moment';
      case DeviceAction.workoutToggle:
        return 'Start / stop workout';
      case DeviceAction.broadcastToTasker:
        return 'Broadcast to Tasker';
    }
  }

  /// One-line description shown under the label.
  String get blurb {
    switch (this) {
      case DeviceAction.none:
        return 'Double-tap does nothing.';
      case DeviceAction.mediaPlayPause:
        return 'Toggle whatever is playing.';
      case DeviceAction.mediaNext:
        return 'Skip to the next track.';
      case DeviceAction.mediaPrev:
        return 'Go back a track.';
      case DeviceAction.volumeUp:
        return 'Raise media volume a step.';
      case DeviceAction.volumeDown:
        return 'Lower media volume a step.';
      case DeviceAction.ringPhone:
        return 'Play a loud sound so you can find your phone.';
      case DeviceAction.torch:
        return "Toggle your phone's flashlight.";
      case DeviceAction.markMoment:
        return 'Tag the current moment in your journal.';
      case DeviceAction.workoutToggle:
        return 'Begin or end a workout from your wrist.';
      case DeviceAction.broadcastToTasker:
        return 'Fire a broadcast intent so Tasker can trigger any automation.';
    }
  }

  /// In-app actions act on our own app/backend (handled in Dart, no native call,
  /// available on every platform). Everything else (except `none`) is native.
  bool get isInApp =>
      this == DeviceAction.markMoment || this == DeviceAction.workoutToggle;

  bool get isNative => this != DeviceAction.none && !isInApp;

  static DeviceAction? fromId(String? id) {
    if (id == null) return null;
    for (final a in DeviceAction.values) {
      if (a.id == id) return a;
    }
    return null;
  }
}
