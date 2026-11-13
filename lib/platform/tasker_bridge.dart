import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A BUZZ_STRAP that TaskerReceiver queued while the app was dead.
class PendingTaskerBuzz {
  final int pattern;

  /// Wall-clock ms when the broadcast arrived; null for a flag queued by a
  /// build that did not record it.
  final int? requestedAtMs;

  const PendingTaskerBuzz({required this.pattern, this.requestedAtMs});

  /// How long a queued buzz stays worth delivering. A buzz is a time-bound
  /// cue (rest timer over, reminder); the queue otherwise waits for any later
  /// reconnect, and a strap buzzing hours after the request reads as random.
  static const Duration maxAge = Duration(minutes: 2);

  static PendingTaskerBuzz? fromChannel(Object? raw) {
    if (raw is! Map) return null;
    final pattern = raw['pattern'];
    if (pattern is! int) return null;
    final at = raw['requestedAtMs'];
    return PendingTaskerBuzz(
      pattern: pattern,
      requestedAtMs: at is int ? at : null,
    );
  }

  /// Unknown age counts as stale. So does a request time in the future beyond
  /// [maxAge], which only happens after the wall clock was moved backwards.
  bool isFresh(DateTime now) {
    final at = requestedAtMs;
    if (at == null) return false;
    final ageMs = now.millisecondsSinceEpoch - at;
    return ageMs.abs() <= maxAge.inMilliseconds;
  }
}

class TaskerBridge {
  static const _ch = MethodChannel('openstrap/tasker');

  final Future<void> Function(int pattern) buzzPattern;

  TaskerBridge({required this.buzzPattern}) {
    _ch.setMethodCallHandler(_onMethodCall);
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method == 'buzz_strap') {
      try {
        final args = call.arguments;
        debugPrint('[tasker] _onMethodCall args=$args (${args.runtimeType})');
        final map = args is Map ? args : <dynamic, dynamic>{};
        final pattern = (map['pattern'] as int?) ?? 2;
        debugPrint('[tasker] buzz pattern=$pattern');
        await buzzPattern(pattern);
      } catch (e, st) {
        debugPrint('[tasker] buzz failed: $e\n$st');
      }
    }
  }

  /// Read (without clearing) a buzz Tasker requested while the app was fully
  /// dead — see TaskerReceiver.kt's "engine dead" fallback. This goes through
  /// a native method-channel call reading the SAME native SharedPreferences
  /// file ("openstrap_runtime") TaskerReceiver writes to directly. The
  /// `shared_preferences` PLUGIN reads/writes a DIFFERENT, plugin-managed
  /// store (its own file, `flutter.`-prefixed keys) — it can never see what
  /// TaskerReceiver persisted, so do not "simplify" this back to
  /// `SharedPreferences.getInstance()`.
  static Future<PendingTaskerBuzz?> peekPendingBuzz() async {
    try {
      return PendingTaskerBuzz.fromChannel(
          await _ch.invokeMethod<Object?>('peek_pending_buzz'));
    } catch (_) {
      return null;
    }
  }

  /// Clear the pending flag. Call ONLY after the buzz was actually delivered
  /// (see AppState._checkPendingTaskerBuzz) — never as part of the read —
  /// so a request that couldn't be sent yet (no BLE connection) survives to
  /// the next attempt instead of being silently dropped.
  static Future<void> clearPendingBuzz() async {
    try {
      await _ch.invokeMethod('clear_pending_buzz');
    } catch (_) {}
  }

  /// Rate-limit for outbound events, at the emit site. A reconnect storm can
  /// complete several offloads in a minute and each one would otherwise fire a
  /// broadcast that wakes every automation profile listening for it.
  static const Duration _minEventGap = Duration(seconds: 60);
  static DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Fire an OUTBOUND automation event: an Android broadcast the user's Tasker
  /// (or Automate, or MacroDroid) profile can trigger on.
  ///
  /// **ANDROID ONLY, and the docs must say so rather than implying parity.**
  /// iOS has no public mechanism for a Shortcuts personal automation to trigger
  /// on an arbitrary app-donated intent — the trigger list is a fixed system
  /// set. `donate`/`INInteraction` buys Siri suggestions and discoverability,
  /// not an event trigger. So iOS gets more intents the user invokes; it does
  /// not get events that invoke the user's shortcut, and pretending otherwise
  /// would be a promise the platform cannot keep.
  ///
  /// [extras] may carry FACTS (counts, timestamps, flags) and must never carry
  /// a derived metric. A number that the UI would have rendered as absent —
  /// with a tier and a note explaining why — becomes a bare `0` once it leaves
  /// the app, where nobody can see that it was never measured. Pass absence as
  /// absence: omit the key.
  static Future<bool> emitEvent(
    String event, {
    Map<String, Object> extras = const {},
  }) async {
    if (!Platform.isAndroid) return false;
    final now = DateTime.now();
    if (now.difference(_lastEmit) < _minEventGap) return false;
    _lastEmit = now;
    try {
      return await _ch.invokeMethod<bool>('emit_event', {
            'event': event,
            'extras': extras,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The one event that ships. `records` is how many the offload actually
  /// stored — a fact about the sync, not a measurement of the user.
  static Future<bool> emitSyncComplete({required int records}) => emitEvent(
        'SYNC_COMPLETE',
        extras: {
          'records': records,
          'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
      );

  /// The per-install secret Tasker (or any automation app) must echo back as
  /// the `token` string extra on its BUZZ_STRAP broadcast — generated once
  /// and persisted natively on first request. Surfaced in Settings →
  /// Automation for the user to copy into their Tasker action; without it,
  /// the exported, permission-less receiver would let any installed app
  /// trigger strap haptics. Returns null only on a channel/platform failure.
  static Future<String?> authToken() async {
    try {
      return await _ch.invokeMethod<String>('get_auth_token');
    } catch (_) {
      return null;
    }
  }
}
