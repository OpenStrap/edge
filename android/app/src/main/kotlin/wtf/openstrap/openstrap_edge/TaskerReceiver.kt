package wtf.openstrap.openstrap_edge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class TaskerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.i(TAG, "onReceive: action=$action")
        if (action != ACTION_BUZZ_STRAP) return

        // The token rides as a plain intent extra. If Tasker (or anything
        // else) sends this as an IMPLICIT broadcast (no setPackage/
        // setComponent), Android delivers it to every app on the device with
        // a matching action intent-filter — including a hostile one that
        // declares the same action just to eavesdrop on the extras. That app
        // could then replay the captured token straight at us later. Require
        // the delivered intent to have been explicitly targeted at this app
        // (our Settings → Automation copy already instructs "set Package to
        // wtf.openstrap.openstrap_edge") BEFORE even looking at the token.
        if (intent.`package` != context.packageName &&
            intent.component?.packageName != context.packageName
        ) {
            Log.w(TAG, "rejected: not explicitly targeted at this app")
            return
        }

        // This receiver is exported with no manifest permission (a signature
        // permission would block Tasker itself, since it isn't signed by us) —
        // so anyone who can send an explicitly-targeted broadcast can still
        // reach it. Require a per-install shared secret the user copies from
        // Settings → Automation into their Tasker action, plus a short rate
        // limit as defense in depth. See NativeChannels.getOrCreateTaskerToken.
        val expected = NativeChannels.getOrCreateTaskerToken(context)
        val provided = intent.getStringExtra(EXTRA_TOKEN)
        if (provided == null || provided != expected) {
            Log.w(TAG, "rejected: missing/incorrect token")
            return
        }

        val nowElapsed = SystemClock.elapsedRealtime()
        if (nowElapsed - lastAcceptedElapsedMs < MIN_INTERVAL_MS) {
            Log.w(TAG, "rejected: rate-limited (< ${MIN_INTERVAL_MS}ms since last accepted broadcast)")
            return
        }
        lastAcceptedElapsedMs = nowElapsed

        val pattern = intent.getIntExtra(EXTRA_PATTERN, DEFAULT_PATTERN)
        Log.i(TAG, "pattern=$pattern")

        val engine = FlutterEngineCache.getInstance()
            .get(EdgeApplication.ENGINE_ID)

        if (engine != null) {
            Log.i(TAG, "engine alive, invoking method channel")
            val args = java.util.HashMap<String, Any>()
            args["pattern"] = pattern
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                NativeChannels.TASKER_CHANNEL
            ).invokeMethod("buzz_strap", args)
            return
        }

        Log.i(TAG, "engine dead, persisting pending flag")
        val prefs = context.getSharedPreferences(
            "openstrap_runtime",
            Context.MODE_PRIVATE
        )
        prefs.edit()
            .putBoolean(PENDING_BUZZ_KEY, true)
            .putInt(PENDING_PATTERN_KEY, pattern)
            .apply()

        val svcIntent = Intent(context, EdgeTrackingService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(svcIntent)
        } else {
            context.startService(svcIntent)
        }
    }

    companion object {
        const val TAG = "TaskerReceiver"
        const val ACTION_BUZZ_STRAP =
            "wtf.openstrap.openstrap_edge.BUZZ_STRAP"
        const val EXTRA_PATTERN = "pattern"
        const val EXTRA_TOKEN = "token"
        const val PENDING_BUZZ_KEY = "pending_tasker_buzz"
        const val PENDING_PATTERN_KEY = "pending_tasker_buzz_pattern"
        const val DEFAULT_PATTERN = 2
        private const val MIN_INTERVAL_MS = 1500L

        // Process-lifetime, not persisted — a fresh process restarting the
        // rate-limit window on cold start is fine; the goal is only to blunt a
        // tight resend loop within one running process.
        @Volatile
        private var lastAcceptedElapsedMs = 0L
    }
}
