# Health Connect heart-rate batch export design

## Problem

OpenStrap exports every minute-average heart-rate value through
`health.writeHealthData`. In `health 11.1.1`, each Android call creates and
inserts a separate `HeartRateRecord`. A manual export therefore consumes the
Health Connect API-call quota before recent sleep sessions can be replaced.
Health Connect then returns `API call quota exceeded`; the exporter propagates
the failure, but downstream apps continue showing an older sleep session.

## Scope

- Treat the newest detected Android sleep session as the highest-priority
  Health Connect write.
- Preserve the existing Apple Health export path.
- Preserve minute-average heart-rate samples on Android.
- Change only Android continuous-heart-rate writes from one call per minute to
  one typed batch operation per calendar day.
- Keep the existing dedicated Android sleep-session writer and its ordering
  before other per-day health data.
- Propagate native `false` results and exceptions as an incomplete day export.
- Do not change derivation, sleep staging, database data, or UI behavior.

## Design

Add a project-local Android MethodChannel API that accepts a local calendar-day
start/end and ordered minute samples. Dart validates and normalizes the payload:
samples must be inside the parent interval, ordered, unique by timestamp, and
within Health Connect's valid heart-rate range.

The Android writer serializes replacements with a mutex, validates the payload
again, reads OpenStrap's prior `HeartRateRecord` data in the exact day window,
inserts one `HeartRateRecord` whose `samples` list contains all minute averages
(carrying over earlier minutes that are no longer stored locally), and only then
deletes the prior records. If the insert fails the old record stays intact; if
the delete fails the call returns `false` and the retry reads, replaces and
deletes both the old and the new record. Health Connect therefore sees a read,
an insert and a delete per re-export, rather than approximately 1,440 individual
inserts plus deletion.

Before Android starts the normal oldest-to-newest bulk loop, it exports the
newest detected sleep session once. If that priority write fails, the bulk loop
stops immediately so heart rate, workouts, old retry days, and energy cannot
consume newly recovered quota ahead of sleep. When it succeeds, the later
per-day loop reuses that result and does not write the same sleep session twice.
Older sleep sessions continue through the existing per-day export path.

When no valid samples exist, the operation is a successful no-op and does not
delete existing data. An insert/delete exception or an unexpected insertion
result returns `false`. Cancellation is rethrown. Health Connect work runs on
`Dispatchers.IO`, while MethodChannel results return on the main scope.

## Alternatives considered

1. Stop Android continuous-heart-rate export. This saves quota but loses data.
2. Throttle individual writes. At Health Connect's observed refill rate, a full
   day could take hours and remain vulnerable to interruption.
3. Vendor `health`. This creates a large dependency-maintenance burden for a
   narrow missing API.

The project-local typed writer is the smallest option that preserves behavior.

## Testing

- A Dart regression test proves a full day's minute values produce exactly one
  native batch call and no generic Android heart-rate writes.
- A regression test proves the newest Android sleep write happens before any
  other health operation, aborts bulk export on `false`, and is not duplicated
  later in the same export pass.
- Tests cover ordering, duplicate timestamps, clipping/invalid values, empty
  input, and propagation of a native `false` result.
- Android compilation verifies the pinned Health Connect constructor/API.
- Run focused health tests, formatting, `flutter analyze`, and a release APK
  build. Install the APK and manually verify that a fresh sync writes the current
  OpenStrap sleep session after the Health Connect quota has recovered.
