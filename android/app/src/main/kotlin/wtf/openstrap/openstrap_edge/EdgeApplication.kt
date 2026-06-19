package wtf.openstrap.openstrap_edge

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Pre-warms a single long-lived [FlutterEngine] and caches it. MainActivity attaches
 * to THIS engine (via getCachedEngineId) instead of creating its own, and does NOT
 * destroy it when the Activity is finished (shouldDestroyEngineWithHost = false).
 *
 * Why: when the user swipes the app from recents, Android destroys the Activity and,
 * with a default Activity-owned engine, tears the engine down too (onDetachedFromEngine
 * in logcat). That kills the Dart VM — and with it flutter_blue_plus's BLE connection
 * AND the notification-relay stream (the native listener keeps firing but "FlutterJNI
 * detached … could not send"). By retaining the engine here and keeping the process
 * alive with the EdgeTracking foreground service, the Dart side keeps running headless
 * after task removal, so the relay can still buzz the band.
 *
 * The trade-off is RAM: the app stays warm in memory. That's the intended cost of a
 * persistent foreground BLE companion, and matches the existing foreground-service model.
 */
class EdgeApplication : Application() {
    companion object {
        const val ENGINE_ID = "openstrap_main_engine"
    }

    override fun onCreate() {
        super.onCreate()
        // Constructor auto-registers plugins (GeneratedPluginRegistrant) → flutter_blue_plus,
        // notification_listener_service, shared_preferences, etc. are all available headless.
        val engine = FlutterEngine(this)
        // Register platform channels on the engine BEFORE Dart starts, so they exist even
        // when no Activity is attached (headless calls like EdgeTracking.start must work).
        NativeChannels.register(engine, applicationContext)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }
}
