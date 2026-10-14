import Flutter
import HealthKit

// HealthKit beat-to-beat replace. One channel call deletes OUR heartbeat series
// in the cleanup window Dart computed (the sleep replace's window), then writes
// each series through its own HKHeartbeatSeriesBuilder.
//
// The Flutter `health` plugin has no heartbeat-series type, which is also why
// this channel carries its own `requestAuthorization`: the plugin's grant sheet
// never lists HKSeriesType.heartbeat().
//
// Dart already built the series (lib/health/health_heartbeat_series.dart):
// strictly increasing offsets from each series' start, and a precededByGap
// flag per beat. This file does not re-derive anything; it refuses a malformed
// series rather than repairing it.

enum HealthKitHeartbeatWriter {
  private static let channelName = "openstrap/healthkit_heartbeat"
  private static let store = HKHealthStore()
  private static let queue = DispatchQueue(label: "wtf.openstrap.healthkit.heartbeat")

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "replaceHeartbeatSeries":
        let args = call.arguments as? [String: Any] ?? [:]
        queue.async {
          replace(args) { ok in
            DispatchQueue.main.async { result(ok) }
          }
        }
      case "requestAuthorization":
        requestAuthorization { ok in
          DispatchQueue.main.async { result(ok) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func requestAuthorization(completion: @escaping (Bool) -> Void) {
    guard HKHealthStore.isHealthDataAvailable() else {
      completion(false)
      return
    }
    store.requestAuthorization(toShare: [HKSeriesType.heartbeat()], read: nil) { ok, _ in
      completion(ok)
    }
  }

  private static func replace(_ args: [String: Any], completion: @escaping (Bool) -> Void) {
    guard HKHealthStore.isHealthDataAvailable() else {
      completion(true) // iPad / simulator: no store, not an export failure
      return
    }
    guard let cleanupStart = dateMs(args["cleanupStartTime"]),
          let cleanupEnd = dateMs(args["cleanupEndTime"]),
          cleanupStart < cleanupEnd else {
      completion(false)
      return
    }

    let series: [ParsedSeries]
    do {
      series = try (args["series"] as? [Any] ?? []).map(parse)
    } catch {
      completion(false)
      return
    }

    let datePred = HKQuery.predicateForSamples(
      withStart: cleanupStart, end: cleanupEnd, options: []
    )
    let sourcePred = HKQuery.predicateForObjects(from: HKSource.default())
    let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, sourcePred])

    store.deleteObjects(of: HKSeriesType.heartbeat(), predicate: pred) { _, _, error in
      if error != nil {
        completion(false)
        return
      }
      write(series, from: 0, allOk: true, completion: completion)
    }
  }

  /// One builder at a time, in order. A failed series does not stop the rest;
  /// the day reports false and the next export pass replaces the lot.
  private static func write(
    _ series: [ParsedSeries],
    from index: Int,
    allOk: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    guard index < series.count else {
      completion(allOk)
      return
    }
    writeOne(series[index]) { ok in
      queue.async {
        write(series, from: index + 1, allOk: allOk && ok, completion: completion)
      }
    }
  }

  private static func writeOne(_ s: ParsedSeries, completion: @escaping (Bool) -> Void) {
    let builder = HKHeartbeatSeriesBuilder(healthStore: store, device: nil, start: s.start)
    let group = DispatchGroup()
    var addOk = true
    let lock = NSLock()
    for (offset, gap) in zip(s.offsets, s.gaps) {
      group.enter()
      builder.addHeartbeatWithTimeInterval(
        sinceSeriesStartDate: offset,
        precededByGap: gap
      ) { ok, error in
        if !ok || error != nil {
          lock.lock()
          addOk = false
          lock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: queue) {
      guard addOk else {
        builder.discard()
        completion(false)
        return
      }
      builder.finishSeries { sample, error in
        completion(sample != nil && error == nil)
      }
    }
  }

  private struct ParsedSeries {
    let start: Date
    let offsets: [TimeInterval]
    let gaps: [Bool]
  }

  private static func parse(_ raw: Any) throws -> ParsedSeries {
    guard let map = raw as? [String: Any],
          let start = dateMs(map["startTime"]),
          let rawOffsets = map["offsetsMs"] as? [NSNumber],
          let rawGaps = map["precededByGap"] as? [Bool],
          rawOffsets.count == rawGaps.count,
          rawOffsets.count >= 2,
          rawOffsets.count <= HKHeartbeatSeriesBuilder.maximumCount else {
      throw HeartbeatWriteError.invalidSeries
    }
    var offsets: [TimeInterval] = []
    offsets.reserveCapacity(rawOffsets.count)
    var previous = -1.0
    for n in rawOffsets {
      let seconds = n.doubleValue / 1000.0
      guard seconds > previous else { throw HeartbeatWriteError.invalidSeries }
      offsets.append(seconds)
      previous = seconds
    }
    return ParsedSeries(start: start, offsets: offsets, gaps: rawGaps)
  }

  private static func dateMs(_ raw: Any?) -> Date? {
    guard let n = raw as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
  }

  private enum HeartbeatWriteError: Error {
    case invalidSeries
  }
}
