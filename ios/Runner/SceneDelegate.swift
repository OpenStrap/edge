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

  // Whenever the phone app comes to the foreground, mirror the App Group
  // snapshot to the watch, so the wrist is not waiting on the next derive.
  // This has to live here: once the app opts into scenes UIKit stops calling
  // AppDelegate.applicationDidBecomeActive, and Flutter's scene fallback only
  // forwards it to plugins, so an AppDelegate override never runs.
  //
  // It mirrors whatever is already there — nothing rewrites the group on a mere
  // foreground, only a completed derive does (AppState → WidgetService.refresh).
  // So this can ship yesterday's snapshot, and that is survivable only because
  // the watch ages `updated_at` itself (WatchMetrics.fresh) and shows its
  // no-recent-data state rather than yesterday's numbers.
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    WatchBridge.shared.pushCurrentState()
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
