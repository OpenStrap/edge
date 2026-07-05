// GpsSource — the (impure) boundary between geolocator and the pure
// RouteTracker. It owns permission handling and maps platform `Position`s to
// `GpsSample`s. Nothing here is uploaded: fixes flow only into the local
// RouteTracker → workout_route table.
//
// v1 uses WHILE-IN-USE location. Continuous background ("always") location for
// screen-off tracking is a documented follow-up (see Info.plist / manifest
// notes); during a session the app is kept alive by the existing foreground
// service, so fixes keep flowing while the app is foregrounded.

import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart';

import 'route_models.dart';

/// Why (or whether) we may read GPS fixes. `granted` is the only success state;
/// the rest let the UI say WHY the map is missing instead of silently skipping.
enum GpsPermissionStatus {
  granted,
  serviceOff, // device location services are disabled
  denied, // user declined this time (can re-prompt)
  deniedForever, // user permanently declined → only Settings can fix it
  error, // platform exception while checking
}

class GpsSource {
  /// Ensure location services are on and while-in-use permission is granted,
  /// prompting the user if needed. Returns [GpsPermissionStatus.granted] only
  /// when we may read fixes; other values say why not (so the caller can show
  /// a "Location off — enable in Settings" affordance instead of silence).
  static Future<GpsPermissionStatus> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return GpsPermissionStatus.serviceOff;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      switch (perm) {
        case LocationPermission.always:
        case LocationPermission.whileInUse:
          return GpsPermissionStatus.granted;
        case LocationPermission.deniedForever:
          return GpsPermissionStatus.deniedForever;
        case LocationPermission.denied:
        case LocationPermission.unableToDetermine:
          return GpsPermissionStatus.denied;
      }
    } catch (_) {
      return GpsPermissionStatus.error;
    }
  }

  /// Open the screen that can actually fix [issue]: the app's permission page
  /// for denied/deniedForever, the system location toggle for serviceOff.
  static Future<void> openSettingsFor(GpsPermissionStatus issue) async {
    try {
      if (issue == GpsPermissionStatus.serviceOff) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (_) {}
  }

  /// A stream of GPS fixes suited to activity tracking (~5 m between fixes,
  /// best navigation accuracy), mapped to [GpsSample].
  static Stream<GpsSample> stream() {
    return Geolocator.getPositionStream(locationSettings: _settings())
        .map(_toSample);
  }

  static LocationSettings _settings() {
    const distanceFilter = 5; // metres
    const accuracy = LocationAccuracy.bestForNavigation;
    if (Platform.isAndroid) {
      // No geolocator foregroundNotificationConfig: that would spawn a SECOND
      // foreground service + notification. The app's own EdgeTrackingService is
      // already an FGS and is retyped to connectedDevice|location while a route
      // session is live (see EdgeTracking.start(location: true)), which is what
      // keeps fixes flowing when the screen turns off.
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        // Deliberately NOT enabling background location updates in v1 — the
        // "location" UIBackgroundMode is intentionally absent. The live map UI
        // shows a "keep the screen on" hint; RouteTracker's gap recovery starts
        // a fresh segment when fixes resume after an unlock.
        allowBackgroundLocationUpdates: false,
        showBackgroundLocationIndicator: false,
      );
    }
    return const LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  static GpsSample _toSample(Position p) => GpsSample(
        lat: p.latitude,
        lng: p.longitude,
        alt: p.altitude,
        accuracy: p.accuracy,
        tsMs: p.timestamp.millisecondsSinceEpoch,
      );
}
