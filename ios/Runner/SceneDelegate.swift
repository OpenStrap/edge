import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// Re-submit the BGProcessingTask request every time a scene enters the
  /// background so iOS always has a pending request to fire opportunistically.
  /// This is the correct hook in a UISceneDelegate-based app (scene lifecycle
  /// fires reliably; AppDelegate.applicationDidEnterBackground fires less
  /// consistently when UISceneDelegate is in use).
  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    BackgroundTaskManager.schedule()
  }
}
