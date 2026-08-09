// Automatic local backup of the database.
//
// The manual export already exists and is complete; this is the same snapshot
// on a schedule, because a backup you have to remember to take is a backup
// most people do not have. Discussion #214 asked for exactly this: years of
// health data living in one place on one phone.
//
// WHERE IT WRITES, and why not a folder you pick. Somewhere the user can
// actually reach — see [backupDirectory], which is per-platform for exactly
// that reason. Anything that syncs a folder (iCloud Drive, Synology Drive,
// Nextcloud) can be pointed at it. A user-chosen folder would need a persisted
// SAF tree URI or a security-scoped bookmark, both of which silently expire,
// and a backup that quietly stopped working is worse than one that lives
// somewhere slightly less convenient.
//
// WHEN IT RUNS. On foreground, when due. There is no background scheduler that
// works on both platforms — Workmanager is Android-only here and iOS's
// BGProcessingTask is best-effort — and a backup that fires when you open the
// app is honest about that. The alternative is a schedule that claims "daily"
// and delivers whenever the OS feels like it.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';

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

/// Filename for a backup taken at [when]. Sorts chronologically as text, so
/// retention can order by name without parsing.
///
/// Seconds are included: two runs inside the same minute would otherwise land
/// on one name and the second would overwrite the first.
String backupFileName(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'openstrap-${when.year}${two(when.month)}${two(when.day)}'
      '-${two(when.hour)}${two(when.minute)}${two(when.second)}.db';
}

/// EXACTLY the shape [backupFileName] emits, and nothing else.
///
/// Retention DELETES what this matches, and it runs in a directory the user
/// can put files into. A loose `openstrap-*.db` glob would happily eat
/// someone's `openstrap-notes.db`.
final _backupNamePattern = RegExp(r'^openstrap-\d{8}-\d{6}\.db$');

/// Existing backups, newest first.
List<File> sortBackupsNewestFirst(Iterable<FileSystemEntity> entries) {
  final files = entries
      .whereType<File>()
      .where((f) => _backupNamePattern.hasMatch(p.basename(f.path)))
      .toList();
  files.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
  return files;
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
///   modern Android and is browsable.
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

/// Take a backup now, regardless of schedule, and prune old ones.
///
/// Serialized against every other backup path.
Future<BackupOutcome> runBackup({
  DateTime? now,
  Future<String> Function()? exportSnapshot,
}) => _serialize(() => _runBackup(now: now, exportSnapshot: exportSnapshot));

Future<BackupOutcome> _runBackup({
  DateTime? now,
  // Test seam. A failing export is otherwise unreachable from a test, which
  // left the queue-recovery case unverifiable.
  Future<String> Function()? exportSnapshot,
}) async {
  final when = now ?? DateTime.now();
  try {
    final dir = await backupDirectory();
    // `exportCopy` is VACUUM INTO — a transactionally consistent snapshot,
    // not a file copy of a database that may be mid-write.
    // Destination FIRST. Exporting before checking meant a failure here left a
    // full copy of the database sitting in temp, once per attempt.
    final dest = _uniqueDestination(dir, when);
    if (dest == null) {
      return const BackupOutcome(
        error: 'no free backup filename for this second',
      );
    }
    final snapshot = await (exportSnapshot ?? LocalDb.exportCopy)();
    final tmp = File(snapshot);
    try {
      await tmp.rename(dest.path);
    } on FileSystemException {
      // The temp directory and external storage are different filesystems on
      // Android, where rename fails outright — copy across, then drop the
      // source.
      await tmp.copy(dest.path);
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }

    await pruneBackups(dir, keep: kBackupsKept);
    return BackupOutcome(path: dest.path);
  } catch (e) {
    return BackupOutcome(error: e.toString());
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

/// A FREE filename in [dir] for a backup taken at [when], or null when the
/// bounded search found none.
///
/// Seconds make a collision rare, not impossible — two manual runs inside one
/// second would otherwise share a name and the second would overwrite the
/// first. Null rather than the last candidate: returning an occupied path
/// would hand back a real snapshot for the next backup to overwrite, which is
/// the exact data loss this function exists to prevent.
File? _uniqueDestination(Directory dir, DateTime when) {
  final base = backupFileName(when);
  final stem = base.substring(0, base.length - 3); // drop '.db'
  for (var i = 1; i < 100; i++) {
    final candidate = File(
      p.join(dir.path, i == 1 ? base : '$stem-$i.db'),
    );
    if (!candidate.existsSync()) return candidate;
  }
  return null;
}

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
  final outcome = await _runBackup(now: when, exportSnapshot: exportSnapshot);
  if (outcome.succeeded) await markRun(when);
  return outcome;
});
