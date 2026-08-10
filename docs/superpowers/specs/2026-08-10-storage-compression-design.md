# Storage compression — design

Date: 2026-08-10
Status: approved, implementing

## Problem

Measured on-device footprint, taken by building the real schema from
`lib/data/db.dart` into a scratch SQLite database, filling it with realistic
values, and reading per-object byte counts out of `dbstat`:

| Object | Rate | Bounded by | 1-year total |
|---|---|---|---|
| `decoded_onehz` + 2 indexes | 7.18 MB/day | 3 days | ~21.5 MB |
| `decoded_rr` + 3 b-trees | 5.40 MB/day | 3 days | ~16.2 MB |
| `day_result` (88 KB `payload_json`) | 88.1 KB/day | **never** | **~32.9 MB** |
| `metric_series` + 2 indexes | 3.0 KB/day | never | ~1.1 MB |
| **Live DB total** | | | **~72 MB** |
| Auto-backups (`kBackupsKept = 5`) | 5 × full DB | 5 copies | **~360 MB** |

Nothing is compressed at rest. `gzip` appears only at I/O boundaries: the
opt-in daily health upload (`telemetry/health_uploader.dart:89`) and container
detection on import (`import/import_container.dart`).

`day_result` is the only pool that grows without bound. The 1 Hz substrate is
capped at `rawRetentionDays = 3` and is flat, not growing.

## What the bytes actually are

`payload_json` is 88 KB, of which `series` is 74.5 KB, stored as:

```json
[{"t":1783572180,"v":77},{"t":1783572240,"v":80}]
```

27 bytes per sample to carry two numbers, with the full 10-digit epoch repeated
in every element. Across the three tracked fixtures, four curves sample on a
perfectly regular grid — `hr_curve` (dt=60), `strain_curve` (60),
`zone_timeline` (60), `skin_temp_day` (300) — and account for 85% of `series`.
The rest (`hrv_day`, `resp_day`, `hrv_timeline`) are event-timed.

This is an encoding problem, not a compression problem. Facebook's Gorilla
reaches ~12x on exactly this shape via delta-of-delta timestamps before any
general-purpose codec runs.

## Constraint that shapes the design

`payload_json` cannot become a compressed BLOB. The coach views read it with
SQL:

```sql
FROM latest l, json_each(json_extract(l.payload_json,'$.series.hypnogram')) e
```

`v_series` and `v_hypnogram` (`db.dart:1755-1791`) `json_extract` into the
payload, and `sleepAccountingDays` (`db.dart:3205`) runs `json_valid` on it.
SQLite's json1 functions cannot see inside a gzip blob, and sqflite exposes no
way to register a custom SQL decompress function. Compressing the column
silently strips every intra-day curve from the AI Coach — invariant 13, and the
§4.7 "wired into one call path but not all N" pattern.

Stacking gzip on top of the re-encoding below reaches 5.1-8.1x instead of
2.13x. It is **explicitly rejected**: it buys ~7 MB/year at the cost of the
coach's entire SQL surface.

## Design

### Wire format

Three shapes coexist permanently. All are plain JSON, so json1 still reads
them.

| Shape | Form | Written | Read |
|---|---|---|---|
| `legacy` | `[{"t":N,"v":X},…]` | never again | always |
| `grid` | `{"t0":N,"dt":N,"v":[…]}` | regular sampling | always |
| `offset` | `{"t0":N,"to":[…],"v":[…]}` | irregular sampling | always |

Legacy stays readable forever. That is what makes this migration-free: no
rewrite pass runs inside `openDatabase` under the iOS CPU watchdog
(invariant 11).

`json_each` exposes a JSON array's index as `key`, so a grid reconstructs its
timestamps as `t0 + key*dt` in pure SQL — no running sum, no extension.

### Encoder rules

Owned by one new pure file, `lib/data/series_codec.dart` (invariant 8).

- Encode only when the curve has >= 3 points and every element carries `t` plus
  the value key. `zone_timeline` uses `z`, everything else `v`.
- `grid` iff every delta is identical and positive; `offset` otherwise, with
  `to[0] == 0`.
- **Null values are preserved as `null` in `v[]`** — never dropped, never
  interpolated (invariant 3).
- Anything the encoder cannot handle passes through unchanged. The fallback is
  always "stay legacy", never "lose data".
- `hypnogram` elements are `{start,end,stage}` with no `t`, so the encoder skips
  them by construction and `v_hypnogram` needs no change.

No `kAlgoVersion` bump: values do not change, only their spelling. Bumping
would force a pointless full-history recompute.

### Three seams, one owner each

**Write** — `LocalDb.putDayResult` encodes. All four callers
(`derivation_engine` x2, `cloud_import`, `whoop_import`) already funnel through
it. Everything upstream keeps operating on plain `[{t,v}]` in memory: the
`bundle['series']` merges at `derivation_engine.dart:2490` and `:2815`, and the
patch logic at `:4793`, are untouched.

**Dart read** — `SeriesCodec.decodePayload` normalizes back to `[{t,v}]` inside
`local_repository_impl._decode` (`:46`), covering ~15 call sites at once. Five
readers live outside that funnel and each gets the same call:
`state/app_state.dart:1304`, `data/db.dart:4173` and `:4422`,
`import/whoop_import.dart:196`, `compute/derivation_engine.dart:3239`.

Normalization is safe to apply to non-`day_result` payloads that share
`_decode` (baselines, freshness, wake features): it only rewrites keys that are
in grid/offset shape, which nothing but `putDayResult` ever writes. It is
idempotent.

**SQL read** — `v_series` becomes a UNION over the three shapes for the named
curves, `zone_timeline`, and the root `activity_curve`. Each branch is guarded
so a row in one shape contributes to exactly one branch. Views are DROP+CREATE
on every open, so they need no migration.

### The duplicate index

`idx_decoded_rr_counter` is an exact duplicate of the index
`PRIMARY KEY (counter, beat_index)` already creates
(`sqlite_autoindex_decoded_rr_1`) — same table, same columns, same order.
Verified: both measured 3,264,512 bytes on a 3-day fill, and after dropping it
the planner still serves `counter` lookups and `(counter, beat_index)` ordering
from the auto-index. Saves ~1.09 MB/day plus one b-tree write on the hottest
insert path in the app.

**No `schemaVersion` bump.** The drop lives inside `_createDecodedStore`, which
`_repairOpenSchema` already re-runs on every open, so it self-heals on existing
installs and is never created on new ones. This follows the precedent one line
above it — the `idx_decoded_rr_ts` drop was done exactly this way. A ladder
entry would force `onUpgrade` to run for no additional effect.

### History backfill

New rows shrink immediately; existing rows would stay large forever. A bounded
re-encode pass runs where `pruneSupersededIntermediates` already runs — after
derivation, off the path to a durable commit, never inside a migration. It
re-encodes a capped number of legacy rows per invocation, is idempotent, and is
resumable.

### Backups and import

- `auto_backup` writes `openstrap-YYYYMMDD-HHMMSS.db.gz`.
- The retention pattern must match **both** `.db` and `.db.gz`. If it only
  matches the new name, existing backups become invisible to
  `sortBackupsNewestFirst` and are never pruned, leaking five stale copies.
- `import_container` learns to inflate gzip instead of rejecting it with "unzip
  it first", reusing the existing `_kMaxUncompressedBytes` guard.
- The manual profile export stays a plain `.db` — users open that in other
  tools.

## Error handling

Every decode path in this codebase is already `try/catch -> ignore`; the codec
keeps that contract. A malformed grid object (missing `dt`, ragged `to`/`v`)
decodes to an empty curve rather than throwing — the same observable outcome as
a missing key today.

## Testing

- `series_codec_test.dart` — lossless round-trip against all three tracked
  fixtures, plus empty, 1-2 points, embedded nulls, non-monotonic `t`,
  duplicate `t`, negative `dt`.
- `coach_views_series_shapes_test.dart` — the same day inserted in legacy and in
  encoded form must produce identical `v_series` rows. This is the regression
  pin.
- A structural guard in the style of `dart_source_test.dart`: every `jsonDecode`
  of a `payload_json` must be wrapped by the normalizer, so a future reader
  cannot silently skip it (§4.7).
- Size assertion: the encoded fixture is under 50% of the original.
- Extensions to `db_storage_hygiene_test.dart` (index gone, `counter` lookups
  still index-served), `auto_backup_test.dart` (`.gz` naming, retention across
  mixed old and new names), `import_container_test.dart` (gzip inflate, size
  guard).

## Measured outcome

Prototype run against the three tracked fixtures, with `v_series` output
compared row-for-row between the old SQL over old payloads and the new SQL over
encoded payloads:

| Fixture | Now | Encoded | Ratio | View output |
|---|---|---|---|---|
| `payload.json` | 88,053 | 32,985 | 2.67x | identical |
| `payload_july10.json` | 68,317 | 39,456 | 1.73x | identical |
| `payload_null.json` | 57,252 | 27,786 | 2.06x | identical |
| **Total** | 213,622 | 100,227 | **2.13x** | **byte-identical** |

End-to-end, rebuilding the real schema both ways and reading `dbstat` — a
one-year-old install with three days of 1 Hz substrate and five auto-backups:

| Component | Before | After | Saved |
|---|---|---|---|
| 1 Hz substrate (3-day window) | 37,703,680 | 34,443,264 | 3,260,416 |
| Derived bundles (365 days) | 26,447,872 | 12,484,608 | 13,963,264 |
| **Database file** | **65,290,240** | **48,066,560** | **1.36x** |
| Backups (5 copies) | 326,451,200 | 94,812,300 | 3.44x |
| **Total on device** | **392 MB** | **143 MB** | **2.74x** |

No decompression on any read path.

## Rejected alternatives

- **gzip `payload_json` into a BLOB** — 5.1-8.1x, but breaks `v_series` /
  `v_hypnogram` and cannot be repaired without a custom SQL function sqflite
  does not expose.
- **Native zstd (`sqlite-zstd`, `sqlite_zstd_vfs`)** — ~80% savings, but means
  FFI plus per-platform native builds wired into the riskiest part of the app.
  Dart's built-in `ZLibCodec` needs none of that and is only used where no SQL
  reads the bytes.
- **Chunked columnar blobs for the 1 Hz substrate** — a real Gorilla-style win
  per day, but the substrate is already capped at 3 days, so the steady-state
  saving is one-time and modest, while the cost is rewriting the BLE drain
  through the commit-before-ACK path (invariant 1), whose failure mode is
  permanent data loss or an infinite re-flood. Deferred. Dropping the duplicate
  index already claims 1.09 of its 12.6 MB/day for none of that risk.
- **Materializing `v_series` into a real table** — measured worse than the JSON
  it would replace (~116 KB/day naive, ~39 KB/day with interned keys, before
  the index the coach would need).
- **Tiered hot/cold split (recent days uncompressed, old days compressed)** —
  the coach auto-appends a row cap but never bounds by date, so old days would
  silently vanish from its context rather than degrade.

## References

- Gorilla: A Fast, Scalable, In-Memory Time Series Database (VLDB 2015) —
  https://www.vldb.org/pvldb/vol8/p1816-teller.pdf
- phiresky/sqlite-zstd — https://phiresky.github.io/blog/2022/sqlite-zstd/
- mlin/sqlite_zstd_vfs — https://github.com/mlin/sqlite_zstd_vfs
- Netdata tiered retention —
  https://www.netdata.cloud/features/dataplatform/tiered-retention/
