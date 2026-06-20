import Foundation

enum AppGroup {
  static let identifier: String = {
    Bundle.main.object(forInfoDictionaryKey: "OpenStrapAppGroupIdentifier") as? String
      ?? "group.com.example.openstrap"
  }()
}
