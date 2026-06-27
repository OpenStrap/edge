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
 * Starting the service also triggers EdgeApplication.onCreate, which pre-warms the
 * cached FlutterEngine. The Dart main() runs in that engine — it sees no Activity
 * (isHeadlessBoot path) and calls headlessBoot() which starts EdgeTracking + connects
 * to the paired band.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON") return

        if (!hasPairedDevice(context)) return

        val svcIntent = Intent(context, EdgeTrackingService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(svcIntent)
        } else {
            context.startService(svcIntent)
        }
    }

    private fun hasPairedDevice(context: Context): Boolean {
        // Flutter SharedPreferences file name + key prefix.
        val prefs: SharedPreferences = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE
        )
        val id = prefs.getString("flutter.paired_remote_id", null)
        return !id.isNullOrEmpty()
    }
}
