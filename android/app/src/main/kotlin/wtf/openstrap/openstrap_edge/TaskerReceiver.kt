package wtf.openstrap.openstrap_edge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class TaskerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != ACTION_BUZZ_STRAP) return

        val pattern = intent.getIntExtra(EXTRA_PATTERN, DEFAULT_PATTERN)

        val engine = FlutterEngineCache.getInstance()
            .get(EdgeApplication.ENGINE_ID)

        if (engine != null) {
            val args = mapOf("pattern" to pattern)
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                CHANNEL
            ).invokeMethod("buzz_strap", args)
            return
        }

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
        const val ACTION_BUZZ_STRAP =
            "wtf.openstrap.openstrap_edge.BUZZ_STRAP"
        const val EXTRA_PATTERN = "pattern"
        const val PENDING_BUZZ_KEY = "pending_tasker_buzz"
        const val PENDING_PATTERN_KEY = "pending_tasker_buzz_pattern"
        const val DEFAULT_PATTERN = 2
        private const val CHANNEL = "openstrap/tasker"
    }
}
