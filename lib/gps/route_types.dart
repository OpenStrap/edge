/// The `sessions.type` keys that record a route.
///
/// This is the ONE list. It used to be a private set in app_state holding
/// {'run', 'cycle', 'walk', 'hike'} while the catalogue's `typeKey` is
/// `name.toLowerCase().replaceAll(' ', '_')` — so the app actually stores
/// 'running', 'cycling', 'walking', 'hiking'. Nothing matched. Not one
/// activity, ever: the eligibility check returned before it could ask for
/// location permission, which is why iOS never even listed the app under
/// Location and every session said "no route".
///
/// Keep it here rather than in ui2 so lib/state and lib/gps can read it
/// without importing the UI layer. `route_types_match_catalogue_test.dart`
/// pins it equal to the catalogue's `gps: true` entries, so adding a GPS
/// activity and forgetting this list is a red test instead of a silent
/// missing map.
const Set<String> kRouteTypeKeys = {
  'running',
  'trail_running',
  'walking',
  'dog_walking',
  'hiking',
  'cycling',
  'mountain_biking',
  'cross_country',
  'golf',
  'kayaking',
  'paddleboard',
  'skiing',
  'snowboarding',
  'skating',
  'skateboarding',
};

/// True when a session of [type] should record a route.
///
/// Case-insensitive because `sessions.type` is free-form text and older rows
/// carry mixed case.
bool typeRecordsRoute(String? type) =>
    type != null && kRouteTypeKeys.contains(type.toLowerCase());
