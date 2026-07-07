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

        private fun hasPairedDevice(context: Context): Boolean {
            // Flutter SharedPreferences file name + key prefix (see BootReceiver).
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            return !prefs.getString("flutter.paired_remote_id", null).isNullOrEmpty()
        }
    }

    override fun doWork(): Result {
        val ctx = applicationContext
        if (!hasPairedDevice(ctx)) return Result.success() // nothing to keep alive
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
