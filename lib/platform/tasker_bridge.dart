import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

class TaskerBridge {
  static const _ch = MethodChannel('openstrap/tasker');
  static const _pendingKey = 'pending_tasker_buzz';
  static const _pendingPatternKey = 'pending_tasker_buzz_pattern';

  final Future<void> Function(int pattern) buzzPattern;

  TaskerBridge({required this.buzzPattern}) {
    _ch.setMethodCallHandler(_onMethodCall);
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method == 'buzz_strap') {
      final pattern = (call.arguments as Map?)?['pattern'] as int? ?? 2;
      await buzzPattern(pattern);
    }
  }

  static Future<int?> consumePendingBuzz() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getBool(_pendingKey) ?? false;
    if (!pending) return null;
    final pattern = prefs.getInt(_pendingPatternKey) ?? 2;
    await prefs.remove(_pendingKey);
    await prefs.remove(_pendingPatternKey);
    return pattern;
  }
}
