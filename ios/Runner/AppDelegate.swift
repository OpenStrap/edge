import Flutter
import UIKit
// workmanager 0.9 split the iOS plugin into the `workmanager_apple` module.
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Background sync (workmanager / BGTaskScheduler).
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // workmanager 0.9 API. Identifier must match BGTaskSchedulerPermittedIdentifiers.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "openstrap.periodicSync",
      frequency: NSNumber(value: 15 * 60)
    )

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
