import CoreLocation
import Flutter
import HealthKit

// HKWorkoutRoute → Dart. The `health` plugin this app already depends on reads
// workouts but has no route API whatsoever (the string "route" does not appear
// anywhere in health 11.1.1's lib/, ios/ or android/ sources), and a route is
// the one thing in an imported workout that cannot be reconstructed from the
// summary. So: the smallest possible channel — one method, coordinates only.
//
// Workouts themselves are deliberately NOT read here. The plugin already does
// that correctly on both platforms, and duplicating it natively would mean two
// definitions of "a workout" that could drift. This returns coordinates keyed
// by the workout's uuid, and Dart joins them to the workouts it already has.
//
// The uuid string is `workout.uuid.uuidString`, which is byte-identical to what
// the plugin emits for the same sample ("\(sample.uuid)"), so the join is exact
// rather than a start-time match with a tolerance.
enum HealthRouteBridge {
  private static let channelName = "openstrap/health_routes"
  private static let store = HKHealthStore()

  /// One point per this many seconds. HKWorkoutRoute delivers roughly 1 Hz, so
  /// an hour's run is ~3600 locations and a 90-day import is easily a million
  /// rows — for a line on a map that is a few hundred pixels wide.
  ///
  /// ponytail: fixed 5 s decimation. If a route ever needs real per-point
  /// analysis (grade, live pace) rather than drawing, take the raw cadence and
  /// decimate at read time instead.
  private static let minPointInterval: TimeInterval = 5

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "routes":
        guard HKHealthStore.isHealthDataAvailable() else {
          result([])  // iPad and the simulator. Not an error, just no store.
          return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        guard let fromMs = args["fromMs"] as? Int, let toMs = args["toMs"] as? Int else {
          result([])
          return
        }
        let from = Date(timeIntervalSince1970: Double(fromMs) / 1000)
        let to = Date(timeIntervalSince1970: Double(toMs) / 1000)
        let reply: ([[String: Any]]) -> Void = { payload in
          DispatchQueue.main.async { result(payload) }
        }
        // Only the manual Import tap may ask. A background/cadence pass reads
        // with whatever has already been decided; an undecided route grant
        // just reads empty there instead of popping a sheet with no tap.
        guard args["prompt"] as? Bool == true else {
          routes(from: from, to: to, completion: reply)
          return
        }
        // `HKSeriesType.workoutRoute()` is a SEPARATE read authorization from
        // the workout type, and the `health` plugin requests only the latter —
        // so without this the route query returns nothing on a store the user
        // has already granted workouts for, which is indistinguishable from
        // owning no routes. Idempotent: HealthKit re-prompts only for types the
        // user has not yet decided on.
        //
        // The grant is deliberately not checked. Apple does not report READ
        // denial (`authorizationStatus` answers for writes only, by design, so
        // an app cannot detect what it is being refused) — an empty result is
        // the only honest answer to both "denied" and "none recorded".
        store.requestAuthorization(
          toShare: [], read: [HKSeriesType.workoutRoute(), HKObjectType.workoutType()]
        ) { _, _ in
          routes(from: from, to: to, completion: reply)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Every workout in the window that HAS a route, as
  /// `[{uuid, points: [[lat, lng, alt, tsMs], …]}]`.
  ///
  /// Workouts without a route are omitted entirely rather than returned with an
  /// empty list: Dart stores the workouts from the plugin regardless, and an
  /// empty entry here would only be a second way of saying nothing.
  private static func routes(
    from: Date, to: Date, completion: @escaping ([[String: Any]]) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let query = HKSampleQuery(
      sampleType: HKObjectType.workoutType(), predicate: predicate,
      limit: HKObjectQueryNoLimit, sortDescriptors: nil
    ) { _, samples, error in
      guard let workouts = samples as? [HKWorkout], error == nil, !workouts.isEmpty else {
        completion([])
        return
      }
      // Each workout's route is its own async query, so collect under a group
      // and answer once. Serialised through a queue rather than a lock: the
      // HealthKit callbacks arrive on arbitrary threads and `out` is a value
      // type, so appending from several of them at once is a data race.
      let group = DispatchGroup()
      let queue = DispatchQueue(label: "openstrap.health.routes")
      var out: [[String: Any]] = []
      for workout in workouts {
        group.enter()
        points(for: workout) { pts in
          if !pts.isEmpty {
            queue.async {
              out.append(["uuid": workout.uuid.uuidString, "points": pts])
              group.leave()
            }
          } else {
            group.leave()
          }
        }
      }
      group.notify(queue: queue) { completion(out) }
    }
    store.execute(query)
  }

  /// The decimated coordinate list for one workout, or empty if it has none.
  private static func points(
    for workout: HKWorkout, completion: @escaping ([[Any]]) -> Void
  ) {
    let routeQuery = HKSampleQuery(
      sampleType: HKSeriesType.workoutRoute(),
      predicate: HKQuery.predicateForObjects(from: workout),
      limit: HKObjectQueryNoLimit, sortDescriptors: nil
    ) { _, samples, error in
      guard let routes = samples as? [HKWorkoutRoute], error == nil, !routes.isEmpty else {
        completion([])  // No route, or the user withheld it. Both mean no line.
        return
      }
      let group = DispatchGroup()
      let queue = DispatchQueue(label: "openstrap.health.route.points")
      var all: [CLLocation] = []
      for route in routes {
        group.enter()
        // HKWorkoutRouteQuery streams in batches and calls back repeatedly
        // until `done`. Leaving the group on anything else double-counts the
        // route and the completion fires while points are still arriving.
        let q = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
          if let locations = locations {
            queue.async { all.append(contentsOf: locations) }
          }
          if done { queue.async { group.leave() } }
        }
        store.execute(q)
      }
      group.notify(queue: queue) {
        let sorted = all.sorted { $0.timestamp < $1.timestamp }
        var out: [[Any]] = []
        var lastKept: Date?
        for loc in sorted {
          // A negative horizontal accuracy means the fix is invalid — Apple's
          // own sentinel. Drawing it puts a spike through the middle of the map.
          guard loc.horizontalAccuracy >= 0 else { continue }
          if let last = lastKept,
            loc.timestamp.timeIntervalSince(last) < minPointInterval
          {
            continue
          }
          lastKept = loc.timestamp
          out.append([
            loc.coordinate.latitude,
            loc.coordinate.longitude,
            loc.altitude,
            Int(loc.timestamp.timeIntervalSince1970 * 1000),
          ])
        }
        completion(out)
      }
    }
    store.execute(routeQuery)
  }
}
