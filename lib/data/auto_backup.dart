// Automatic local backup of the database.
//
// The manual export already exists and is complete; this is the same snapshot
// on a schedule, because a backup you have to remember to take is a backup
// most people do not have. Discussion #214 asked for exactly this: years of
// health data living in one place on one phone.
//
// WHERE IT WRITES, and why not a folder you pick. The files go into the app's
// own documents directory, which is exposed to Files on iOS
// (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`) and to the
// file manager on Android. Anything that syncs a folder — iCloud Drive,
// Synology Drive, Nextcloud — can be pointed at it. A user-chosen folder would
// need a persisted SAF tree URI or a security-scoped bookmark, both of which
// silently expire, and a backup that quietly stopped working is worse than one
// that lives somewhere slightly less convenient.
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

/// Folder name under the documents directory. Named so it is obvious what it
/// is when someone finds it in Files.
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
String backupFileName(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'openstrap-${when.year}${two(when.month)}${two(when.day)}'
      '-${two(when.hour)}${two(when.minute)}.db';
}

/// Existing backups, newest first.
List<File> sortBackupsNewestFirst(Iterable<FileSystemEntity> entries) {
  final files = entries
      .whereType<File>()
      .where((f) => p.basename(f.path).startsWith('openstrap-'))
      .where((f) => p.extension(f.path) == '.db')
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
Future<Directory> backupDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, kBackupDirName));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Take a backup now, regardless of schedule, and prune old ones.
Future<BackupOutcome> runBackup({DateTime? now}) async {
  final when = now ?? DateTime.now();
  try {
    final dir = await backupDirectory();
    // `exportCopy` is VACUUM INTO — a transactionally consistent snapshot,
    // not a file copy of a database that may be mid-write.
    final snapshot = await LocalDb.exportCopy();
    final dest = File(p.join(dir.path, backupFileName(when)));
    await File(snapshot).rename(dest.path);
    // Best-effort: the snapshot lives in temp and a failed delete is harmless.
    try {
      final tmp = File(snapshot);
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}

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

/// Run a backup if [cadence] says one is due. Returns a skipped outcome
/// otherwise, so the caller can tell "not yet" from "it broke".
Future<BackupOutcome> runBackupIfDue({
  required BackupCadence cadence,
  required DateTime? lastRun,
  DateTime? now,
}) async {
  final when = now ?? DateTime.now();
  if (!backupIsDue(cadence: cadence, lastRun: lastRun, now: when)) {
    return const BackupOutcome(skipped: true);
  }
  return runBackup(now: when);
}
