package wtf.openstrap.openstrap_edge

import android.Manifest
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener2
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * THE PHONE'S OWN STEP COUNT — `Sensor.TYPE_STEP_COUNTER`, not Health Connect's
 * `StepsRecord` aggregate. The aggregate is the sum of every app holding
 * WRITE_STEPS, at least one of which may itself be estimating; this is the
 * sensor hub's own count and nothing else. See lib/health/phone_pedometer.dart.
 *
 * WHAT THE PLATFORM GIVES US, AND WHAT IT DOES NOT. AOSP: the counter "reports
 * the number of steps taken by the user since the last reboot while activated"
 * and "is reset to zero only on a system reboot". So it is a monotonically
 * rising register whose absolute value is meaningless, with NO history API —
 * if nobody is watching, the delta is gone. Three consequences shape this file:
 *
 *  1. WE ACCUMULATE. Deltas between samples are bucketed into 5-minute bins in
 *     SharedPreferences, which is what makes a range query answerable at all.
 *     Five minutes rather than an hour because a local hour boundary is not a
 *     UTC hour boundary everywhere (+05:30, +05:45, +12:45) — every real UTC
 *     offset is a multiple of 15 minutes, so 5-minute bins line up exactly with
 *     the local hour boundaries the Dart hour walk asks for.
 *  2. A REBOOT IS NEVER A STEP. `raw` restarting below `lastRaw` means the
 *     device rebooted, not that the user walked `raw` steps. The stretch
 *     between our last sample and that reboot is genuinely unrecoverable, so it
 *     is recorded as a GAP and any query touching it answers NOT_COVERED — an
 *     absent answer, never a number quietly missing those steps.
 *  3. AN UNCOVERED RANGE IS NOT ZERO. A fresh install asked for yesterday has
 *     no bins at all, and returning 0 would bank a fabricated zero day that
 *     `replacePhoneCoverageForDay`'s delete-then-insert would then make sticky.
 *     Anything before `since_ms`, past retention, or across a gap is
 *     NOT_COVERED.
 *
 * The listener rides the existing EdgeTrackingService process rather than
 * adding a second service: Android 9+ withholds sensor events from background
 * processes, and a foreground service of any type lifts that.
 */
object PhoneStepCounter : SensorEventListener2 {
    private const val CHANNEL = "openstrap/phone_steps"
    private const val PREFS = "openstrap_steps"

    private const val BUCKET_MS = 5L * 60 * 1000
    private const val RETENTION_MS = 10L * 24 * 60 * 60 * 1000

    private const val KEY_LAST_RAW = "last_raw"
    private const val KEY_LAST_MS = "last_ms"
    private const val KEY_BOOT_MS = "boot_ms"
    private const val KEY_SINCE_MS = "since_ms"
    private const val KEY_GAPS = "gaps"
    private const val KEY_PRUNED_MS = "pruned_ms"
    private const val BUCKET_PREFIX = "b"

    /** Mirrors PhonePedometer.intervalNotCovered on the Dart side. */
    private const val NOT_COVERED = -1

    /**
     * The counter already holds steps taken before our first sample of a boot
     * session. We know the window they fall in ([bootMs, now)) but not how they
     * are spread through it, so we only credit them when that window is short —
     * a fresh install on a phone that has been up for three weeks would
     * otherwise smear its entire register across those weeks.
     */
    private const val MAX_BACKFILL_MS = 60L * 60 * 1000

    /** currentTimeMillis can be nudged by NTP, so boot-time equality needs slack. */
    private const val BOOT_MATCH_SLACK_MS = 120_000L

    private const val PERM_REQUEST = 8741

    private var appContext: Context? = null
    private var registered = false
    private var pendingPermission: MethodChannel.Result? = null

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        appContext = app
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(sensor(app) != null)
                    // ARMING RIDES THIS CALL, deliberately. Dart asks it at the top of
                    // every sync, and it only syncs when the user has phone steps
                    // switched on — so the listener starts for exactly the users who
                    // asked for it, on every launch, sticky restart and headless boot,
                    // and for nobody else. A process-start arm would instead count for
                    // users who had turned the feature off.
                    "authorized" -> {
                        val ok = sensor(app) != null && permitted(app)
                        if (ok) startIfPermitted(app)
                        result.success(ok)
                    }
                    "requestPermission" -> requestPermission(app, result)
                    "stop" -> {
                        stopAndForget(app)
                        result.success(null)
                    }
                    // The listener batches for up to 60 s. A three-minute calibration
                    // routine read without a flush misses up to a third of itself.
                    // Answers when the flush has COMPLETED (onFlushCompleted, after the
                    // batched events are delivered), not when it was requested. False
                    // when it was refused or did not complete within FLUSH_TIMEOUT_MS.
                    "flush" -> flush(app, result)
                    // The sensor's own running total as last delivered — exact, unlike
                    // a range query, which prorates 5-minute bins. Calibration reads it
                    // at the start and end of a routine (after a flush) and differences.
                    "rawCount" -> {
                        val r = prefs(app).getFloat(KEY_LAST_RAW, -1f)
                        result.success(if (registered && r >= 0f) r.toLong() else null)
                    }
                    "stepsInInterval" -> {
                        val from = call.argument<Number>("fromMs")?.toLong()
                        val to = call.argument<Number>("toMs")?.toLong()
                        if (from == null || to == null) {
                            result.success(null)
                        } else {
                            result.success(query(app, from, to))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── permission ──────────────────────────────────────────────────────────

    /** ACTIVITY_RECOGNITION is only enforced from API 29; below it the sensor is open. */
    private fun permitted(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(ctx: Context, result: MethodChannel.Result) {
        if (sensor(ctx) == null) {
            result.success(false)
            return
        }
        if (permitted(ctx)) {
            startIfPermitted(ctx)
            result.success(true)
            return
        }
        // Borrow the Activity the same way CompanionBridge does for the CDM dialog.
        // Headless (no Activity) there is nothing to prompt with, and reporting
        // success would leave the toggle on with no data ever arriving.
        val activity = CompanionBridge.currentActivity
        if (activity == null) {
            result.success(false)
            return
        }
        pendingPermission?.success(false) // never leave an earlier call hanging
        pendingPermission = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.ACTIVITY_RECOGNITION),
            PERM_REQUEST,
        )
    }

    /** Returns true when this result was ours (MainActivity forwards it). */
    fun handlePermissionResult(ctx: Context, requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERM_REQUEST) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) startIfPermitted(ctx)
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    // ── accumulation ────────────────────────────────────────────────────────

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun sensor(ctx: Context): Sensor? =
        (ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager)
            .getDefaultSensor(Sensor.TYPE_STEP_COUNTER)

    fun startIfPermitted(ctx: Context) {
        val app = ctx.applicationContext
        appContext = app
        if (registered || !permitted(app)) return
        val sm = app.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val s = sm.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) ?: return
        // BATCHED. The 60 s is maxReportLatency, not a sampling rate: the sensor hub
        // accumulates while the application processor sleeps and delivers in one go,
        // so this costs approximately nothing. Today's count therefore trails real
        // life by up to a minute, which no screen can tell.
        //
        // NOT raised further: attribution is delivery-time (onSensorChanged, `now`),
        // so the batch window is also the worst-case misattribution across a bin/day
        // boundary — a longer latency credits pre-midnight steps to the next day. The
        // per-delivery full-prefs-XML rewrite is the real cost here; the fix is the
        // SQLite move (see audit follow-ups), which cuts writes WITHOUT widening this.
        registered = sm.registerListener(this, s, SensorManager.SENSOR_DELAY_NORMAL, 60_000_000)
    }

    /**
     * The user turned phone steps off. Unregister and wipe the bins — leaving the
     * listener armed would keep this app counting a user who asked it to stop, and
     * the wipe also resets `since_ms`, so re-enabling starts covered from that
     * moment rather than claiming a stretch we were not watching.
     */
    private fun stopAndForget(ctx: Context) {
        val app = ctx.applicationContext
        if (registered) {
            (app.getSystemService(Context.SENSOR_SERVICE) as SensorManager)
                .unregisterListener(this)
            registered = false
        }
        prefs(app).edit().clear().apply()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    // ── flush ───────────────────────────────────────────────────────────────

    private const val FLUSH_TIMEOUT_MS = 5_000L
    private val main = Handler(Looper.getMainLooper())
    private val pendingFlushes = mutableListOf<MethodChannel.Result>()

    private fun flush(ctx: Context, result: MethodChannel.Result) {
        if (!registered) {
            result.success(false)
            return
        }
        val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        pendingFlushes.add(result)
        if (!sm.flush(this)) {
            pendingFlushes.remove(result)
            result.success(false)
            return
        }
        main.postDelayed({
            if (pendingFlushes.remove(result)) result.success(false)
        }, FLUSH_TIMEOUT_MS)
    }

    // Delivered on the listener's thread (main: registered without a handler),
    // after every batched event, so the totals are current when it fires.
    override fun onFlushCompleted(sensor: Sensor?) {
        val done = pendingFlushes.toList()
        pendingFlushes.clear()
        done.forEach { it.success(true) }
    }

    override fun onSensorChanged(event: SensorEvent) {
        val ctx = appContext ?: return
        val raw = event.values?.firstOrNull() ?: return
        // Wall clock AT DELIVERY rather than event.timestamp: that field is documented
        // as nanoseconds since boot but several OEMs populate it with wall-clock nanos,
        // and with a 60 s batch the difference costs at most a minute of attribution.
        // ponytail: delivery-time attribution, ±1 batch window; only worth swapping for
        // event.timestamp behind a per-device sanity check.
        val now = System.currentTimeMillis()
        val bootMs = now - SystemClock.elapsedRealtime()
        val p = prefs(ctx)
        val ed = p.edit()

        val lastRaw = p.getFloat(KEY_LAST_RAW, -1f)
        val lastMs = p.getLong(KEY_LAST_MS, 0L)
        val storedBoot = p.getLong(KEY_BOOT_MS, 0L)
        val rebooted = lastRaw >= 0f &&
            (raw < lastRaw || abs(bootMs - storedBoot) > BOOT_MATCH_SLACK_MS)

        if (lastRaw < 0f || rebooted) {
            // FIRST SAMPLE OF A BOOT SESSION. `raw` is everything since boot, not a
            // delta — treating it as one is exactly the "a reboot looks like 8,000
            // steps" bug.
            val canBackfill = now - bootMs <= MAX_BACKFILL_MS
            if (canBackfill) {
                if (raw >= 1f) credit(ed, p, bootMs, now, raw.toInt())
                if (rebooted && lastMs > 0L) addGap(ed, p, lastMs, bootMs)
            } else if (lastMs > 0L) {
                // Too long between boot and our first look to place those steps in
                // time. They happened; we cannot say when — so the whole stretch is
                // unknown rather than zero.
                addGap(ed, p, lastMs, now)
            }
            if (p.getLong(KEY_SINCE_MS, 0L) == 0L) {
                ed.putLong(KEY_SINCE_MS, if (canBackfill) bootMs else now)
            }
        } else {
            val delta = (raw - lastRaw).toInt()
            // Within one boot session the hub keeps counting while our process is
            // dead, so a delta spanning hours is real coverage, not a gap.
            if (delta > 0) credit(ed, p, if (lastMs > 0L) lastMs else now, now, delta)
        }

        ed.putFloat(KEY_LAST_RAW, raw)
        ed.putLong(KEY_LAST_MS, now)
        ed.putLong(KEY_BOOT_MS, bootMs)
        ed.apply()
        prune(ctx, now)
    }

    /**
     * Add [steps] to the 5-minute bins covering `[from, to)`, split by how much of
     * the span each bin holds.
     *
     * ponytail: uniform-rate split across a multi-bin span. Only reachable when a
     * batch arrives late or our process was dead through part of a boot session;
     * within a single 5-minute bin it is exact. Upgrade path is storing spans
     * instead of bins, which is what `live_coverage` itself does.
     */
    private fun credit(
        ed: SharedPreferences.Editor,
        p: SharedPreferences,
        from: Long,
        to: Long,
        steps: Int,
    ) {
        if (steps <= 0) return
        if (to <= from) {
            bump(ed, p, to / BUCKET_MS, steps)
            return
        }
        val span = (to - from).toDouble()
        val lastBin = (to - 1) / BUCKET_MS
        var bin = from / BUCKET_MS
        var placed = 0
        while (bin <= lastBin) {
            val lo = max(from, bin * BUCKET_MS)
            val hi = min(to, (bin + 1) * BUCKET_MS)
            // The final bin takes the remainder so the parts always sum to `steps`.
            val n = if (bin == lastBin) steps - placed else ((hi - lo) / span * steps).toInt()
            if (n > 0) {
                bump(ed, p, bin, n)
                placed += n
            }
            bin++
        }
    }

    private fun bump(ed: SharedPreferences.Editor, p: SharedPreferences, bin: Long, n: Int) {
        val key = "$BUCKET_PREFIX$bin"
        ed.putInt(key, p.getInt(key, 0) + n)
    }

    private fun gaps(p: SharedPreferences): List<LongArray> =
        p.getString(KEY_GAPS, "").orEmpty()
            .split(';')
            .mapNotNull {
                val parts = it.split('-')
                if (parts.size != 2) return@mapNotNull null
                val a = parts[0].toLongOrNull() ?: return@mapNotNull null
                val b = parts[1].toLongOrNull() ?: return@mapNotNull null
                if (b > a) longArrayOf(a, b) else null
            }

    private fun addGap(ed: SharedPreferences.Editor, p: SharedPreferences, from: Long, to: Long) {
        if (to <= from) return
        val kept = gaps(p) + listOf(longArrayOf(from, to))
        ed.putString(KEY_GAPS, kept.joinToString(";") { "${it[0]}-${it[1]}" })
    }

    /** Drop bins and gaps past retention. Cheap, so it runs at most once a day. */
    private fun prune(ctx: Context, now: Long) {
        val p = prefs(ctx)
        if (now - p.getLong(KEY_PRUNED_MS, 0L) < 24 * 60 * 60 * 1000L) return
        val cutoff = now - RETENTION_MS
        val oldestBin = cutoff / BUCKET_MS
        val ed = p.edit()
        for (key in p.all.keys) {
            if (!key.startsWith(BUCKET_PREFIX)) continue
            val bin = key.removePrefix(BUCKET_PREFIX).toLongOrNull() ?: continue
            if (bin < oldestBin) ed.remove(key)
        }
        ed.putString(KEY_GAPS, gaps(p).filter { it[1] >= cutoff }
            .joinToString(";") { "${it[0]}-${it[1]}" })
        ed.putLong(KEY_PRUNED_MS, now)
        ed.apply()
    }

    // ── query ───────────────────────────────────────────────────────────────

    /** null = cannot read at all; NOT_COVERED = no record; otherwise the count. */
    private fun query(ctx: Context, from: Long, to: Long): Int? {
        if (sensor(ctx) == null || !permitted(ctx)) return null
        val p = prefs(ctx)
        val since = p.getLong(KEY_SINCE_MS, 0L)
        val now = System.currentTimeMillis()
        if (since == 0L || from < since) return NOT_COVERED
        if (from < now - RETENTION_MS) return NOT_COVERED // bins are gone, not empty
        if (gaps(p).any { it[0] < to && from < it[1] }) return NOT_COVERED
        if (to <= from) return 0
        var sum = 0.0
        val lastBin = (to - 1) / BUCKET_MS
        var bin = from / BUCKET_MS
        while (bin <= lastBin) {
            val n = p.getInt("$BUCKET_PREFIX$bin", 0)
            if (n > 0) {
                val lo = max(from, bin * BUCKET_MS)
                val hi = min(to, (bin + 1) * BUCKET_MS)
                sum += n * (hi - lo).toDouble() / BUCKET_MS
            }
            bin++
        }
        return sum.roundToInt()
    }
}
