import '../gestures/gesture_dispatcher.dart';
import '../gestures/gesture_settings.dart';

/// Owns the double-tap dispatcher. AppState still stores the band event and
/// handles the alarm before handing the event here.
class GestureController {
  GestureController({
    required GestureSettings settings,
    required void Function(String line) log,
    required Future<void> Function() onMarkMoment,
    required Future<void> Function() onWorkoutToggle,
    required Future<void> Function() onLogWater,
  }) : _dispatcher = GestureDispatcher(
          settings: settings,
          log: log,
          onMarkMoment: onMarkMoment,
          onWorkoutToggle: onWorkoutToggle,
          onLogWater: onLogWater,
        );

  /// Built with the controller, as AppState built it in its constructor.
  final GestureDispatcher _dispatcher;

  void onEvent(int id, int ts, String hex) {
    _dispatcher.onEvent(id, ts, hex);
  }
}
