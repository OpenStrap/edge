package wtf.openstrap.openstrap_edge

import android.content.Context
import android.content.Intent
import android.os.Bundle
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
 * The one exception is CompanionDeviceManager association, which must launch a system
 * dialog — [CompanionBridge] borrows this Activity for that (registered in onCreate,
 * result forwarded from onActivityResult).
 *
 * FlutterFragmentActivity (not FlutterActivity) is required by the `health` plugin — its
 * Health Connect permission flow uses the AndroidX activity-result APIs, which need a
 * FragmentActivity host. The cached-engine overrides work the same on either base.
 */
class MainActivity : FlutterFragmentActivity() {
    companion object {
        @Volatile
        var activityAttached: Boolean = false
    }

    override fun getCachedEngineId(): String = EdgeApplication.ENGINE_ID
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        activityAttached = true
        clearPendingHeadlessBoot()
        super.onCreate(savedInstanceState)
        CompanionBridge.currentActivity = this
        // Re-arm CDM device-presence observation for an already-associated band
        // (idempotent; no-op below API 31 or when nothing is associated).
        CompanionBridge.ensureObserving(applicationContext)
    }

    override fun onStart() {
        super.onStart()
        activityAttached = true
        clearPendingHeadlessBoot()
    }

    override fun onStop() {
        activityAttached = false
        super.onStop()
    }

    override fun onDestroy() {
        if (CompanionBridge.currentActivity === this) {
            CompanionBridge.currentActivity = null
        }
        super.onDestroy()
    }

    @Deprecated("Deprecated in AndroidX; Flutter still routes plugin results through it")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // CDM association dialog result → CompanionBridge (consumed there).
        if (CompanionBridge.handleActivityResult(applicationContext, requestCode, resultCode)) {
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun clearPendingHeadlessBoot() {
        val prefs = applicationContext.getSharedPreferences(
            "openstrap_runtime",
            Context.MODE_PRIVATE
        )
        if (prefs.getBoolean("pending_headless_boot", false)) {
            prefs.edit().putBoolean("pending_headless_boot", false).apply()
        }
    }
}
