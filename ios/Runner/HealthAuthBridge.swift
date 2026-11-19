import Flutter
import HealthKit

// Per-type WRITE authorization status → Dart. The `health` plugin cannot read
// write auth on iOS (HealthKit hides it from the plugin by design), but
// HKHealthStore.authorizationStatus(for:) DOES answer for the share side —
// only READ denial is withheld, so an app can tell "granted"/"denied"/
// "not yet asked" apart for writes, which is exactly what a settings screen
// needs. Without this, a revoked grant only surfaced as a silently skipped
// export.
//
// `authorizationStatus` is synchronous and never prompts, so this is safe to
// call on app resume and on every settings-screen open.

enum HealthAuthBridge {
  private static let channelName = "openstrap/health_auth"
  private static let store = HKHealthStore()

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "writeStatus":
        guard HKHealthStore.isHealthDataAvailable() else {
          result([])  // iPad and the simulator. Not an error, just no store.
          return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        let keys = args["types"] as? [String] ?? []
        var out: [[String: Any]] = []
        for key in keys {
          guard let type = objectType(for: key) else { continue }
          out.append([
            "type": key,
            "status": statusString(store.authorizationStatus(for: type)),
          ])
        }
        result(out)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The HealthKit object type behind one Dart-side key, or nil for a key this
  /// build does not ask for. Sleep collapses to the single `sleepAnalysis`
  /// category type that all stage types share.
  private static func objectType(for key: String) -> HKObjectType? {
    switch key {
    case "sleep":
      return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    case "resting_hr":
      return HKObjectType.quantityType(forIdentifier: .restingHeartRate)
    case "hrv":
      return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    case "resp_rate":
      return HKObjectType.quantityType(forIdentifier: .respiratoryRate)
    case "heart_rate":
      return HKObjectType.quantityType(forIdentifier: .heartRate)
    case "active_energy":
      return HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
    case "basal_energy":
      return HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)
    case "steps":
      return HKObjectType.quantityType(forIdentifier: .stepCount)
    case "workout":
      return HKObjectType.workoutType()
    case "weight":
      return HKObjectType.quantityType(forIdentifier: .bodyMass)
    default:
      return nil
    }
  }

  private static func statusString(_ status: HKAuthorizationStatus) -> String {
    switch status {
    case .sharingAuthorized:
      return "authorized"
    case .sharingDenied:
      return "denied"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "unknown"
    }
  }
}
