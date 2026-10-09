// Automatic local backup of the database.
//
// The manual export already exists and is complete; this is the same snapshot
// on a schedule, because a backup you have to remember to take is a backup
// most people do not have. Discussion #214 asked for exactly this: years of
// health data living in one place on one phone.
//
// Android can use a user-chosen document tree with a persisted access grant.
// Without one, keep the original app-specific folder. iOS keeps its Documents
// folder. Lost access is a reported failure, never a silent switch of location.
//
// WHEN IT RUNS. On foreground, when due. There is no background scheduler that
// works on both platforms — Workmanager is Android-only here and iOS's
// BGProcessingTask is best-effort — and a backup that fires when you open the
// app is honest about that. The alternative is a schedule that claims "daily"
// and delivers whenever the OS feels like it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/prefs.dart';
import '../sync/reset_gate.dart';
import 'backup_storage.dart';
import 'db.dart';

export 'backup_storage.dart' show BackupFolder, AndroidBackupStorage;

/// One JSON value keeps the folder label and grant from drifting apart.
BackupFolder? get selectedBackupFolder {
  final saved = Prefs.getString(Prefs.backupFolder, '');
  if (saved.isEmpty) return null;
  try {
    return BackupFolder.fromJson(jsonDecode(saved) as Map<String, dynamic>);
  } catch (_) {
    // Preserve the fact that a folder was selected. Falling back would write
    // somewhere the user did not choose and hide the broken configuration.
    return const BackupFolder(uri: '', name: '');
  }
}

/// Wait for any in-flight write before changing or releasing its destination.
Future<void> saveBackupFolder(BackupFolder? folder) => _serialize(() async {
  if (ResetGate.active) {
    throw const FileSystemException('Data reset is in progress');
  }
  await Prefs.ensureLoaded();
  if (!Prefs.loaded) {
    throw const FileSystemException('Could not load backup settings');
  }
  final old = selectedBackupFolder;
  final prefs = await SharedPreferences.getInstance();
  final saved = folder == null ? '' : jsonEncode(folder.toJson());
  final previous = Prefs.getString(Prefs.backupFolder, '');
  try {
    if (!await prefs.setString(Prefs.backupFolder, saved)) {
      throw const FileSystemException('Could not save the backup folder');
    }
  } catch (_) {
    // SharedPreferences updates its cache before acknowledging the disk write.
    try {
      await prefs.setString(Prefs.backupFolder, previous);
    } catch (_) {}
    rethrow;
  }
  if (old != null && old.uri != folder?.uri && Platform.isAndroid) {
    try {
      await AndroidBackupStorage.release(old);
    } catch (_) {
      // The new setting is saved; a stale grant must not undo that decision.
    }
  }
});

/// How often a backup is taken. Off is the default: this writes an unencrypted
/// copy of everything the app knows about you into a folder other apps can
/// reach, and that is a choice to make deliberately rather than one to
/// discover later.
enum BackupCadence {
  off,
  daily,
  weekly;

  String get label => switch (this) {
    BackupCadence.off => 'Off',
    BackupCadence.daily => 'Daily',
    BackupCadence.weekly => 'Weekly',
  };

  Duration? get interval => switch (this) {
    BackupCadence.off => null,
    BackupCadence.daily => const Duration(days: 1),
    BackupCadence.weekly => const Duration(days: 7),
  };

  static BackupCadence fromName(String? name) => BackupCadence.values
      .firstWhere((c) => c.name == name, orElse: () => BackupCadence.off);
}

/// Folder name. Spelled out so it is obvious what it is when someone finds it
/// in Files or a file manager.
const kBackupDirName = 'OpenStrap Backups';

/// How many backups are kept. Enough to survive noticing a problem a few days
/// late, few enough that the folder does not grow without bound — each file is
/// a full copy of the database.
const kBackupsKept = 5;

/// Whether a backup is due.
///
/// Pure, and the only place the schedule is decided. A null [lastRun] means
/// one has never been taken, which is always due — otherwise switching the
/// setting on would do nothing visible until tomorrow, and the user would
/// reasonably conclude it was broken.
bool backupIsDue({
  required BackupCadence cadence,
  required DateTime? lastRun,
  required DateTime now,
}) {
  final interval = cadence.interval;
  if (interval == null) return false;
  if (lastRun == null) return true;
  // A clock that moved backwards (timezone change, NTP correction, a user
  // setting the date) must not park the schedule in the future forever.
  if (lastRun.isAfter(now)) return true;
  return now.difference(lastRun) >= interval;
}

/// Extension for a backup written by the CURRENT code. Backups are gzipped:
/// the database is JSON-heavy and mostly text, so this is roughly a 3x saving
/// on the one thing here that is kept five times over.
const kBackupExtension = '.db.gz';

/// Filename for a backup taken at [when].
///
/// Seconds are included: two runs inside the same minute would otherwise land
/// on one name and the second would overwrite the first.
String backupFileName(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'openstrap-${when.year}${two(when.month)}${two(when.day)}'
      '-${two(when.hour)}${two(when.minute)}${two(when.second)}$kBackupExtension';
}

/// EXACTLY the shapes this file has ever emitted, and nothing else.
///
/// Retention DELETES what this matches, and it runs in a directory the user
/// can put files into. A loose `openstrap-*.db` glob would happily eat
/// someone's `openstrap-notes.db`.
///
/// Covers THREE shapes deliberately:
///   • `.db.gz` — what is written now.
///   • `.db` — what earlier versions wrote. An install that upgrades still has
///     up to [kBackupsKept] of these. If the pattern stopped matching them they
///     would become invisible to [sortBackupsNewestFirst], never be counted
///     toward retention and never be pruned — five stale full-size copies
///     leaked permanently, which is the opposite of what this change is for.
///   • a `-N` collision suffix — [_uniqueName] emits these when two runs
///     land in the same second, and the pattern never matched them, so they
///     leaked for the same reason.
final _backupNamePattern = RegExp(r'^openstrap-\d{8}-\d{6}(-\d+)?\.db(\.gz)?$');

/// Appended while a backup is still being written. Chosen so
/// [_backupNamePattern] does NOT match it: a partial file must be invisible to
/// retention, or a process killed mid-write would let a truncated backup evict
/// a good one.
const kBackupStagingSuffix = '.partial';

/// True when [basename] is one of OUR staging files.
///
/// The suffix alone is not enough. This directory is app-specific external
/// storage on Android and the file-sharing Documents directory on iOS — the
/// whole point of picking it is that users and sync clients can reach it, and
/// `.partial` is exactly what a half-finished Nextcloud or iCloud download is
/// called. Deleting on the suffix alone reached outside this feature's own
/// files, for the same reason [_backupNamePattern] is strict rather than a
/// loose `openstrap-*` glob.
bool _isOurStagingFile(String basename) {
  if (!basename.endsWith(kBackupStagingSuffix)) return false;
  final published = basename.substring(
    0,
    basename.length - kBackupStagingSuffix.length,
  );
  return _backupNamePattern.hasMatch(published);
}

/// Delete staging files left by a run that was killed mid-write.
///
/// Retention cannot do this — it only sees names it matches, and the whole
/// point of the staging suffix is that it does not. Best-effort: a leftover
/// costs disk, never correctness.
Future<void> pruneStagingFiles(Directory dir) async {
  try {
    for (final f in dir.listSync().whereType<File>()) {
      if (_isOurStagingFile(p.basename(f.path))) await f.delete();
    }
  } catch (_) {
    /* housekeeping only */
  }
}

/// Sort key for a backup filename: its timestamp, then its collision index.
///
/// NOT the raw basename. Names sort chronologically as text right up until a
/// same-second collision suffix appears, because `-` (0x2D) sorts before `.`
/// (0x2E): `…-000000-2.db.gz` compares LESS than `…-000000.db.gz`, so the
/// second backup of that second was ranked as the older one and retention
/// would evict it first. A higher index is always the later write —
/// [_uniqueName] only reaches `-2` because the unsuffixed name was taken.
(String, int) _backupSortKey(String basename) {
  final m = _backupNamePattern.firstMatch(basename);
  if (m == null) return ('', 0);
  final stamp = basename.substring(0, 'openstrap-00000000-000000'.length);
  final collision = m.group(1);
  return (stamp, collision == null ? 1 : (int.tryParse(collision.substring(1)) ?? 1));
}

/// Existing backups, newest first.
List<File> sortBackupsNewestFirst(Iterable<FileSystemEntity> entries) {
  final files = entries
      .whereType<File>()
      .where((f) => _backupNamePattern.hasMatch(p.basename(f.path)))
      .toList();
  files.sort(
    (a, b) => _compareBackupNames(p.basename(a.path), p.basename(b.path)),
  );
  return files;
}

int _compareBackupNames(String a, String b) {
  final ka = _backupSortKey(a);
  final kb = _backupSortKey(b);
  final byStamp = kb.$1.compareTo(ka.$1);
  if (byStamp != 0) return byStamp;
  final byCollision = kb.$2.compareTo(ka.$2);
  if (byCollision != 0) return byCollision;
  // Same second, same index — an upgraded install can hold both the old
  // `.db` and the new `.db.gz`. Any stable order will do; pick one.
  return b.compareTo(a);
}

/// What a backup attempt did.
class BackupOutcome {
  const BackupOutcome({this.path, this.error, this.skipped = false});

  /// The file written, or null when nothing was.
  final String? path;

  /// Why it failed, or null. A failure is REPORTED rather than swallowed —
  /// a backup silently not happening is the failure mode this whole feature
  /// exists to prevent.
  final String? error;

  /// Not due yet. Distinct from both success and failure.
  final bool skipped;

  bool get succeeded => path != null;
}

/// The backup directory, created if missing.
///
/// PLATFORM SPLIT, and it decides whether this feature works at all:
///   iOS — the app's Documents directory, which `UIFileSharingEnabled` +
///   `LSSupportsOpeningDocumentsInPlace` expose in Files.
///   Android — app-specific EXTERNAL storage. `getApplicationDocumentsDirectory`
///   resolves to `/data/user/0/<pkg>/app_flutter` there, which no file manager
///   and no sync app can reach, so backups would have been written somewhere
///   the user could never get at them. External storage needs no permission on
///   modern Android, but other apps cannot normally browse Android/data.
///   User-selected Android folders go through [AndroidBackupStorage] instead.
///
/// Falls back to the documents directory if external storage is unavailable
/// (no shared volume) — a backup somewhere awkward beats no backup.
Future<Directory> backupDirectory() async {
  Directory? root;
  if (Platform.isAndroid) {
    try {
      root = await getExternalStorageDirectory();
    } catch (_) {
      root = null;
    }
  }
  root ??= await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(root.path, kBackupDirName));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// The whole backup transaction runs under this, one at a time.
///
/// It has to cover MORE than the export. Reading `lastRun`, deciding whether a
/// backup is due, writing the file, pruning, and persisting the new `lastRun`
/// are one indivisible sequence: a guard that ended when the export finished
/// still left a window where a second trigger read the stale timestamp, judged
/// it due, and started another export. A resume can fire more than once, and a
/// cadence change lands on the same path.
Future<void> _tail = Future<void>.value();

Future<T> _serialize<T>(Future<T> Function() body) {
  final result = _tail.then((_) => body());
  // The queue must survive a failed run, or one error wedges every later
  // backup for the life of the process.
  _tail = result.then((_) {}, onError: (_) {});
  return result;
}

Future<BackupStorage> _storage() async {
  if (Platform.isAndroid) {
    await Prefs.ensureLoaded();
    if (!Prefs.loaded) {
      throw const FileSystemException('Could not load backup settings');
    }
  }
  final folder = selectedBackupFolder;
  if (Platform.isAndroid && folder != null) return AndroidBackupStorage(folder);
  return LocalBackupStorage(await backupDirectory());
}

/// Take a backup now, regardless of schedule, and prune old ones.
///
/// Serialized against every other backup path.
Future<BackupOutcome> runBackup({
  DateTime? now,
  Future<String> Function()? exportSnapshot,
  BackupStorage? storage,
}) => _serialize(
  () => _runBackup(now: now, exportSnapshot: exportSnapshot, storage: storage),
);

Future<BackupOutcome> _runBackup({
  DateTime? now,
  // Test seam. A failing export is otherwise unreachable from a test, which
  // left the queue-recovery case unverifiable.
  Future<String> Function()? exportSnapshot,
  BackupStorage? storage,
}) async {
  if (ResetGate.active) return const BackupOutcome(skipped: true);
  final when = now ?? DateTime.now();
  try {
    final destination = storage ?? await _storage();
    // `exportCopy` is VACUUM INTO — a transactionally consistent snapshot,
    // not a file copy of a database that may be mid-write.
    // Destination FIRST. Exporting before checking meant a failure here left a
    // full copy of the database sitting in temp, once per attempt.
    final name = _uniqueName(await destination.list(), when);
    if (name == null) {
      return const BackupOutcome(
        error: 'no free backup filename for this second',
      );
    }
    // WITHOUT the substrate archive: five rotating copies of an already
    // deflated year of history is the one thing gzip cannot help with. The
    // manual "Export the database" keeps it.
    final snapshot = await (exportSnapshot ??
        () => LocalDb.exportCopy(includeSubstrateArchive: false))();
    final tmp = File(snapshot);
    // Publish only after compression and the destination stream have closed.
    // A provider that cannot rename safely fails without running retention.
    BackupFile? staging;
    late BackupFile published;
    try {
      staging = await destination.write(tmp, '$name$kBackupStagingSuffix');
      published = await destination.rename(staging, name);
    } catch (_) {
      try {
        if (staging != null) await destination.delete(staging);
      } catch (_) {}
      rethrow;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }

    // Sweep any staging files a previous run was killed midway through. They
    // are invisible to retention by design, so nothing else would ever remove
    // them.
    await _pruneStorage(destination, keep: kBackupsKept);
    // A document URI means nothing to a person; show the folder they chose.
    return BackupOutcome(
      path: destination is AndroidBackupStorage
          ? '${destination.folder.name}/${published.name}'
          : published.path,
    );
  } catch (e) {
    return BackupOutcome(
      error: e is PlatformException ? (e.message ?? e.code) : e.toString(),
    );
  }
}

/// Delete all but the [keep] newest backups.
Future<void> pruneBackups(Directory dir, {required int keep}) async {
  try {
    final files = sortBackupsNewestFirst(dir.listSync());
    for (final old in files.skip(keep)) {
      await old.delete();
    }
  } catch (_) {
    // Housekeeping only — never fail a backup over cleanup.
  }
}

/// A free filename among [entries] for a backup taken at [when], or null when the
/// bounded search found none.
///
/// Seconds make a collision rare, not impossible — two manual runs inside one
/// second would otherwise share a name and the second would overwrite the
/// first. Null rather than the last candidate: returning an occupied path
/// would hand back a real snapshot for the next backup to overwrite, which is
/// the exact data loss this function exists to prevent.
String? _uniqueName(List<BackupFile> entries, DateTime when) {
  final base = backupFileName(when);
  final stem = base.substring(0, base.length - kBackupExtension.length);
  final occupied = entries.map((f) => f.name).toSet();
  for (var i = 1; i < 100; i++) {
    final candidate = i == 1 ? base : '$stem-$i$kBackupExtension';
    if (!occupied.contains(candidate) &&
        !occupied.contains('$candidate$kBackupStagingSuffix')) {
      return candidate;
    }
  }
  return null;
}

Future<void> _pruneStorage(BackupStorage storage, {required int keep}) async {
  try {
    final entries = await storage.list();
    final backups =
        entries.where((f) => _backupNamePattern.hasMatch(f.name)).toList()
          ..sort((a, b) => _compareBackupNames(a.name, b.name));
    for (final file in backups.skip(keep)) {
      await storage.delete(file);
    }
    for (final file in entries.where((f) => _isOurStagingFile(f.name))) {
      await storage.delete(file);
    }
  } catch (_) {
    // A completed backup stays successful if housekeeping fails.
  }
}

/// Called before reset clears preferences, so the selected URI is still known.
/// Serialized with writes; deletes only our exact backup and staging names.
Future<void> deleteAutomaticBackups() => _serialize(() async {
  await Prefs.ensureLoaded();
  Object? firstError = Prefs.loaded
      ? null
      : const FileSystemException('Could not load backup settings');
  final destinations = <BackupStorage>[];
  try {
    destinations.add(LocalBackupStorage(await backupDirectory()));
  } catch (e) {
    firstError ??= e;
  }
  final folder = selectedBackupFolder;
  if (Platform.isAndroid && folder != null) {
    destinations.add(AndroidBackupStorage(folder));
  }
  for (final storage in destinations) {
    try {
      for (final file in await storage.list()) {
        if (_backupNamePattern.hasMatch(file.name) ||
            _isOurStagingFile(file.name)) {
          try {
            await storage.delete(file);
          } catch (e) {
            firstError ??= e;
          }
        }
      }
    } catch (e) {
      firstError ??= e;
    }
  }
  if (firstError != null) throw firstError;
});

/// Run a backup if [cadence] says one is due.
///
/// [cadence], [lastRun] and [markRun] are all CALLBACKS rather than values, so
/// reading the setting and the timestamp, deciding, exporting and persisting
/// happen inside the same lock. Passing either in as a value would reintroduce
/// exactly the race this serialization exists to close: the caller would have
/// read it before queueing, and both a backup that finished in the meantime
/// and a setting the user changed in the meantime would be invisible to the
/// decision.
///
/// Returns a skipped outcome when nothing was due, so the caller can tell
/// "not yet" from "it broke".
Future<BackupOutcome> runBackupIfDue({
  required BackupCadence Function() cadence,
  required DateTime? Function() lastRun,
  required Future<void> Function(DateTime) markRun,
  DateTime? now,
  Future<String> Function()? exportSnapshot,
  BackupStorage? storage,
}) => _serialize(() async {
  final when = now ?? DateTime.now();
  // Cadence is read here too, for the same reason as the timestamp: a call
  // that waits behind an export would otherwise act on the setting as it was
  // when it queued. Someone who switches backup OFF while one is running would
  // still get another unencrypted copy of their health data written after
  // they disabled it.
  if (!backupIsDue(cadence: cadence(), lastRun: lastRun(), now: when)) {
    return const BackupOutcome(skipped: true);
  }
  final outcome = await _runBackup(
    now: when,
    exportSnapshot: exportSnapshot,
    storage: storage,
  );
  if (outcome.succeeded) await markRun(when);
  return outcome;
});
