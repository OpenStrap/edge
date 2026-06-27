package wtf.openstrap.openstrap_edge

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * Attaches to the long-lived engine pre-warmed in [EdgeApplication] rather than spinning
 * up its own, and refuses to destroy that engine when the Activity is finished. Combined
 * with the EdgeTracking foreground service keeping the process alive, this lets the Dart
 * side (BLE connection + notification relay) keep running after the app is swiped from
 * recents — instead of Android tearing the engine down (onDetachedFromEngine).
 *
 * Platform channels are registered on the engine in EdgeApplication (NativeChannels), not
 * here, so they exist even while no Activity is attached (headless channel calls work).
 *
 * FlutterFragmentActivity (not FlutterActivity) is required by the `health` plugin — its
 * Health Connect permission flow uses the AndroidX activity-result APIs, which need a
 * FragmentActivity host. The cached-engine overrides work the same on either base.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun getCachedEngineId(): String = EdgeApplication.ENGINE_ID
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
