package wtf.openstrap.openstrap_edge

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ActivityNotFoundException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
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
    private const val BLE_NATIVE_CHANNEL = "openstrap/ble_native"
    const val TASKER_CHANNEL = "openstrap/tasker"
    const val ACTION_DOUBLE_TAP = "wtf.openstrap.openstrap_edge.DOUBLE_TAP"
    private const val TASKER_TOKEN_KEY = "tasker_auth_token"

        /**
         * Outbound automation events broadcast as
         * `wtf.openstrap.openstrap_edge.<EVENT>` so an automation app can
         * filter on the action directly. Runtime-registered receivers (which is
         * what Tasker's "Intent Received" profile installs) still receive
         * implicit broadcasts on Android 8+; the O background restriction
         * applies to manifest-declared receivers.
         */
        const val EVENT_ACTION_PREFIX = "wtf.openstrap.openstrap_edge."

    private var torchOn = false

    // "Ring my phone" (find-my-phone). The ringtone must be retained so it can be
    // stopped — without a held reference the default TYPE_RINGTONE loops until the
    // process dies, which is why it rang until force-close (#115).
    private const val RING_TIMEOUT_MS = 30_000L
    private var activeRingtone: Ringtone? = null
    private val ringHandler = Handler(Looper.getMainLooper())
    private var ringStopRunnable: Runnable? = null

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext

        HealthConnectSleepWriter.register(engine, app)
        HealthConnectHeartRateWriter.register(engine, app)
        // The phone's own step counter. Registered here (from EdgeApplication.ensureEngine,
        // which runs on the process's FIRST engine need — cold launch or headless wake)
        // so the channel exists headless; the sensor listener itself arms on the first
        // Dart call, which only happens when the user has phone steps switched on.
        PhoneStepCounter.register(engine, app)

        MethodChannel(engine.dartExecutor.binaryMessenger, EDGE_TRACKING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // Route workout live → the FGS also claims the location type
                        // (see EdgeTrackingService.EXTRA_LOCATION). Dart always sends
                        // the flag, so the extra is always set (authoritative).
                        EdgeTrackingService.start(
                            app,
                            call.argument<Boolean>("location") == true,
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        app.stopService(Intent(app, EdgeTrackingService::class.java))
                        result.success(null)
                    }
                    // Hold the screen on for the duration of a live workout, the
                    // way every run/ride app does — the athlete is glancing at a
                    // handlebar/armband, not tapping to keep the display awake.
                    // FLAG_KEEP_SCREEN_ON is scoped to this window and released
                    // automatically if the activity goes away, so it can never
                    // leak into a permanent wakelock.
                    "keepAwake" -> {
                        val on = call.argument<Boolean>("on") == true
                        val activity = CompanionBridge.currentActivity
                        if (activity == null) {
                            result.success(false)
                        } else {
                            activity.runOnUiThread {
                                if (on) {
                                    activity.window.addFlags(
                                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                    )
                                } else {
                                    activity.window.clearFlags(
                                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                    )
                                }
                            }
                            result.success(true)
                        }
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

        // Native Bluetooth reads flutter_blue_plus cannot answer. The one
        // method here backs the gen5 readiness gate: it must read the
        // platform `BluetoothDevice.getName()` (bond/stack-backed), not the
        // plugin's in-memory platformName cache, which is empty for a device
        // rebuilt from its id on a cold start. See lib/ble/android_native_name.dart.
        MethodChannel(engine.dartExecutor.binaryMessenger, BLE_NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "remoteDeviceName" -> {
                        val mac = call.arguments as? String
                        if (mac.isNullOrEmpty()) {
                            result.error("bad_args", "expected the remote MAC", null)
                        } else {
                            remoteDeviceName(app, mac, result)
                        }
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
                    // OUTBOUND automation event. ANDROID ONLY, and deliberately
                    // so: iOS has no public mechanism for a Shortcuts personal
                    // automation to trigger on an app-donated intent — that
                    // trigger list is a fixed system set, and `donate`/
                    // INInteraction buys Siri suggestions, not an event
                    // trigger. Claiming parity in the docs would be a promise
                    // the platform cannot keep.
                    //
                    // NO TOKEN RIDES OUT. This is an implicit broadcast, so
                    // every app on the device can read its extras; putting the
                    // INBOUND buzz secret in here would hand any installed app
                    // the ability to buzz the strap, which is the one thing
                    // that token exists to prevent. The outbound direction has
                    // nothing to protect — the worst a spoofed event can do is
                    // run the user's own Tasker profile early.
                    //
                    // Extras carry only FACTS ABOUT THE SYNC (how many records
                    // landed, when), never a derived metric: a Shortcut that
                    // receives `readiness=0` has recreated the fabricated-number
                    // problem outside the app, where there is no tier and no
                    // note to read. Absence must leave as absence, and the
                    // simplest way to guarantee that is to send no metrics.
                    "emit_event" -> {
                        val name = call.argument<String>("event")
                        if (name.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            val intent = Intent("$EVENT_ACTION_PREFIX$name")
                            call.argument<Map<String, Any>>("extras")
                                ?.forEach { (k, v) ->
                                    when (v) {
                                        is Int -> intent.putExtra(k, v)
                                        is Long -> intent.putExtra(k, v)
                                        is Boolean -> intent.putExtra(k, v)
                                        is String -> intent.putExtra(k, v)
                                    }
                                }
                            app.sendBroadcast(intent)
                            result.success(true)
                        }
                    }
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

    /**
     * The platform `BluetoothDevice.getName()` read behind the gen5 readiness
     * gate. `getName()` needs BLUETOOTH_CONNECT on API 31+ — the same runtime
     * permission every GATT operation already holds by the time a link is
     * connected, checked explicitly here so a revoked grant answers as a clean
     * error instead of a SecurityException. Lint cannot see that check through
     * the early return, hence the targeted suppression; the belt-and-braces
     * catch still turns any surprise (invalid MAC, no adapter) into the same
     * error, which Dart reads as "no name" — the gate's failing value.
     */
    @SuppressLint("MissingPermission")
    private fun remoteDeviceName(app: Context, mac: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            app.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.error("name_unavailable", "BLUETOOTH_CONNECT not granted", null)
            return
        }
        try {
            val mgr = app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            result.success(mgr?.adapter?.getRemoteDevice(mac)?.name)
        } catch (e: Exception) {
            result.error("name_unavailable", e.toString(), null)
        }
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
        // Toggle: a second double-tap while it's ringing stops it early.
        if (activeRingtone?.isPlaying == true) {
            stopRing()
            return
        }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        val rt = RingtoneManager.getRingtone(ctx.applicationContext, uri) ?: return
        // Loop for the whole find-my-phone window (API 28+); older versions loop a
        // TYPE_RINGTONE by default. Either way the timeout below guarantees it stops.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) rt.isLooping = true
        activeRingtone = rt
        rt.play()
        // Register the fail-safe stop BEFORE vibrating: vibrate() can throw and
        // perform() swallows it, which must never leave the ring without a
        // scheduled stop (that was the original ring-forever failure mode).
        ringStopRunnable?.let { ringHandler.removeCallbacks(it) }
        val stop = Runnable { stopRing() }
        ringStopRunnable = stop
        ringHandler.postDelayed(stop, RING_TIMEOUT_MS)
        vibrate(ctx)
    }

    private fun stopRing() {
        ringStopRunnable?.let { ringHandler.removeCallbacks(it) }
        ringStopRunnable = null
        activeRingtone?.let { if (it.isPlaying) it.stop() }
        activeRingtone = null
    }

    // Torch via CameraManager.setTorchMode — no CAMERA permission required (API 23+).
    private fun toggleTorch(ctx: Context) {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it)
                .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return
        val desired = !torchOn
        cm.setTorchMode(camId, desired)
        torchOn = desired
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
