package wtf.openstrap.openstrap_edge

import android.content.Context
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Periodic watchdog: "paired but the tracking service isn't running" → restart it.
 *
 * START_STICKY already asks the OS to recreate EdgeTrackingService after a kill,
 * but several OEMs delay or drop sticky restarts, and a user-swiped task can end
 * the service without a restart on some builds. WorkManager survives all of that
 * (its jobs are persisted by the OS), so every ~15 min (the WorkManager floor)
 * this worker checks the paired flag + the in-process running flag and restarts
 * the foreground service if it died.
 *
 * FGS-from-background note (API 31+): starting a foreground service from a
 * worker requires an exemption. This app requests two independent ones — the
 * CompanionDeviceManager association (CompanionBridge) and the
 * battery-optimization exemption — either of which unblocks the start. If
 * neither is granted yet, the start throws ForegroundServiceStartNotAllowedException;
 * we log and retry next period (the CDM presence callback and app-open paths
 * still recover the service).
 */
class KeepAliveWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    companion object {
        private const val TAG = "KeepAliveWorker"
        private const val WORK_NAME = "edge_keepalive_watchdog"

        /** Enqueue the periodic watchdog (idempotent — KEEPs an existing chain). */
        @JvmStatic
        fun schedule(context: Context) {
            try {
                val req = PeriodicWorkRequestBuilder<KeepAliveWorker>(15, TimeUnit.MINUTES)
                    .build()
                WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                    WORK_NAME,
                    ExistingPeriodicWorkPolicy.KEEP,
                    req,
                )
            } catch (e: Exception) {
                Log.w(TAG, "schedule failed: $e")
            }
        }

        /**
         * Drop the periodic watchdog. Called only from the explicit unpair path:
         * the chain is persisted by WorkManager, so without this it keeps
         * cold-starting the process every 15 min for the life of the install
         * after a band is forgotten. doWork deliberately does not self-cancel
         * on an unpaired prefs read (see there), so the unpair intent is the
         * one place this is safe. Pairing again re-arms it via
         * EdgeTrackingService.onCreate.
         */
        @JvmStatic
        fun cancel(context: Context) {
            try {
                WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            } catch (e: Exception) {
                Log.w(TAG, "cancel failed: $e")
            }
        }

        /**
         * Whether Dart has a band paired. Flutter SharedPreferences writes to
         * "FlutterSharedPreferences.xml" with keys prefixed "flutter.".
         * Internal: EdgeApplication and BootReceiver gate on the same check.
         */
        @JvmStatic
        internal fun hasPairedDevice(context: Context): Boolean {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            return !prefs.getString("flutter.paired_remote_id", null).isNullOrEmpty()
        }
    }

    override fun doWork(): Result {
        val ctx = applicationContext
        if (!hasPairedDevice(ctx)) {
            // Unpaired: nothing to keep alive this tick — succeed WITHOUT
            // cancelling the unique chain. hasPairedDevice is a best-effort
            // prefs read; a false negative here used to cancel the watchdog
            // permanently for a paired user, which is exactly the state the
            // watchdog exists for (fgs dead). One extra no-op wake per 15 min
            // is the cheap side of that one-way door; a real unpair cancels
            // the chain explicitly via cancel().
            return Result.success()
        }
        if (EdgeTrackingService.running) return Result.success() // healthy
        return try {
            Log.i(TAG, "paired but service not running — restarting EdgeTrackingService")
            EdgeTrackingService.start(ctx)
            Result.success()
        } catch (e: Exception) {
            // Most likely ForegroundServiceStartNotAllowedException (no background
            // FGS exemption yet). Don't retry-storm; the next period tries again.
            Log.w(TAG, "restart failed: $e")
            Result.success()
        }
    }
}
