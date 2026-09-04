package wtf.openstrap.openstrap_edge

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.CompanionDeviceService
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * CompanionDeviceManager (CDM) integration.
 *
 * After pairing, the Dart side calls `associateCompanion` (openstrap/android_background
 * channel, wired in NativeChannels) with the band's MAC. We:
 *   1. build an AssociationRequest pre-filtered to exactly that MAC (single-device),
 *   2. launch the system's one-tap companion dialog from the current Activity,
 *   3. on success — and on every subsequent app open (ensureObserving) — call
 *      `startObservingDevicePresence` (API 31+) so the OS binds EdgeCompanionService
 *      when the band comes into range, even if the app process was killed.
 *
 * Why: an associated companion app is exempt from the API 31+ restriction on starting
 * foreground services from the background (unblocking the KeepAliveWorker watchdog and
 * BootReceiver paths), and device-presence observation gives us an OS-driven relaunch
 * the moment the band reappears — no polling.
 *
 * API gates: CDM exists from API 26; presence observation + CompanionDeviceService
 * from API 31. Below those we silently degrade (the foreground service + sticky
 * restart still work).
 */

/**
 * Pure request-code bookkeeping for in-flight CDM associations, keyed by uppercased MAC.
 *
 * Extracted from [CompanionBridge] so the attribution logic — the actual bug fixed here —
 * is testable with plain JUnit, with no Android framework/Robolectric dependency.
 *
 * WAS a single `@Volatile pendingMac: String?` on [CompanionBridge]. Two concurrent
 * `associate()` calls overwrote each other, so the loser's MAC never reached
 * `startObservingDevicePresence` and that device got no OS presence relaunch — with every
 * log line still reading as success. Two calls is not hypothetical: `_persistPaired` fires
 * `associateCompanion` fire-and-forget per device.
 */
internal class PendingAssociations {
    /** One in-flight association: the chooser request code and the Flutter reply. */
    class Entry(val requestCode: Int, val result: MethodChannel.Result?)

    // ConcurrentHashMap because `associate` runs on the platform thread and
    // `handleActivityResult` on the main thread.
    private val pending = ConcurrentHashMap<String, Entry>()

    /**
     * Chooser request codes are allocated from this base so a result can be traced back
     * to its MAC. The FIRST allocation is the base itself, which is the value this code
     * has always used — a single-device pairing sends the identical request code it did
     * before.
     */
    private val nextSlot = AtomicInteger(0)

    /** Already has a dialog in flight for [mac]? (idempotence check for `associate`). */
    fun inFlight(mac: String): Boolean = pending.containsKey(mac)

    /** Allocate a request code and record [mac] as in-flight. */
    fun begin(mac: String, result: MethodChannel.Result?, base: Int, span: Int): Int {
        val code = base + (nextSlot.getAndIncrement() % span)
        pending[mac] = Entry(code, result)
        return code
    }

    fun requestCodeFor(mac: String): Int? = pending[mac]?.requestCode

    fun remove(mac: String) {
        pending.remove(mac)
    }

    /** The MAC awaiting [requestCode], if any — does not remove it. */
    fun macFor(requestCode: Int): String? =
        pending.entries.firstOrNull { it.value.requestCode == requestCode }?.key
}

object CompanionBridge {
    private const val TAG = "CompanionBridge"

    private const val REQUEST_CODE_ASSOCIATE = 0x4A11
    private const val REQUEST_CODE_SPAN = 16

    /** The visible Activity, registered by MainActivity (needed to launch the CDM dialog). */
    @Volatile
    var currentActivity: Activity? = null

    private val pending = PendingAssociations()

    private fun manager(context: Context): CompanionDeviceManager? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            context.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager
        else null

    /** MACs already associated with this app (empty below API 26 / on error). */
    private fun associatedMacs(context: Context): List<String> {
        val dm = manager(context) ?: return emptyList()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                dm.myAssociations.mapNotNull { it.deviceMacAddress?.toString()?.uppercase() }
            } else {
                @Suppress("DEPRECATION")
                dm.associations.map { it.uppercase() }
            }
        } catch (e: Exception) {
            Log.w(TAG, "associations query failed: $e")
            emptyList()
        }
    }

    /**
     * Associate the paired band (fire-and-forget from Dart). Completes [result] with a
     * short status string; the real outcome (user accepting the dialog) lands later in
     * [handleActivityResult].
     */
    fun associate(context: Context, mac: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || mac.isEmpty()) {
            result.success("unsupported")
            return
        }
        val dm = manager(context)
        if (dm == null) {
            result.success("no_cdm") // device lacks the companion_device_setup feature
            return
        }
        val upper = mac.uppercase()
        if (associatedMacs(context).contains(upper)) {
            startObserving(context, upper)
            result.success("already_associated")
            return
        }
        val activity = currentActivity
        if (activity == null) {
            // Headless call (no UI to host the system dialog). MainActivity.onCreate
            // retries via ensureObserving/associations on next open.
            result.success("no_activity")
            return
        }
        // Idempotence per MAC: a second associate for a MAC whose dialog is already up
        // is the duplicate this map exists to notice, not a reason to launch a second
        // chooser for the same device.
        if (pending.inFlight(upper)) {
            result.success("dialog_shown")
            return
        }
        pending.begin(upper, result, REQUEST_CODE_ASSOCIATE, REQUEST_CODE_SPAN)
        try {
            val scanFilter = ScanFilter.Builder().setDeviceAddress(upper).build()
            val deviceFilter = BluetoothLeDeviceFilter.Builder()
                .setScanFilter(scanFilter)
                .build()
            val request = AssociationRequest.Builder()
                .addDeviceFilter(deviceFilter)
                // setSingleDevice(true) STAYS: the filter is already pinned to one MAC,
                // so the clean one-tap dialog is correct and was never the bug.
                .setSingleDevice(true)
                .build()
            @Suppress("DEPRECATION") // non-Executor overload: valid on all supported APIs
            dm.associate(request, object : CompanionDeviceManager.Callback() {
                @Deprecated("Deprecated in API 33; still delivered on 26–32")
                override fun onDeviceFound(chooserLauncher: IntentSender) {
                    launchChooser(upper, chooserLauncher, result)
                }

                // API 33+ path (default impl would forward to onDeviceFound, but be explicit).
                override fun onAssociationPending(intentSender: IntentSender) {
                    launchChooser(upper, intentSender, result)
                }

                override fun onAssociationCreated(associationInfo: AssociationInfo) {
                    // Some OS builds skip the pending step when the device was
                    // associated before. Nothing to launch — just observe.
                    Log.i(TAG, "association created for $upper: ${associationInfo.id}")
                    pending.remove(upper)
                    startObserving(context, upper)
                    try { result.success("associated") } catch (_: Exception) {}
                }

                override fun onFailure(error: CharSequence?) {
                    Log.w(TAG, "association failed for $upper: $error")
                    pending.remove(upper)
                    try { result.success("failed: $error") } catch (_: Exception) {}
                }
            }, null)
        } catch (e: Exception) {
            Log.w(TAG, "associate threw for $upper: $e")
            pending.remove(upper)
            result.success("error: $e")
        }
    }

    private fun launchChooser(mac: String, sender: IntentSender, result: MethodChannel.Result) {
        val activity = currentActivity
        val code = pending.requestCodeFor(mac)
        if (activity == null || code == null) {
            pending.remove(mac)
            try { result.success("no_activity") } catch (_: Exception) {}
            return
        }
        try {
            activity.startIntentSenderForResult(sender, code, null, 0, 0, 0)
            try { result.success("dialog_shown") } catch (_: Exception) {}
        } catch (e: Exception) {
            Log.w(TAG, "chooser launch failed for $mac: $e")
            pending.remove(mac)
            try { result.success("error: $e") } catch (_: Exception) {}
        }
    }

    /**
     * MainActivity forwards its activity results here. Returns true when the result was
     * one of OUR association dialogs (consumed) — resolved through the pending map, so a
     * second device's dialog result can never be credited to the first device's MAC.
     */
    fun handleActivityResult(context: Context, requestCode: Int, resultCode: Int): Boolean {
        if (requestCode < REQUEST_CODE_ASSOCIATE ||
            requestCode >= REQUEST_CODE_ASSOCIATE + REQUEST_CODE_SPAN) return false
        val mac = pending.macFor(requestCode)
        // In range but unknown: our own dialog whose entry was already dropped (process
        // recreated the Activity, or a failure path cleared it). Consume it — forwarding
        // it to super would offer it to plugins as if it were theirs — but attribute
        // nothing.
        if (mac == null) {
            Log.i(TAG, "association result $requestCode has no pending entry — ignored")
            return true
        }
        pending.remove(mac)
        if (resultCode == Activity.RESULT_OK) {
            Log.i(TAG, "companion association accepted for $mac")
            startObserving(context, mac)
        } else {
            Log.i(TAG, "companion association declined/cancelled for $mac (code=$resultCode)")
        }
        return true
    }

    /**
     * Re-arm presence observation for any already-associated band. Called on every
     * MainActivity.onCreate — cheap, idempotent, and covers OS updates/reboots where
     * the observation registration may need refreshing.
     */
    fun ensureObserving(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        for (mac in associatedMacs(context)) startObserving(context, mac)
    }

    private fun startObserving(context: Context, mac: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            @Suppress("DEPRECATION") // ObservingDevicePresenceRequest is API 36+
            manager(context)?.startObservingDevicePresence(mac)
            Log.i(TAG, "observing device presence for $mac")
        } catch (e: Exception) {
            Log.w(TAG, "startObservingDevicePresence failed: $e")
        }
    }
}

/**
 * Bound by the OS (API 31+) when an observed companion device appears/disappears.
 * "Appeared" = the band is in range again → restart the tracking foreground service
 * (allowed from here; CompanionDeviceService callbacks carry the FGS exemption). The
 * service keeps the pre-warmed FlutterEngine process alive, whose Dart side
 * auto-connects to the paired band (headless_boot / AppState reconnect).
 */
@RequiresApi(Build.VERSION_CODES.S)
class EdgeCompanionService : CompanionDeviceService() {
    companion object { private const val TAG = "EdgeCompanionService" }

    // API 31–32 signature.
    @Deprecated("Deprecated in API 33; still the delivery path on 31–32")
    override fun onDeviceAppeared(address: String) {
        Log.i(TAG, "device appeared: $address")
        onBandAppeared()
    }

    // API 33+ signature.
    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        Log.i(TAG, "device appeared: ${associationInfo.deviceMacAddress}")
        onBandAppeared()
    }

    @Deprecated("Deprecated in API 33; still the delivery path on 31–32")
    override fun onDeviceDisappeared(address: String) {
        Log.i(TAG, "device disappeared: $address")
    }

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        Log.i(TAG, "device disappeared: ${associationInfo.deviceMacAddress}")
    }

    private fun onBandAppeared() {
        // Routine re-appearances (arm-swing / body-block dropouts, many per hour
        // mid-workout) must not churn an already-running service — a restart just
        // rebuilds and re-posts the notification. `running` is exact in-process,
        // and a dead process initializes it false, so the cold path still starts.
        if (EdgeTrackingService.running) return
        try {
            EdgeTrackingService.start(this)
        } catch (e: Exception) {
            Log.w(TAG, "failed to start tracking service: $e")
        }
    }
}
