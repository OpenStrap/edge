import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene,
          let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = FlutterViewController(
      engine: delegate.sharedEngine, nibName: nil, bundle: nil)
    self.window = window
    window.makeKeyAndVisible()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// Re-submit the BGProcessingTask + BGAppRefreshTask requests every time a
  /// scene enters the background so iOS always has pending requests to fire
  /// opportunistically. This is the correct hook in a UISceneDelegate-based app
  /// (scene lifecycle fires reliably; AppDelegate.applicationDidEnterBackground
  /// fires less consistently when UISceneDelegate is in use).
  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    BackgroundTaskManager.schedule()
    BackgroundTaskManager.scheduleRefresh()
  }
}
