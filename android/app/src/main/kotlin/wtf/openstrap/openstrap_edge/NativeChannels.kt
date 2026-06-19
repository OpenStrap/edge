package wtf.openstrap.openstrap_edge

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
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

    private var torchOn = false

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext

        MethodChannel(engine.dartExecutor.binaryMessenger, EDGE_TRACKING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(app, EdgeTrackingService::class.java)
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
                            "volume_up", "volume_down", "ring_phone", "torch"
                        )
                    )
                    "perform" -> result.success(perform(app, call.argument<String>("action") ?: ""))
                    else -> result.notImplemented()
                }
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
                else -> return false
            }
            true
        } catch (e: Exception) {
            false
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
}
