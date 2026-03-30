package com.whoopconnect.whoop_connect

import android.content.Context
import android.content.Intent
import android.os.Build
import android.telecom.TelecomManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "com.whoopconnect.whoop_connect/service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cache engine for use by background services
        FlutterEngineCache.getInstance().put(WhoopNotificationService.ENGINE_ID, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    startWhoopService(0)
                    result.success(null)
                }
                "stopForegroundService" -> {
                    stopService(Intent(this, WhoopForegroundService::class.java))
                    result.success(null)
                }
                "updateNotification" -> {
                    val hr = call.argument<Int>("heartRate") ?: 0
                    startWhoopService(hr)
                    result.success(null)
                }
                "onDoubleTap" -> {
                    handleDoubleTapCallControl()
                    result.success(null)
                }
                "setHapticApps" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    WhoopNotificationService.enabledPackages.clear()
                    WhoopNotificationService.enabledPackages.addAll(packages)
                    result.success(null)
                }
                "openNotificationSettings" -> {
                    val intent = Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                "isNotificationAccessGranted" -> {
                    val flat = android.provider.Settings.Secure.getString(
                        contentResolver, "enabled_notification_listeners"
                    ) ?: ""
                    result.success(flat.contains(packageName))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startWhoopService(hr: Int) {
        val intent = Intent(this, WhoopForegroundService::class.java).apply {
            putExtra(WhoopForegroundService.EXTRA_HR, hr)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    @Suppress("DEPRECATION")
    private fun handleDoubleTapCallControl() {
        try {
            val telecom = getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // API 31+: use isInCall to detect active/ringing state
                val hasAnswerPerm = checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                if (hasAnswerPerm && telecom.isInCall) {
                    // Try to accept ringing call first, otherwise end active call
                    try {
                        telecom.acceptRingingCall()
                    } catch (_: Exception) {
                        dispatchKeyEvent(android.view.KeyEvent(
                            android.view.KeyEvent.ACTION_DOWN,
                            android.view.KeyEvent.KEYCODE_ENDCALL
                        ))
                    }
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (telecom.isInCall) {
                    val keyEvent = android.view.KeyEvent(
                        android.view.KeyEvent.ACTION_DOWN,
                        android.view.KeyEvent.KEYCODE_ENDCALL
                    )
                    dispatchKeyEvent(keyEvent)
                }
            }
        } catch (_: SecurityException) {
            // Permission not granted
        }
    }
}
