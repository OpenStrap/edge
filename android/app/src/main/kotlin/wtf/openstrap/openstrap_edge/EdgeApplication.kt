package wtf.openstrap.openstrap_edge

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the single long-lived [FlutterEngine], created LAZILY via [ensureEngine].
 * MainActivity attaches to it (via getCachedEngineId) instead of creating its own,
 * and does NOT destroy it when the Activity is finished (shouldDestroyEngineWithHost
 * = false).
 *
 * Why retained: when the user swipes the app from recents, Android destroys the
 * Activity and, with a default Activity-owned engine, tears the engine down too
 * (onDetachedFromEngine in logcat). That kills the Dart VM — and with it
 * flutter_blue_plus's BLE connection AND the notification-relay stream. By retaining
 * the engine and keeping the process alive with the EdgeTracking foreground service,
 * the Dart side keeps running headless after task removal.
 *
 * Why LAZY (moved out of Application.onCreate): the process is also started by
 * widget update alarms, KeepAliveWorker runs, CDM device-presence binds and Tasker
 * broadcasts — wakes that need ZERO Dart. Widgets render native snapshots from
 * prefs; the worker/CDM paths just start EdgeTrackingService, whose own onCreate
 * calls [ensureEngine]; TaskerReceiver has an engine-dead fallback. Cold-booting a
 * full FlutterEngine + Dart main() for each of those wakes was pure battery burn on
 * exactly the devices (background-restricted / low-RAM) that kill the process most
 * often. Accepted trade-off: the system-bound NotificationListener can cold-start
 * the process engine-less, so relayed notification buzzes drop until the tracking
 * service starts (CDM presence when the band is in range — the only time a buzz
 * can land anyway — or the ≤15 min KeepAliveWorker).
 *
 * The trade-off is RAM while the engine IS up: intended cost of a persistent
 * foreground BLE companion, matching the foreground-service model.
 */
class EdgeApplication : Application() {
    companion object {
        const val ENGINE_ID = "openstrap_main_engine"

        /**
         * Create, register, run and cache the shared engine if it doesn't exist
         * yet; return the cached one otherwise. Idempotent. Main-thread only —
         * every caller (Activity/Service onCreate) already is.
         */
        @JvmStatic
        fun ensureEngine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
            val app = context.applicationContext
            // Constructor auto-registers plugins (GeneratedPluginRegistrant) →
            // flutter_blue_plus, notification_listener_service, shared_preferences,
            // etc. are all available headless.
            val engine = FlutterEngine(app)
            // Register platform channels on the engine BEFORE Dart starts, so they
            // exist even when no Activity is attached (headless calls like
            // EdgeTracking.start must work).
            NativeChannels.register(engine, app)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            return engine
        }
    }

    override fun onCreate() {
        super.onCreate()
        // Periodic watchdog: restart the tracking foreground service if the OS
        // killed it while a band is paired (START_STICKY backup). Idempotent (KEEP
        // policy). Paired-gated: unconditional scheduling gave even a never-paired
        // install a persisted 15-min periodic wake forever. Pairing (re-)arms it
        // via EdgeTrackingService.onCreate, and unpair cancels the chain
        // (KeepAliveWorker.cancel from the edge_tracking "stop" call).
        if (KeepAliveWorker.hasPairedDevice(this)) {
            KeepAliveWorker.schedule(this)
        }
    }
}
