package wtf.openstrap.openstrap_edge

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Telephony bridge for the incoming-call strap buzz (see lib/notify/call_buzzer.dart).
 *
 * Ringing is NOT observable through the notification relay: dialers post the
 * incoming-call notification as ONGOING (which the relay rightly skips as
 * "not a ping"), and the dialer itself is a system app the picker hides. So the
 * Dart side gets a dedicated call-state stream instead: "ringing" | "offhook" |
 * "idle", straight from TelephonyManager.
 *
 * Registered on the long-lived engine (see EdgeApplication) with the application
 * Context, so the stream keeps flowing while the app is backgrounded. Only the
 * call STATE is read — never numbers: READ_PHONE_STATE without READ_CALL_LOG
 * doesn't expose them (and we don't ask).
 */
object CallStateBridge {
    private const val METHOD_CHANNEL = "openstrap/call_state"
    private const val EVENT_CHANNEL = "openstrap/call_state_events"

    /** Unique within the app; MainActivity routes matching results back here. */
    private const val PERMISSION_REQUEST_CODE = 4207

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPermissionResult: MethodChannel.Result? = null

    private var telephony: TelephonyManager? = null
    private var sink: EventChannel.EventSink? = null
    // Exactly one of these is registered, by API level. Kept to unregister on cancel.
    private var modernCallback: TelephonyCallback? = null
    private var legacyListener: PhoneStateListener? = null

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPermissionGranted" -> result.success(hasPermission(app))
                    "requestPermission" -> requestPermission(result)
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink) {
                    sink = events
                    startListening(app)
                }

                override fun onCancel(args: Any?) {
                    stopListening()
                    sink = null
                }
            })
    }

    private fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        // Needs a foreground Activity for the system dialog — borrow the one
        // CompanionBridge already tracks. Absent (headless) → report ungranted;
        // the Dart side re-reads the real grant afterwards anyway.
        val activity = CompanionBridge.currentActivity
        if (activity == null) {
            result.success(false)
            return
        }
        if (hasPermission(activity)) {
            result.success(true)
            return
        }
        pendingPermissionResult?.success(false) // supersede a stale in-flight request
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.READ_PHONE_STATE),
            PERMISSION_REQUEST_CODE,
        )
    }

    /** MainActivity forwards permission results here. Returns true when consumed. */
    fun handlePermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    private fun stateName(state: Int): String = when (state) {
        TelephonyManager.CALL_STATE_RINGING -> "ringing"
        TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
        else -> "idle"
    }

    // EventSink must be driven from the main thread; telephony callbacks may not be.
    private fun emit(state: String) {
        mainHandler.post { sink?.success(state) }
    }

    private fun startListening(context: Context) {
        stopListening()
        // Without the grant, registering throws — stay silent; the Dart side only
        // subscribes when granted, and re-subscribes after a fresh grant.
        if (!hasPermission(context)) return
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return
        telephony = tm
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) = emit(stateName(state))
                }
                modernCallback = cb
                tm.registerTelephonyCallback(ContextCompat.getMainExecutor(context), cb)
            } else {
                @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
                val listener = object : PhoneStateListener() {
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) =
                        emit(stateName(state))
                }
                legacyListener = listener
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            }
        } catch (_: SecurityException) {
            // Grant revoked between the check and the register — stay inert.
        }
    }

    private fun stopListening() {
        val tm = telephony
        if (tm != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                modernCallback?.let { tm.unregisterTelephonyCallback(it) }
            }
            @Suppress("DEPRECATION")
            legacyListener?.let { tm.listen(it, PhoneStateListener.LISTEN_NONE) }
        }
        modernCallback = null
        legacyListener = null
        telephony = null
    }
}
