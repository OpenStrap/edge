import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  static Future<int?> peekPendingBuzz() async {
    try {
      return await _ch.invokeMethod<int>('peek_pending_buzz');
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
