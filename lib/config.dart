/// Build-time configuration. Override via `--dart-define` flags.
class Config {
  static const String apiBaseUrl = String.fromEnvironment(
    'WHOOPSIE_API',
    defaultValue: 'https://whoopsie-backend.abdulsaheel81.workers.dev',
  );

  /// How often the cloud sync worker drains the local DB.
  static const Duration syncInterval = Duration(seconds: 30);

  /// How often we poll the strap for battery (it doesn't push reliable events).
  static const Duration batteryPollInterval = Duration(seconds: 20);

  /// LINK_VALID heartbeat — without this BLE drops faster on Android Doze.
  static const Duration linkHeartbeatInterval = Duration(seconds: 10);
}
