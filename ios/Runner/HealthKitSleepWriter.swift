import Flutter
import HealthKit

// HealthKit sleep replace. Mirrors Android `HealthConnectSleepWriter`: one
// channel call deletes OUR overlapping `sleepAnalysis` samples, then writes
// one `inBed` envelope plus stages.
//
// The Flutter `health` plugin is not used here. Unknown type keys (SLEEP_SESSION)
// map to bodyMass and hang `delete()`. SLEEP_LIGHT / inBed writes have been
// failing on recent iOS as Core-less ~2 h nights with leftover 11pm fragments
// (#225/#239/#249). Dart already computed the noon-to-noon cleanup window;
// this file does not re-derive local noon.

enum HealthKitSleepWriter {
  private static let channelName = "openstrap/healthkit_sleep"
  private static let store = HKHealthStore()
  private static let queue = DispatchQueue(label: "wtf.openstrap.healthkit.sleep")
  // Nap calls carry a monotonic `seq` from Dart. A native call that outlives
  // its Dart-side timeout can still land later; dropping any nap call whose
  // seq is not newer than the last applied one keeps a late replaceNap from
  // overwriting a newer deleteNapRange for the same window. Guarded by queue.
  private static var lastNapSeq = 0

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "replaceSleepSession"
          || call.method == "replaceNap"
          || call.method == "deleteNapRange" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      queue.async {
        switch call.method {
        case "replaceNap":
          replaceNap(args) { ok in
            DispatchQueue.main.async { result(ok) }
          }
        case "deleteNapRange":
          deleteRange(args) { ok in
            DispatchQueue.main.async { result(ok) }
          }
        default:
          replace(args) { ok in
            DispatchQueue.main.async { result(ok) }
          }
        }
      }
    }
  }

  // A confirmed nap: delete OUR overlapping sleepAnalysis samples in the nap
  // window, then write one inBed envelope plus one asleep sample. HealthKit
  // has no nap value (HKCategoryValueSleepAnalysis offers no nap case), so the
  // nap appears in Apple Health as an ordinary daytime sleep segment — never
  // labelled as a nap. No stage samples: a nap has no hypnogram, and writing
  // asleepCore/Deep/REM would fabricate stages. The cleanup window is the nap
  // window itself, NOT the noon-to-noon night window — it must never touch
  // the exported main sleep.
  private static func replaceNap(_ args: [String: Any], completion: @escaping (Bool) -> Void) {
    guard let seq = napSeq(args) else {
      completion(false)
      return
    }
    if staleNapCallDropped(seq, completion: completion) { return }
    guard HKHealthStore.isHealthDataAvailable() else {
      completion(true) // iPad / simulator: no store, not an export failure
      return
    }
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
          let start = dateMs(args["startTime"]),
          let end = dateMs(args["endTime"]),
          start < end else {
      completion(false)
      return
    }
    let asleepValue: HKCategoryValueSleepAnalysis
    if #available(iOS 16.0, *) {
      asleepValue = .asleepUnspecified
    } else {
      asleepValue = .asleep // deprecated pre-16 name for asleepUnspecified
    }
    let samples: [HKCategorySample] = [
      HKCategorySample(type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue, start: start, end: end),
      HKCategorySample(type: sleepType, value: asleepValue.rawValue, start: start, end: end),
    ]
    deleteAndSave(samples: samples, type: sleepType, cleanupStart: start, cleanupEnd: end, seq: napSeq(args), completion: completion)
  }

  // A nap removed/rejected in Edge: delete OUR sleepAnalysis samples
  // overlapping the window so the export does not outlive the decision.
  // [protectStartTime/protectEndTime] (optional, epoch ms) mark the current
  // main-sleep window: if the night shifted onto a previously exported nap,
  // samples overlapping that window are kept — deleting them would remove
  // the user's night from Apple Health.
  private static func deleteRange(_ args: [String: Any], completion: @escaping (Bool) -> Void) {
    guard let seq = napSeq(args) else {
      completion(false)
      return
    }
    if staleNapCallDropped(seq, completion: completion) { return }
    guard HKHealthStore.isHealthDataAvailable() else {
      completion(true)
      return
    }
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
          let start = dateMs(args["startTime"]),
          let end = dateMs(args["endTime"]),
          start < end else {
      completion(false)
      return
    }
    let protectStart = dateMs(args["protectStartTime"])
    let protectEnd = dateMs(args["protectEndTime"])
    deleteRange(samples: [], type: sleepType, start: start, end: end,
                protectStart: protectStart, protectEnd: protectEnd, seq: seq, completion: completion)
  }

  private static func napSeq(_ args: [String: Any]) -> Int? {
    (args["seq"] as? NSNumber)?.intValue
  }

  // Runs on `queue`. Returns true when the call is stale and was dropped
  // (completed with false — a dropped call never claims success).
  private static func staleNapCallDropped(_ seq: Int, completion: @escaping (Bool) -> Void) -> Bool {
    if seq <= lastNapSeq {
      completion(false)
      return true
    }
    lastNapSeq = seq
    return false
  }

  // Delete-then-save. [seq] (nap calls only) is re-checked in the delete's
  // completion callback: a newer nap call that started while this delete was
  // in flight has already bumped lastNapSeq, so this call must NOT save its
  // samples afterwards — otherwise a removed nap reappears after the newer
  // deletion. Nil seq (replaceSleepSession) skips the re-check.
  private static func deleteAndSave(
    samples: [HKCategorySample],
    type: HKCategoryType,
    cleanupStart: Date,
    cleanupEnd: Date,
    seq: Int?,
    completion: @escaping (Bool) -> Void
  ) {
    let datePred = HKQuery.predicateForSamples(withStart: cleanupStart, end: cleanupEnd, options: [])
    let sourcePred = HKQuery.predicateForObjects(from: HKSource.default())
    let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, sourcePred])
    store.deleteObjects(of: type, predicate: pred) { _, _, error in
      if error != nil {
        completion(false)
        return
      }
      if let seq, seq != lastNapSeq {
        completion(false) // superseded while the delete was in flight
        return
      }
      guard !samples.isEmpty else {
        completion(true)
        return
      }
      store.save(samples) { success, error in
        completion(success && error == nil)
      }
    }
  }

  // Delete OUR sleepAnalysis samples overlapping [start, end), except those
  // overlapping [protectStart, protectEnd) (the current main-sleep window) —
  // a night that shifted onto a previously exported nap must not be deleted
  // with it. The seq re-check happens before the delete lands.
  private static func deleteRange(
    samples: [HKCategorySample],
    type: HKCategoryType,
    start: Date,
    end: Date,
    protectStart: Date?,
    protectEnd: Date?,
    seq: Int,
    completion: @escaping (Bool) -> Void
  ) {
    let datePred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
    let sourcePred = HKQuery.predicateForObjects(from: HKSource.default())
    let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, sourcePred])
    let query = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
      guard let samples = results as? [HKCategorySample], error == nil else {
        completion(false)
        return
      }
      if seq != lastNapSeq {
        completion(false) // superseded while the query was in flight
        return
      }
      // Samples overlapping the protected main-sleep window are kept.
      let doomed = samples.filter { s in
        if let ps = protectStart, let pe = protectEnd {
          return !(s.startDate < pe && s.endDate > ps)
        }
        return true
      }
      guard !doomed.isEmpty else {
        completion(true)
        return
      }
      store.delete(doomed) { success, error in
        completion(success && error == nil)
      }
    }
    store.execute(query)
  }

  private static func replace(_ args: [String: Any], completion: @escaping (Bool) -> Void) {
    guard HKHealthStore.isHealthDataAvailable() else {
      completion(true) // iPad / simulator: no store, not an export failure
      return
    }
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      completion(false)
      return
    }
    guard let cleanupStart = dateMs(args["cleanupStartTime"]),
          let cleanupEnd = dateMs(args["cleanupEndTime"]),
          cleanupStart < cleanupEnd else {
      completion(false)
      return
    }

    let samples: [HKCategorySample]
    do {
      samples = try buildSamples(args, type: sleepType)
    } catch {
      completion(false)
      return
    }

    deleteAndSave(
      samples: samples,
      type: sleepType,
      cleanupStart: cleanupStart,
      cleanupEnd: cleanupEnd,
      seq: nil, // sleep sessions carry no seq — unchanged behavior
      completion: completion
    )
  }

  private static func buildSamples(
    _ args: [String: Any],
    type: HKCategoryType
  ) throws -> [HKCategorySample] {
    guard let start = dateMs(args["startTime"]),
          let end = dateMs(args["endTime"]) else {
      return []
    }
    guard start < end else {
      throw SleepWriteError.invalidWindow
    }

    var samples: [HKCategorySample] = [
      HKCategorySample(
        type: type,
        value: HKCategoryValueSleepAnalysis.inBed.rawValue,
        start: start,
        end: end
      ),
    ]

    let rawStages = args["stages"] as? [Any] ?? []
    var previousEnd = start
    for raw in rawStages {
      guard let map = raw as? [String: Any],
            let stageStart = dateMs(map["startTime"]),
            let stageEnd = dateMs(map["endTime"]),
            let value = sleepValue(map["stage"] as? String) else {
        throw SleepWriteError.invalidStage
      }
      guard stageStart < stageEnd,
            stageStart >= start,
            stageEnd <= end,
            stageStart >= previousEnd else {
        throw SleepWriteError.invalidStage
      }
      samples.append(
        HKCategorySample(type: type, value: value.rawValue, start: stageStart, end: stageEnd)
      )
      previousEnd = stageEnd
    }
    return samples
  }

  private static func sleepValue(_ stage: String?) -> HKCategoryValueSleepAnalysis? {
    switch stage {
    case "awake": return .awake
    case "rem":
      if #available(iOS 16.0, *) { return .asleepREM }
      return .asleep
    case "light":
      // .asleepCore is the iOS 16+ name for light sleep; on iOS 15 HealthKit
      // only has the binary .asleep. The runner target is 15.0 — without the
      // guard this file does not compile at all.
      if #available(iOS 16.0, *) { return .asleepCore }
      return .asleep
    case "deep":
      if #available(iOS 16.0, *) { return .asleepDeep }
      return .asleep
    default: return nil
    }
  }

  private static func dateMs(_ raw: Any?) -> Date? {
    guard let n = raw as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
  }

  private enum SleepWriteError: Error {
    case invalidWindow
    case invalidStage
  }
}
