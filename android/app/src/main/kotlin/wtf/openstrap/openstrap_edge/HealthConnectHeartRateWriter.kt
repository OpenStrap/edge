package wtf.openstrap.openstrap_edge

import android.content.Context
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Replaces one day's normalized minute heart-rate samples in Health Connect. */
object HealthConnectHeartRateWriter {
    private const val TAG = "OpenStrapHeartRateExport"
    private const val CHANNEL = "openstrap/health_connect_heart_rate"
    private const val REPLACE_HEART_RATE_DAY = "replaceHeartRateDay"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val replaceMutex = Mutex()

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != REPLACE_HEART_RATE_DAY) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                scope.launch {
                    val replaced = withContext(Dispatchers.IO) { replace(app, call) }
                    result.success(replaced)
                }
            }
    }

    @Suppress("TooGenericExceptionCaught")
    private suspend fun replace(context: Context, call: MethodCall): Boolean {
        return replaceMutex.withLock {
            try {
                val request = buildRequest(call) ?: return@withLock false
                if (request.samples.isEmpty()) return@withLock true
                if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) {
                    false
                } else {
                    val client = HealthConnectClient.getOrCreate(context)
                    // The day is one record. Minutes before our first sample may
                    // no longer exist locally (the 1 Hz rows are pruned), so carry
                    // them over from the record we wrote last time rather than
                    // deleting them with it.
                    val firstNew = request.samples.first().time
                    val kept = readOwnSamples(context, client, request.start, request.end)
                        .filter { !it.time.isBefore(request.start) && it.time.isBefore(firstNew) }
                    val samples = (kept + request.samples).distinctBy { it.time }
                    client.deleteRecords(
                        HeartRateRecord::class,
                        TimeRangeFilter.between(request.start, request.end),
                    )
                    client.insertRecords(
                        listOf(
                            HeartRateRecord(
                                startTime = request.start,
                                endTime = request.end,
                                startZoneOffset = ZoneId.systemDefault().rules.getOffset(request.start),
                                endZoneOffset = ZoneId.systemDefault().rules.getOffset(request.end),
                                samples = samples,
                                metadata = Metadata(
                                    recordingMethod = Metadata.RECORDING_METHOD_AUTOMATICALLY_RECORDED,
                                ),
                            ),
                        ),
                    ).recordIdsList.size == 1
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.e(TAG, "HeartRateRecord replace failed", error)
                false
            }
        }
    }

    private suspend fun readOwnSamples(
        context: Context,
        client: HealthConnectClient,
        start: Instant,
        end: Instant,
    ): List<HeartRateRecord.Sample> {
        val out = ArrayList<HeartRateRecord.Sample>()
        var pageToken: String? = null
        do {
            val response = client.readRecords(
                ReadRecordsRequest(
                    HeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    dataOriginFilter = setOf(DataOrigin(context.packageName)),
                    pageToken = pageToken,
                ),
            )
            response.records.forEach { out.addAll(it.samples) }
            pageToken = response.pageToken
        } while (pageToken != null)
        return out.sortedBy { it.time }
    }

    private data class Request(
        val start: Instant,
        val end: Instant,
        val samples: List<HeartRateRecord.Sample>,
    )

    private fun buildRequest(call: MethodCall): Request? {
        val start = (call.argument<Any>("startTime") as? Number)
            ?.toLong()?.let(Instant::ofEpochMilli) ?: return null
        val end = (call.argument<Any>("endTime") as? Number)
            ?.toLong()?.let(Instant::ofEpochMilli) ?: return null
        if (!start.isBefore(end)) return null

        val rawSamples = call.argument<List<*>>("samples") ?: return null
        val samples = ArrayList<HeartRateRecord.Sample>(rawSamples.size)
        var previous: Instant? = null
        for (raw in rawSamples) {
            val sample = (raw as? Map<*, *>)?.let(::buildSample) ?: return null
            if (sample.time.isBefore(start) || !sample.time.isBefore(end)) return null
            if (previous != null && !previous.isBefore(sample.time)) return null
            samples.add(sample)
            previous = sample.time
        }
        return Request(start, end, samples)
    }

    private fun buildSample(raw: Map<*, *>): HeartRateRecord.Sample? {
        val time = (raw["time"] as? Number)?.toLong()?.let(Instant::ofEpochMilli)
            ?: return null
        val beatsPerMinute = (raw["beatsPerMinute"] as? Number)?.toLong() ?: return null
        if (beatsPerMinute !in 1..300) return null
        return HeartRateRecord.Sample(time, beatsPerMinute)
    }
}
