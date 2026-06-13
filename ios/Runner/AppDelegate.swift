import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // No OS periodic background task (no WorkManager 15-min / BGTask): continuous sync is
    // the kept-alive live BLE connection + the persistent flusher in AppState, with
    // CoreBluetooth state restoration below as the relaunch-recovery fallback.

    // CoreBluetooth state restoration — must be created here (early) so iOS can relaunch
    // us with willRestoreState when the band reappears. Wakes the app → headless sync.
    BleRestoreManager.shared.start(launchOptions: launchOptions)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Live Activity MethodChannel (start/update/end the workout activity).
    // LiveActivityBridge lives in LiveActivityBridge.swift (Runner target).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LiveActivityBridge") {
      LiveActivityBridge.register(messenger: registrar.messenger())
    }
    // BLE-restore channel: native wake (band reconnected) → Dart headless sync.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BleRestoreManager") {
      BleRestoreManager.shared.attach(messenger: registrar.messenger())
    }
  }
}
