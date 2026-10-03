package wtf.openstrap.openstrap_edge

import android.content.Context
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal data class SleepCleanupRange(val start: Instant, val end: Instant)

internal fun sleepCleanupRange(start: Instant, end: Instant, zoneId: ZoneId): SleepCleanupRange {
    require(start.isBefore(end))
    val localEnd = end.atZone(zoneId)
    val endDate = if (localEnd.toLocalTime().isBefore(LocalTime.NOON)) {
        localEnd.toLocalDate()
    } else {
        localEnd.toLocalDate().plusDays(1)
    }
    val cleanupEnd = endDate.atTime(LocalTime.NOON).atZone(zoneId).toInstant()
    val calculatedStart = endDate.minusDays(1).atTime(LocalTime.NOON).atZone(zoneId).toInstant()
    val cleanupStart = if (start.isBefore(calculatedStart)) start else calculatedStart
    return SleepCleanupRange(cleanupStart, cleanupEnd)
}

/** Writes one Health Connect sleep parent containing all normalized stages. */
object HealthConnectSleepWriter {
    private const val TAG = "OpenStrapSleepExport"
    private const val CHANNEL = "openstrap/health_connect_sleep"
    private const val REPLACE_SLEEP_SESSION = "replaceSleepSession"
    private const val CLEAR_SLEEP_SESSIONS = "clearSleepSessions"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val replaceMutex = Mutex()

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != REPLACE_SLEEP_SESSION && call.method != CLEAR_SLEEP_SESSIONS) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                scope.launch {
                    val ok = withContext(Dispatchers.IO) {
                        if (call.method == CLEAR_SLEEP_SESSIONS) clear(app, call) else replace(app, call)
                    }
                    result.success(ok)
                }
            }
    }

    @Suppress("TooGenericExceptionCaught")
    private suspend fun replace(context: Context, call: MethodCall): Boolean {
        return replaceMutex.withLock {
            try {
                if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) {
                    false
                } else {
                    val session = buildSession(call)
                    if (session == null) {
                        false
                    } else {
                        val client = HealthConnectClient.getOrCreate(context)
                        val cleanupRange = sleepCleanupRange(
                            session.startTime,
                            session.endTime,
                            ZoneId.systemDefault(),
                        )

                        // This removes both records created by this writer and legacy
                        // one-stage fragments whose intervals fall inside the real
                        // overnight window, including the portion before midnight.
                        client.deleteRecords(
                            SleepSessionRecord::class,
                            TimeRangeFilter.between(cleanupRange.start, cleanupRange.end),
                        )
                        client.insertRecords(listOf(session)).recordIdsList.size == 1
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                // Health Connect may surface several unrelated platform and
                // transport exceptions; the channel reports all of them as false.
                Log.e(TAG, "SleepSessionRecord replace failed", error)
                false
            }
        }
    }

    /** Deletes our own sleep records overlapping a day with no night left to write. */
    @Suppress("TooGenericExceptionCaught")
    private suspend fun clear(context: Context, call: MethodCall): Boolean {
        return replaceMutex.withLock {
            try {
                val start = (call.argument<Any>("startTime") as? Number)
                    ?.toLong()?.let(Instant::ofEpochMilli)
                val end = (call.argument<Any>("endTime") as? Number)
                    ?.toLong()?.let(Instant::ofEpochMilli)
                if (start == null || end == null || !start.isBefore(end) ||
                    HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE
                ) {
                    false
                } else {
                    HealthConnectClient.getOrCreate(context).deleteRecords(
                        SleepSessionRecord::class,
                        TimeRangeFilter.between(start, end),
                    )
                    true
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.e(TAG, "SleepSessionRecord clear failed", error)
                false
            }
        }
    }

    private fun buildSession(call: MethodCall): SleepSessionRecord? {
        val start = (call.argument<Any>("startTime") as? Number)
            ?.toLong()?.let(Instant::ofEpochMilli) ?: return null
        val end = (call.argument<Any>("endTime") as? Number)
            ?.toLong()?.let(Instant::ofEpochMilli) ?: return null
        if (!start.isBefore(end)) return null

        val rawStages = call.argument<List<*>>("stages").orEmpty()
        val stages = rawStages
            .mapNotNull { (it as? Map<*, *>)?.let(::buildStage) }
            .sortedBy { it.startTime }
        if (stages.isEmpty()) return null
        var previousEnd = start
        for (stage in stages) {
            if (stage.startTime.isBefore(start) || stage.endTime.isAfter(end)) return null
            if (!stage.startTime.isBefore(stage.endTime)) return null
            if (stage.startTime.isBefore(previousEnd)) return null
            previousEnd = stage.endTime
        }

        val zoneRules = ZoneId.systemDefault().rules
        return SleepSessionRecord(
            startTime = start,
            startZoneOffset = zoneRules.getOffset(start),
            endTime = end,
            endZoneOffset = zoneRules.getOffset(end),
            title = "OpenStrap sleep",
            stages = stages,
            metadata = Metadata(
                recordingMethod = Metadata.RECORDING_METHOD_AUTOMATICALLY_RECORDED,
            ),
        )
    }

    private fun buildStage(raw: Map<*, *>): SleepSessionRecord.Stage? {
        val start = (raw["startTime"] as? Number)?.toLong()?.let(Instant::ofEpochMilli)
            ?: return null
        val end = (raw["endTime"] as? Number)?.toLong()?.let(Instant::ofEpochMilli)
            ?: return null
        val type = when (raw["stage"] as? String) {
            "awake" -> SleepSessionRecord.STAGE_TYPE_AWAKE
            "rem" -> SleepSessionRecord.STAGE_TYPE_REM
            "light" -> SleepSessionRecord.STAGE_TYPE_LIGHT
            "deep" -> SleepSessionRecord.STAGE_TYPE_DEEP
            else -> return null
        }
        return SleepSessionRecord.Stage(start, end, type)
    }
}
