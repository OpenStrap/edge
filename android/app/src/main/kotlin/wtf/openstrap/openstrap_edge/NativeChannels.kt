package wtf.openstrap.openstrap_edge

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ActivityNotFoundException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channels for the app. Registered on the long-lived engine at creation time
 * (see EdgeApplication) so they keep working when Dart runs headless (no Activity). All
 * use the application Context — none of these actions need an Activity.
 */
object NativeChannels {
    private const val EDGE_TRACKING_CHANNEL = "openstrap/edge_tracking"
    private const val DEVICE_ACTIONS_CHANNEL = "openstrap/device_actions"
    private const val ANDROID_BG_CHANNEL = "openstrap/android_background"
    const val TASKER_CHANNEL = "openstrap/tasker"
    const val ACTION_DOUBLE_TAP = "wtf.openstrap.openstrap_edge.DOUBLE_TAP"
    private const val TASKER_TOKEN_KEY = "tasker_auth_token"

    private var torchOn = false

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext

        MethodChannel(engine.dartExecutor.binaryMessenger, EDGE_TRACKING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(app, EdgeTrackingService::class.java)
                        // Route workout live → the FGS also claims the location type
                        // (see EdgeTrackingService.EXTRA_LOCATION).
                        val location = call.argument<Boolean>("location") == true
                        intent.putExtra(EdgeTrackingService.EXTRA_LOCATION, location)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            app.startForegroundService(intent)
                        } else {
                            app.startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        app.stopService(Intent(app, EdgeTrackingService::class.java))
                        result.success(null)
                    }
                    "consumeHeadlessBootPending" -> {
                        val prefs = app.getSharedPreferences(
                            "openstrap_runtime",
                            Context.MODE_PRIVATE
                        )
                        val pending = prefs.getBoolean("pending_headless_boot", false)
                        val eligible = pending && !MainActivity.activityAttached
                        if (eligible) {
                            prefs.edit().putBoolean("pending_headless_boot", false).apply()
                        }
                        result.success(eligible)
                    }
                    else -> result.notImplemented()
                }
            }

        // OS keep-alive integrations: CompanionDeviceManager association (background
        // FGS exemption + device-presence relaunch) and the battery-optimization
        // (Doze) exemption. See CompanionBridge.kt / lib/ble/android_background.dart.
        MethodChannel(engine.dartExecutor.binaryMessenger, ANDROID_BG_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "associateCompanion" -> {
                        val mac = call.arguments as? String ?: ""
                        CompanionBridge.associate(app, mac, result)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(app.packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestIgnoreBatteryOptimizations(app))
                    }
                    "manufacturerHint" -> result.success(Build.MANUFACTURER.lowercase())
                    "isBackgroundRestricted" -> {
                        result.success(isBackgroundRestricted(app))
                    }
                    "openOemAutostartSettings" -> {
                        result.success(openOemAutostartSettings(app))
                    }
                    else -> result.notImplemented()
                }
            }

        // Band-gesture actions. All no-risk OS APIs: media-key dispatch (works for any
        // player, no permission), system media volume, ringtone + vibrate, torch.
        MethodChannel(engine.dartExecutor.binaryMessenger, DEVICE_ACTIONS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(
                        listOf(
                            "media_play_pause", "media_next", "media_prev",
                            "volume_up", "volume_down", "ring_phone", "torch",
                            "broadcast_to_tasker"
                        )
                    )
                    "perform" -> result.success(perform(app, call.argument<String>("action") ?: ""))
                    else -> result.notImplemented()
                }
            }

        // Tasker integration support. TaskerReceiver (a BroadcastReceiver, not a
        // Flutter plugin) writes directly to the native "openstrap_runtime"
        // SharedPreferences file — NOT through the shared_preferences PLUGIN,
        // which owns a separate, plugin-managed store (its own file, with
        // flutter.-prefixed keys) that can never see what a native-only
        // BroadcastReceiver wrote. Dart must go through this channel instead
        // of SharedPreferences.getInstance() to see/clear the pending buzz, or
        // to read the per-install auth token TaskerReceiver requires.
        MethodChannel(engine.dartExecutor.binaryMessenger, TASKER_CHANNEL)
            .setMethodCallHandler { call, result ->
                val prefs = app.getSharedPreferences("openstrap_runtime", Context.MODE_PRIVATE)
                when (call.method) {
                    "peek_pending_buzz" -> {
                        val pending = prefs.getBoolean(TaskerReceiver.PENDING_BUZZ_KEY, false)
                        result.success(
                            if (pending) {
                                prefs.getInt(TaskerReceiver.PENDING_PATTERN_KEY, TaskerReceiver.DEFAULT_PATTERN)
                            } else {
                                null
                            }
                        )
                    }
                    "clear_pending_buzz" -> {
                        prefs.edit()
                            .remove(TaskerReceiver.PENDING_BUZZ_KEY)
                            .remove(TaskerReceiver.PENDING_PATTERN_KEY)
                            .apply()
                        result.success(null)
                    }
                    "get_auth_token" -> result.success(getOrCreateTaskerToken(app))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Per-install shared secret Tasker (or any automation app) must echo back
     * as the `token` string extra on a BUZZ_STRAP broadcast (see
     * TaskerReceiver.onReceive). Generated once and persisted in the native
     * "openstrap_runtime" prefs; surfaced to Dart (Settings → Automation,
     * copy-to-clipboard) via [TASKER_CHANNEL]. Without this, the exported,
     * permission-less receiver would let ANY installed app trigger strap
     * haptics on demand — including the alarm-mode pattern, which buzzes
     * until acknowledged. A manifest `android:permission` isn't viable here:
     * Tasker can't declare a permission for our arbitrary custom string ahead
     * of time, so it would just block the legitimate use case too.
     */
    internal fun getOrCreateTaskerToken(ctx: Context): String {
        val prefs = ctx.getSharedPreferences("openstrap_runtime", Context.MODE_PRIVATE)
        prefs.getString(TASKER_TOKEN_KEY, null)?.let { return it }
        val token = java.util.UUID.randomUUID().toString().replace("-", "")
        prefs.edit().putString(TASKER_TOKEN_KEY, token).apply()
        return token
    }

    private fun perform(ctx: Context, action: String): Boolean {
        return try {
            when (action) {
                "media_play_pause" -> dispatchMediaKey(ctx, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                "media_next" -> dispatchMediaKey(ctx, KeyEvent.KEYCODE_MEDIA_NEXT)
                "media_prev" -> dispatchMediaKey(ctx, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                "volume_up" -> adjustVolume(ctx, AudioManager.ADJUST_RAISE)
                "volume_down" -> adjustVolume(ctx, AudioManager.ADJUST_LOWER)
                "ring_phone" -> ringPhone(ctx)
                "torch" -> toggleTorch(ctx)
                "broadcast_to_tasker" -> sendTaskerBroadcast(ctx)
                else -> return false
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Fire the system "ignore battery optimizations?" dialog for this app
     * (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS — allowed because the manifest
     * declares REQUEST_IGNORE_BATTERY_OPTIMIZATIONS). Returns whether the intent
     * launched; false if already exempt (no-op) or the OS blocked it.
     */
    private fun requestIgnoreBatteryOptimizations(ctx: Context): Boolean {
        return try {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) return true
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${ctx.packageName}"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Whether the OS is CURRENTLY restricting this app's background work —
     * the one official, CTS-tested, documented signal for this situation
     * (`ActivityManager.isBackgroundRestricted`, API 28+): "if true, any work
     * that the app tries to do will be aggressively restricted while it is in
     * the background... jobs and alarms will not execute and foreground
     * services cannot be started." This is what actually gates whether the
     * OEM-autostart entry point below should even be surfaced to the user —
     * NOT a manufacturer-name guess, which can't tell whether the OS is
     * presently restricting anything at all. False on API <28 (unsupported,
     * so we can't tell — callers fall back to the manufacturer hint alone in
     * that case, same as before).
     */
    private fun isBackgroundRestricted(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.isBackgroundRestricted
    }

    /**
     * OEM autostart/battery-manager allowlist deep link — a second, stronger
     * line of defense than [requestIgnoreBatteryOptimizations]. The stock
     * Android Doze exemption is well-known to be INSUFFICIENT on Xiaomi
     * (MIUI)/Huawei/Honor/Oppo (ColorOS)/Vivo (FuntouchOS)/OnePlus — these
     * OEMs layer their own aggressive process killers on top of stock Doze
     * and gate survival behind a separate "autostart"/"protected apps" list
     * that stock APIs cannot toggle. There is NO official Android API for
     * this specific mechanism (confirmed against developer.android.com's
     * Doze/App-Standby guide, which never mentions OEM autostart screens);
     * the settings-activity ComponentNames below are long-standing
     * community-documented ones (the "autostarter" pattern), not a Google
     * source, and can change across OEM software versions — every attempt
     * is wrapped so a missing/renamed activity on some device just falls
     * through to the next candidate, never crashes. Falls back to this app's
     * standard "App info" settings page (always resolvable) if no
     * OEM-specific screen exists on this device — so the user always lands
     * somewhere useful, never a silent no-op. Dart gates whether to even
     * OFFER this (via [isBackgroundRestricted]) rather than firing it
     * unconditionally off the manufacturer string — see
     * AndroidBackground.needsOemAutostartSettings.
     */
    private fun openOemAutostartSettings(ctx: Context): String {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val candidates: List<ComponentName> = when {
            manufacturer.contains("xiaomi") -> listOf(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.powercenter.PowerSettings",
                ),
            )
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> listOf(
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                ),
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity",
                ),
            )
            manufacturer.contains("oppo") || manufacturer.contains("realme") -> listOf(
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                ),
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.startupapp.StartupAppListActivity",
                ),
            )
            manufacturer.contains("vivo") -> listOf(
                ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                ),
                ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                ),
            )
            manufacturer.contains("oneplus") -> listOf(
                ComponentName(
                    "com.oneplus.security",
                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
                ),
            )
            else -> emptyList()
        }

        for (component in candidates) {
            try {
                val intent = Intent().apply {
                    setComponent(component)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                ctx.startActivity(intent)
                return "opened_oem_autostart"
            } catch (e: ActivityNotFoundException) {
                continue // try the next candidate / fall through to app-info
            } catch (e: SecurityException) {
                continue
            }
        }

        return try {
            val fallback = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${ctx.packageName}"),
            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            ctx.startActivity(fallback)
            "opened_app_info_fallback"
        } catch (e: Exception) {
            "failed"
        }
    }

    private fun audio(ctx: Context): AudioManager =
        ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun dispatchMediaKey(ctx: Context, keyCode: Int) {
        val am = audio(ctx)
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
    }

    private fun adjustVolume(ctx: Context, direction: Int) {
        audio(ctx).adjustStreamVolume(
            AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI
        )
    }

    private fun ringPhone(ctx: Context) {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        RingtoneManager.getRingtone(ctx.applicationContext, uri)?.play()
        vibrate(ctx)
    }

    // Torch via CameraManager.setTorchMode — no CAMERA permission required (API 23+).
    private fun toggleTorch(ctx: Context) {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it)
                .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return
        torchOn = !torchOn
        cm.setTorchMode(camId, torchOn)
    }

    @Suppress("DEPRECATION")
    private fun vibrate(ctx: Context) {
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(500, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            vibrator.vibrate(500)
        }
    }

    /** Send a broadcast intent so Tasker (or any automation app) can subscribe
     * to band double-taps. The intent action is
     * `wtf.openstrap.openstrap_edge.DOUBLE_TAP`; Tasker listens via
     * Event → Intent Received.
     */
    private fun sendTaskerBroadcast(ctx: Context) {
        val intent = Intent(ACTION_DOUBLE_TAP).apply {
            addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
        }
        ctx.sendBroadcast(intent)
    }

}
