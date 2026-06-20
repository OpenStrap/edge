import Flutter
import UIKit
import AudioToolbox
import AVFoundation

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
    // Band-gesture actions channel (double-tap → play/pause, skip, ring phone).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ActionBridge") {
      ActionBridge.register(messenger: registrar.messenger())
    }
    // Build-time iOS configuration exposed to Dart without requiring --dart-define.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ConfigBridge") {
      ConfigBridge.register(messenger: registrar.messenger())
    }
  }
}

enum ConfigBridge {
  private static let channelName = "openstrap/ios_config"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "appGroupIdentifier":
        result(Bundle.main.object(forInfoDictionaryKey: "OpenStrapAppGroupIdentifier") as? String ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// Band-gesture actions on iOS. Media control is deliberately NOT offered: iOS has no
// public API to control a third-party player (Spotify et al.) — only Apple Music via
// systemMusicPlayer — so advertising it would be misleading. The only sanctioned
// no-risk action here today is "ring my phone" (system alert sound + vibrate). System
// volume and call control aren't possible from a sandboxed iOS app and are omitted.
enum ActionBridge {
  private static let channelName = "openstrap/device_actions"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities":
        result(["ring_phone", "torch"])
      case "perform":
        let args = call.arguments as? [String: Any] ?? [:]
        result(perform(args["action"] as? String ?? ""))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func perform(_ action: String) -> Bool {
    switch action {
    case "ring_phone":
      AudioServicesPlaySystemSound(SystemSoundID(1005)) // loud alert tone
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
      return true
    case "torch":
      // Torch via AVCaptureDevice — toggling it does NOT start a capture session, so
      // it needs no camera authorization / NSCameraUsageDescription. (Verifeid on device.)
      guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
        return false
      }
      do {
        try device.lockForConfiguration()
        device.torchMode = device.isTorchActive ? .off : .on
        device.unlockForConfiguration()
        return true
      } catch {
        return false
      }
    default:
      return false
    }
  }
}
