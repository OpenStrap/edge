import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the manual "Export database" / "Export encrypted" snapshots go.
///
/// Their own folder, not the temp root: automatic backups, issue reports and
/// the health upload also write `openstrap_export_*.db` snapshots to temp and
/// delete them when done, so a sweep over the temp root could remove one of
/// those mid-flight. Inside this folder every file belongs to a manual export.
Future<Directory> sharedExportDir() async {
  final tmp = await getTemporaryDirectory();
  final dir = Directory(p.join(tmp.path, 'db_share'));
  await dir.create(recursive: true);
  return dir;
}

/// How many manual exports survive a sweep.
///
/// Two, for the same reason the CSV export keeps two runs: the share target
/// reads the file lazily, so the previous export's file may still be open in a
/// share sheet when the next one starts. Each export is a full copy of the
/// health record (often 100+ MB, plaintext unless encrypted), and nothing else
/// ever removed them, so every tap added one more.
const kSharedExportsKept = 2;

final _exportName = RegExp(r'^openstrap_export_(\d+)\.db(\.osbk)?$');

/// Delete all but the [keep] newest manual exports in [dir].
///
/// An export is identified by the millisecond stamp in its name, so the
/// plaintext `.db` and its `.osbk` count as one export. Files that do not
/// match the export name are left alone.
Future<void> pruneSharedExports(
  Directory dir, {
  int keep = kSharedExportsKept,
}) async {
  try {
    final byStamp = <int, List<File>>{};
    for (final f in dir.listSync().whereType<File>()) {
      final m = _exportName.firstMatch(p.basename(f.path));
      if (m == null) continue;
      byStamp.putIfAbsent(int.parse(m.group(1)!), () => []).add(f);
    }
    final stamps = byStamp.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final s in stamps.skip(keep)) {
      for (final f in byStamp[s]!) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  } catch (_) {
    // Housekeeping only — a failure here must never fail the export itself.
  }
}

/// Remove manual-export copies that earlier versions left in the temp root.
///
/// Before [sharedExportDir] existed, manual exports went straight into temp
/// and were never deleted. Other features still create (and delete) their own
/// snapshots there, so only files older than [minAge] are touched: an
/// in-flight snapshot is minutes old, a leaked one is not.
Future<void> pruneLegacyRootExports(
  Directory tmpRoot, {
  Duration minAge = const Duration(days: 1),
  DateTime? now,
}) async {
  try {
    final cutoff = (now ?? DateTime.now()).subtract(minAge);
    for (final f in tmpRoot.listSync().whereType<File>()) {
      if (!_exportName.hasMatch(p.basename(f.path))) continue;
      try {
        if (f.lastModifiedSync().isBefore(cutoff)) await f.delete();
      } catch (_) {}
    }
  } catch (_) {
    // Housekeeping only.
  }
}

final _reportName = RegExp(r'^openstrap_report_(\d+)\.zip$');

/// Delete all but the [keep] newest issue-report archives in [tmpRoot].
///
/// "Share locally" hands the zip to the share sheet and, like a manual
/// export, never hears back, so the zip was never deleted — and one built
/// with the full database is a complete plaintext copy of the health record.
/// The previous one is kept in case its share sheet is still reading it.
/// [current], the archive about to be shared, is never deleted: its name
/// stamp comes from the clock, and a clock set back after earlier reports
/// would rank it oldest.
Future<void> pruneSharedReports(
  Directory tmpRoot, {
  int keep = kSharedExportsKept,
  File? current,
}) async {
  try {
    final byStamp = <int, File>{};
    for (final f in tmpRoot.listSync().whereType<File>()) {
      if (current != null && p.equals(f.path, current.path)) continue;
      final m = _reportName.firstMatch(p.basename(f.path));
      if (m != null) byStamp[int.parse(m.group(1)!)] = f;
    }
    final stamps = byStamp.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final s in stamps.skip(current == null ? keep : keep - 1)) {
      try {
        await byStamp[s]!.delete();
      } catch (_) {}
    }
  } catch (_) {
    // Housekeeping only — a failure here must never fail the share.
  }
}

final _healthCopyName = RegExp(
    r'^openstrap_(export_\d+\.db(\.osbk)?|report_\d+(\.zip|\.db\.gz)|(slice|days)_\d+\.db)$');

/// Delete every copy of the health record the app has handed to a share
/// sheet or staged in [tmpRoot]: manual exports, selected-day exports, CSV
/// runs, issue-report archives and their intermediates.
///
/// For "Delete everything". The retention sweeps above keep the newest
/// couple on purpose, and the OS purges the cache only when it likes, so a
/// reset that wiped the database still left whole plaintext copies of it
/// behind. Best effort: one undeletable file must not fail the reset.
Future<void> purgeSharedHealthCopies([Directory? tmpRoot]) async {
  try {
    tmpRoot ??= await getTemporaryDirectory();
  } catch (_) {
    return;
  }
  for (final name in const ['db_share', 'openstrap_csv']) {
    try {
      final d = Directory(p.join(tmpRoot.path, name));
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }
  try {
    for (final f in tmpRoot.listSync().whereType<File>()) {
      if (!_healthCopyName.hasMatch(p.basename(f.path))) continue;
      try {
        await f.delete();
      } catch (_) {}
    }
  } catch (_) {}
}
