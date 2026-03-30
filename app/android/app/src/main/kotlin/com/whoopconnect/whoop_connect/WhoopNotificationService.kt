package com.whoopconnect.whoop_connect

import android.os.Handler
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Listens for notifications from selected apps and triggers WHOOP haptic.
 *
 * Grant Notification Access in: Settings > Apps > Special App Access > Notification Access.
 * Flutter updates enabledPackages via the setHapticApps MethodChannel call.
 */
class WhoopNotificationService : NotificationListenerService() {

    companion object {
        const val ENGINE_ID = "whoop_engine"
        const val CHANNEL = "com.whoopconnect.whoop_connect/service"
        val enabledPackages = mutableSetOf<String>()
    }

    private val mainHandler = Handler(android.os.Looper.getMainLooper())

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        if (!enabledPackages.contains(pkg)) return

        val engine = FlutterEngineCache.getInstance().get(ENGINE_ID) ?: return
        mainHandler.post {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("onHapticNotification", mapOf("package" to pkg))
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
    }
}
