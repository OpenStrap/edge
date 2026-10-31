package wtf.openstrap.openstrap_edge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build

/**
 * Receives BOOT_COMPLETED (and Qualcomm QUICKBOOT_POWERON) and restarts the
 * EdgeTrackingService so the band auto-reconnects headlessly after a device reboot.
 *
 * Checks for a paired band first so we don't spin up a pointless engine on phones that
 * never ran the app.
 *
 * Flutter SharedPreferences writes to "FlutterSharedPreferences.xml" with all keys
 * prefixed "flutter.". Our PairedDevice uses the key "paired_remote_id", so the XML
 * key is "flutter.paired_remote_id".
 *
 * Starting the service warms the cached FlutterEngine (EdgeTrackingService.onCreate
 * → EdgeApplication.ensureEngine). The Dart main() runs in that engine — it sees no
 * Activity (isHeadlessBoot path) and calls headlessBoot() which starts EdgeTracking +
 * connects to the paired band.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON") return

        if (!KeepAliveWorker.hasPairedDevice(context)) return
        markPendingHeadlessBoot(context)
        // BOOT_COMPLETED is exempt from the background FGS-start restriction;
        // QUICKBOOT_POWERON is not, so this start can be refused.
        EdgeTrackingService.startFromBackground(context, "BootReceiver")
    }

    private fun markPendingHeadlessBoot(context: Context) {
        val prefs: SharedPreferences = context.getSharedPreferences(
            "openstrap_runtime",
            Context.MODE_PRIVATE
        )
        prefs.edit().putBoolean("pending_headless_boot", true).apply()
    }
}
