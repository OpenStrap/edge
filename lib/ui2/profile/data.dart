// Your data — getting it out, keeping a copy, bringing one back.
//
// Everything here was already written, tested, and reachable from nothing.
// `csv_export.dart`, `LocalDb.exportCopy`, `auto_backup.dart` and the four
// importers all existed; the only code that read the whole database out of
// the app was the UPLOAD path. So the app told the user to "export first"
// immediately before the one destructive action in it, and there was no
// export; and the automatic backup defaulted to off with no way to turn it
// on, which made the foreground hook a permanent no-op and the new-phone
// story "you don't have one".
//
// A local-first app whose data cannot leave is not local-first, it is trapped.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/auto_backup.dart';
import '../../data/csv_export.dart';
import '../../data/db.dart';
import '../../import/backup_crypto.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/clock_format.dart' show formatClockOf;
import '../activity/share.dart' show shareOrigin;
import '../onboarding/welcome.dart'
    show
        ImportOutcome,
        ImportReport,
        PassphraseCancelled,
        askBackupPassphrase,
        runImport;
import '../screens/home_screen.dart' show dbRebuiltCard;
import '../ui2.dart';
import 'phone_import.dart';
import 'profile.dart';

/// What an action has to say for itself: the line to show, and whether it is a
/// failure. Without the second half every outcome rendered as "Done ✓".
typedef _Note = (String text, bool failed);

class DataScreen extends StatefulWidget {
  const DataScreen({super.key});

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  bool _busy = false;
  String? _note;

  /// Whether [_note] is a failure. Every outcome used to render as "Done" with
  /// a green check — a thrown FileSystemException from the export included.
  bool _noteFailed = false;
  ImportOutcome? _outcome;

  void _say(String s, {bool failed = false}) {
    if (mounted) {
      setState(() {
        _note = s;
        _noteFailed = failed;
      });
    }
  }

  /// Run [job] with the screen locked, reporting whatever it says or throws.
  ///
  /// Every action on this screen is slow, destructive-adjacent or both, and a
  /// second tap while one is running would race the first over the same files.
  Future<void> _run(Future<_Note> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
      _outcome = null;
    });
    final l = AppLocalizations.of(context);
    try {
      final (text, failed) = await job();
      _say(text, failed: failed);
    } on PassphraseCancelled {
      // Closing the passphrase prompt is a decision. "Failed:" over it would
      // report the user's own choice back to them as a fault.
    } catch (e) {
      _say(l?.dataFailed(e.toString()) ?? 'Failed: $e',
          failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_Note> _exportCsv() async {
    final l = AppLocalizations.of(context);
    // Read before the export runs: an anchor taken after a multi-second await
    // may be measuring a screen the user has already left.
    final origin = shareOrigin(context);
    final res = await exportCsvFiles(kCsvExportSets);
    if (res.paths.isEmpty) {
      return res.hasFailures
          ? (l?.dataNothingExportedFailed(res.failed.join(', ')) ??
                  'Nothing exported (${res.failed.join(', ')} failed).',
              true)
          : (l?.dataNothingToExportYet ?? 'Nothing to export yet.', false);
    }
    await Share.shareXFiles([for (final p in res.paths) XFile(p)],
        subject: 'OpenStrap export', sharePositionOrigin: origin);
    final n = res.paths.length;
    final failed = res.hasFailures
        ? ' ${l?.dataSetsFailed(res.failed.length, res.failed.join(', ')) ?? '${res.failed.length} set(s) failed: ${res.failed.join(', ')}.'}'
        : '';
    return (
      (l?.dataFilesShared(n) ?? '$n file${n == 1 ? '' : 's'} shared.') + failed,
      res.hasFailures
    );
  }

  Future<_Note> _exportDb() async {
    final l = AppLocalizations.of(context);
    final origin = shareOrigin(context);
    // VACUUM INTO — a transactionally consistent snapshot, not a file copy.
    final path = await LocalDb.exportCopy();
    await Share.shareXFiles([XFile(path)],
        subject: 'OpenStrap database', sharePositionOrigin: origin);
    return (
      l?.dataDatabaseShared ?? 'Database shared. It is the complete copy.',
      false
    );
  }

  /// The same VACUUM'd snapshot as [_exportDb], sealed with AES-256-GCM under
  /// a key derived from a passphrase this app never stores.
  ///
  /// The plaintext intermediate is deleted whatever happens: an encrypted
  /// backup that leaves a readable copy of the whole health record in the
  /// share directory has encrypted nothing.
  Future<_Note> _exportEncrypted() async {
    final pass = await askBackupPassphrase(context, creating: true);
    if (pass == null) return ('', false); // cancelled
    if (!mounted) return ('', false);
    final l = AppLocalizations.of(context);
    final origin = shareOrigin(context);
    final plain = await LocalDb.exportCopy();
    final dest = '$plain.osbk';
    try {
      // 210 000 PBKDF2 rounds is seconds of solid CPU. On the UI isolate that
      // is a frozen app; nothing in the crypto path touches a plugin, which is
      // what makes the worker legal.
      await Isolate.run(
          () => encryptBackupFile(File(plain), File(dest), pass));
    } finally {
      try {
        await File(plain).delete();
      } catch (_) {}
    }
    await Share.shareXFiles([XFile(dest)],
        subject: 'OpenStrap encrypted backup', sharePositionOrigin: origin);
    return (
      l?.dataEncryptedBackupShared ??
          'Encrypted backup shared. Without that passphrase nobody can open it — '
              'including this app, and including us.',
      false
    );
  }

  Future<_Note> _reanalyze(AppState app) async {
    final l = AppLocalizations.of(context);
    final ml = MaterialLocalizations.of(context);
    Future<Map<String, int>> recovery() async => {
          for (final r in await LocalDb.metricSeries('readiness'))
            r['date'] as String: (r['value'] as num).round(),
        };
    final before = await recovery();
    final n = await app.reanalyzeAll();
    final after = await recovery();
    // Which days' recovery a re-analysis actually moved, newest first.
    // ponytail: first 5 only; the note is a heads-up, not an audit log.
    final changed = [
      for (final e in after.entries)
        if (before[e.key] != null && before[e.key] != e.value)
          (day: e.key, from: before[e.key]!, to: e.value),
    ].reversed.take(5).map((c) {
      final d = DateTime.tryParse(c.day);
      final label = d == null ? c.day : ml.formatShortMonthDay(d);
      return '$label ${c.from} → ${c.to}';
    }).join(', ');
    final done =
        l?.dataDaysReanalyzed(n) ?? '$n day${n == 1 ? '' : 's'} re-analyzed.';
    return (
      changed.isEmpty
          ? done
          : '$done ${l?.dataRecoveryChanged(changed) ?? 'Recovery changed: $changed'}',
      false
    );
  }

  Future<_Note> _backupNow(AppState app) async {
    final l = AppLocalizations.of(context);
    final outcome = await app.runBackupNow();
    if (outcome.error != null) {
      return (l?.dataBackupFailed(outcome.error!) ?? 'Backup failed: ${outcome.error}', true);
    }
    if (!outcome.succeeded) {
      return (l?.dataBackupSkipped ?? 'Backup skipped.', false);
    }
    return (l?.dataBackedUpTo(outcome.path!) ?? 'Backed up to ${outcome.path}', false);
  }

  Future<_Note> _chooseBackupFolder(AppState app) async {
    final l = AppLocalizations.of(context);
    final folder = await AndroidBackupStorage.pick();
    if (folder == null) return ('', false);
    // The grant is already persisted; save it even if the screen closed, and
    // hand it back if saving fails so no unreferenced grant is left behind.
    final current = app.backupFolder?.uri;
    try {
      await app.setBackupFolder(folder);
    } catch (_) {
      if (folder.uri != current) {
        try {
          await AndroidBackupStorage.release(folder);
        } catch (_) {}
      }
      rethrow;
    }
    return (l?.dataBackupFolderSaved ?? 'Backup folder saved.', false);
  }

  Future<_Note> _useDefaultBackupFolder(AppState app) async {
    final l = AppLocalizations.of(context);
    await app.setBackupFolder(null);
    return (l?.dataBackupFolderSaved ?? 'Backup folder saved.', false);
  }

  Future<_Note> _import(AppState app) async {
    final l = AppLocalizations.of(context);
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform
          .pickFiles(allowMultiple: true, withReadStream: false);
    } catch (e) {
      return (
        l?.dataCouldNotOpenPicker(e.toString()) ??
            'Could not open the file picker: $e',
        true
      );
    }
    final paths = (picked?.files ?? const [])
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    // cancelled — not a failure, say nothing
    if (paths.isEmpty) return ('', false);
    final outcome = await runImport(app, paths,
        askPassphrase: () => askBackupPassphrase(context));
    if (mounted) setState(() => _outcome = outcome);
    return ('', false);
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final last = app.lastBackupAt;
    final folder = app.backupFolder;
    final backupError = app.lastBackupError;
    final folderLabel = folder == null
        ? (l?.dataBackupFolderDefault ?? 'App folder (default)')
        : folder.name.isEmpty
            ? (l?.dataBackupFolder ?? 'Backup folder')
            : folder.name;
    final o = _outcome;
    final rebuilt = dbRebuiltCard(app.dbRebuild);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.dataNavTitle ?? 'Your data'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                // Home shows this too, on the launch it happened. It belongs
                // here as well because this is the screen someone opens when
                // they notice their food log is empty, and it is the only
                // screen where the card is ALSO an instruction: "Import a
                // file" three rows down reads the quarantined file back.
                // (It is named `openstrap.db.unopenable-<ms>`, not `.db` —
                // `runImport` matches that shape explicitly, because routing
                // on the suffix alone sent a SQLite file into the vendor-CSV
                // importer.)
                if (rebuilt != null) ...[
                  rebuilt,
                  const SizedBox(height: S.x5),
                ],
                settingsGroup(c, l?.dataExportGroup ?? 'Export', [
                  SetRow(LucideIcons.fileSpreadsheet, C.green,
                      l?.dataExportSpreadsheets ?? 'Export as spreadsheets',
                      // export-provenance: the daily file now carries `source`
                      // and `algo_version` per day, so an imported vendor
                      // snapshot and a day derived from 1 Hz rows stop being
                      // byte-identical. An empty source cell is unknown
                      // provenance — never back-filled to 'band'.
                      sub: l?.dataExportSpreadsheetsSub(kCsvExportSets.length) ??
                          '${kCsvExportSets.length} CSV files — daily metrics, '
                              'workouts, sleep, journal, labs, and everything you '
                              'typed in. Each day carries where it came from and '
                              'which algorithm version scored it',
                      onTap: _busy ? null : () => _run(_exportCsv)),
                  SetRow(LucideIcons.database, C.blue,
                      l?.dataExportDatabase ?? 'Export the database',
                      sub: l?.dataExportDatabaseSub ??
                          'One .db file. Lossless, and the only format that '
                              'restores onto another phone. Readable by anything '
                              'that opens SQLite — including anyone who gets the '
                              'file',
                      onTap: _busy ? null : () => _run(_exportDb)),
                  SetRow(LucideIcons.lock, C.purple,
                      l?.dataExportEncrypted ?? 'Export an encrypted backup',
                      sub: l?.dataExportEncryptedSub ??
                          'The same complete copy, sealed with a passphrase, '
                              'for somewhere like iCloud. Forget the passphrase '
                              'and that file is gone — there is no recovery, '
                              'because there is no account holding a key',
                      onTap: _busy ? null : () => _run(_exportEncrypted)),
                ]),
                const SizedBox(height: S.x5),
                settingsGroup(c, l?.dataAutoBackupGroup ?? 'Automatic backup', [
                  SetRow(LucideIcons.calendarClock, C.purple,
                      l?.dataHowOften ?? 'How often',
                      // Unencrypted, and it says so. The encrypted format is
                      // new and its restore path has not yet run green against
                      // a file written by an older build — defaulting the
                      // automatic copy to a format that might not open is
                      // worse than the plaintext it replaced.
                      sub: l?.dataHowOftenSub(folder == null ? kBackupDirName : folderLabel, kBackupsKept) ??
                          'Writes a compressed, unencrypted copy to '
                              '${folder == null ? kBackupDirName : folderLabel}, keeping the last $kBackupsKept',
                      value: app.backupCadence.label,
                      onTap: _busy
                          ? null
                          : () => _run(() async {
                              await app.setBackupCadence(_nextCadence(app.backupCadence));
                              return ('', false);
                            })),
                  if (defaultTargetPlatform == TargetPlatform.android)
                    SetRow(LucideIcons.folder, C.purple,
                        l?.dataBackupFolder ?? 'Backup folder',
                        sub: '$folderLabel\n${l?.dataBackupFolderSub ?? 'Choose where new backups are saved. Existing backups stay where they are'}',
                        onTap: _busy ? null : () => _run(() => _chooseBackupFolder(app))),
                  if (defaultTargetPlatform == TargetPlatform.android && folder != null)
                    SetRow(LucideIcons.folderClosed, C.n500,
                        l?.dataBackupFolderUseDefault ?? 'Use default folder',
                        onTap: _busy ? null : () => _run(() => _useDefaultBackupFolder(app))),
                  SetRow(LucideIcons.clock, C.n500,
                      l?.dataLastBackup ?? 'Last backup',
                      value: last == null
                          ? (l?.dataNever ?? 'Never')
                          : _stamp(last),
                      chevron: false),
                  if (backupError != null)
                    SetRow(LucideIcons.triangleAlert, C.orange,
                        l?.dataBackupFailed(backupError) ?? 'Backup failed: $backupError',
                        sub: defaultTargetPlatform == TargetPlatform.android
                            ? (l?.dataBackupFolderRetry ?? 'Retry with Back up now, or choose another folder')
                            : (l?.dataBackUpNow ?? 'Back up now'),
                        chevron: false),
                  SetRow(LucideIcons.hardDriveDownload, C.teal,
                      l?.dataBackUpNow ?? 'Back up now',
                      onTap: _busy ? null : () => _run(() => _backupNow(app))),
                ]),
                const SizedBox(height: S.x5),
                settingsGroup(c, l?.dataBringDataInGroup ?? 'Bring data in', [
                  SetRow(LucideIcons.upload, C.orange,
                      l?.dataImportFile ?? 'Import a file',
                      sub: l?.dataImportFileSub ??
                          'An OpenStrap backup (encrypted or not), a journal '
                              'CSV you edited, a raw sensor export, or a vendor '
                              'CSV. Days this band already measured are never '
                              'overwritten',
                      onTap: _busy ? null : () => _run(() => _import(app))),
                  // Progressive disclosure: two health-store reads, each with
                  // its own consent and its own ceiling, behind one row rather
                  // than two more rows on this screen.
                  SetRow(LucideIcons.smartphone, C.blue,
                      l?.dataFromYourPhone ?? 'From your phone',
                      sub: l?.dataFromYourPhoneSub ??
                          'Resting heart rate, blood pressure, glucose and '
                              'body temperature',
                      onTap: _busy ? null : () => goto(c, const PhoneImport())),
                ]),
                const SizedBox(height: S.x5),
                settingsGroup(c, l?.dataRebuildGroup ?? 'Rebuild', [
                  // The engine puts days on hold after a ≥3 h timezone jump
                  // "until Re-analyze data runs" — and nothing in the app ran
                  // it. A flight abroad quietly stopped days updating with no
                  // control anywhere to release them.
                  SetRow(LucideIcons.refreshCcw, C.blue,
                      l?.dataReanalyzeEverything ?? 'Re-analyze everything',
                      sub: l?.dataReanalyzeEverythingSub ??
                          'Scores every day again from what is stored. Needed '
                              'after a long-haul flight, and after an import that '
                              'landed days out of order',
                      value: app.reanalyzeProgress,
                      onTap: _busy || app.reanalyzing
                          ? null
                          : () => _run(() => _reanalyze(app))),
                ]),
                if (_busy) ...[
                  const SizedBox(height: S.x6),
                  Center(child: CircularProgressIndicator(color: p.on(C.blue))),
                ],
                if (_note != null && _note!.isNotEmpty) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(
                      _noteFailed
                          ? (l?.dataThatDidNotWork ?? 'That did not work')
                          : (l?.actionDone ?? 'Done'),
                      _note!,
                      icon: _noteFailed
                          ? LucideIcons.triangleAlert
                          : LucideIcons.check),
                ],
                if (app.importRollupError != null) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(
                    l?.welcomeSummariesDidNotTitle ??
                        'The days landed, the summaries did not',
                    l?.dataSummariesDidNotBodyShort(
                            '${app.importRollupError}') ??
                        'Every imported row is in the database, but rebuilding the '
                            'cross-day summaries over them threw '
                            '(${app.importRollupError}), so trends and insights '
                            'still describe the data you had before.',
                    fix: l?.dataReanalyzeEverything ?? 'Re-analyze everything',
                    icon: LucideIcons.triangleAlert,
                    onFix: _busy ? null : () => _run(() => _reanalyze(app)),
                  ),
                ],
                // The onboarding report, not a second copy of it. This
                // screen used to render its own paraphrase, which had already
                // drifted: it lost the rollup error entirely and stated the
                // loss counts in one run-on sentence.
                if (o != null) ...[
                  const SizedBox(height: S.x5),
                  ImportReport(o),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Off → Daily → Weekly → Off. Three states cycle in a row; a picker for three
/// options is a sheet nobody needs.
BackupCadence _nextCadence(BackupCadence c) => BackupCadence
    .values[(c.index + 1) % BackupCadence.values.length];

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${formatClockOf(t)}';
}
