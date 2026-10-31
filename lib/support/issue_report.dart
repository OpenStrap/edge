// "Report an issue": what goes in the archive, how it is built, sent and
// later deleted. The screen is lib/ui2/profile/report_issue.dart.
//
// ONE list of files ([reportPaths]) feeds the archive's manifest.json AND the
// "What's included" section, so the two cannot say different things. Each
// file's description is an ARB string: the manifest uses the English text,
// the screen the user's language.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../data/db.dart';
import '../data/recent_slice.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../sync/file_log.dart';
import '../telemetry/telemetry_service.dart';
import 'report_crypto.dart';

/// The report service. One constant; the Worker answers under /v1.
const String kReportBaseUrl = 'https://reports.openstrap.site';

/// Server limits (bytes of the sealed blob). UPLOAD limits only: a local
/// share has no size cap. 95 MB stays under the 100 MB request body the
/// Worker's free plan accepts.
const int kReportMaxBytes = 5 * 1024 * 1024;
const int kReportMaxBytesWithDb = 95 * 1024 * 1024;

/// Days of second-by-second data tried, in order, until an uploaded ticket
/// fits [kReportMaxBytesWithDb]. Everything else in the slice keeps 14 days.
const List<int> kRawDaysSteps = [kSliceDays, 7, 3, 1];

/// Recent logs ride along up to this many bytes (they zip about 10:1).
const int kReportLogBytes = 1500 * 1024;

enum ReportCategory { sync, sleep, recovery, workout, pairing, other }

/// Every file in the archive, in order. [screenshotExt] is the picked image's
/// extension ("png", "jpg"), null when no screenshot is attached. [database]
/// is the last-2-weeks slice; [fullDatabase] (local share only) replaces it.
List<String> reportPaths(
        {String? screenshotExt,
        bool database = false,
        bool fullDatabase = false}) =>
    [
      'manifest.json',
      'meta.json',
      'device.json',
      'state.json',
      'logs/sync.log',
      'logs/telemetry.json',
      'user.txt',
      if (screenshotExt != null) 'screenshot.$screenshotExt',
      if (fullDatabase)
        'database.db.gz'
      else if (database)
        'database_14d.db.gz',
    ];

/// One plain line per file, in [l]'s language.
String describeReportFile(AppLocalizations l, String path) => switch (path) {
      'manifest.json' => l.reportFileManifest,
      'meta.json' => l.reportFileMeta,
      'device.json' => l.reportFileDevice,
      'state.json' => l.reportFileState,
      'logs/sync.log' => l.reportFileSyncLog,
      'logs/telemetry.json' => l.reportFileTelemetry,
      'user.txt' => l.reportFileUser,
      'database.db.gz' => l.reportFileDatabase,
      'database_14d.db.gz' => l.reportFileDatabaseSlice,
      _ => l.reportFileScreenshot,
    };

/// What the user typed and picked.
class ReportDraft {
  final ReportCategory category;
  final String title, description;
  final String? screenshotPath;
  /// The last-2-weeks slice (uploadable).
  final bool includeDatabase;

  /// The whole database, for Share locally only; wins over [includeDatabase].
  final bool fullDatabase;
  const ReportDraft({
    required this.category,
    required this.title,
    required this.description,
    this.screenshotPath,
    this.includeDatabase = false,
    this.fullDatabase = false,
  });

  String? get screenshotExt {
    final s = screenshotPath;
    if (s == null) return null;
    final dot = s.lastIndexOf('.');
    final ext = dot < 0 ? '' : s.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'img';
  }
}

/// The archive, from already-gathered parts, written to [path]. The tests
/// call it directly. [meta], [device] and [state] become JSON files;
/// [syncLog] is UTF-8 text. [databaseGz] is copied in from disk, stored as is
/// (it is already compressed), so it never sits in memory. [rawDays] is how
/// many days of second-by-second data the slice holds.
Future<File> writeReportZip(
  String path, {
  required ReportDraft draft,
  required Map<String, Object?> meta,
  required Map<String, Object?> device,
  required Map<String, Object?> state,
  required String syncLog,
  required List<Map<String, dynamic>> telemetry,
  Uint8List? screenshot,
  File? databaseGz,
  int? rawDays,
}) async {
  final en = lookupAppLocalizations(const Locale('en'));
  final paths = reportPaths(
      screenshotExt: screenshot == null ? null : draft.screenshotExt,
      database: databaseGz != null && !draft.fullDatabase,
      fullDatabase: databaseGz != null && draft.fullDatabase);
  const pretty = JsonEncoder.withIndent('  ');
  final bodies = <String, List<int>>{
    'manifest.json': utf8.encode(pretty.convert({
      'v': 1,
      'files': [
        for (final p in paths) {'path': p, 'description': describeReportFile(en, p)}
      ],
      if (databaseGz != null && !draft.fullDatabase) 'rawDays': ?rawDays,
    })),
    'meta.json': utf8.encode(pretty.convert(meta)),
    'device.json': utf8.encode(pretty.convert(device)),
    'state.json': utf8.encode(pretty.convert(state)),
    'logs/sync.log': utf8.encode(syncLog),
    'logs/telemetry.json': utf8.encode(pretty.convert(telemetry)),
    'user.txt': utf8.encode('Category: ${draft.category.name}\n'
        'Title: ${draft.title}\n\n${draft.description}\n'),
    'screenshot.${draft.screenshotExt}': ?screenshot,
  };
  final zip = ZipFileEncoder()..create(path);
  InputFileStream? db;
  try {
    for (final p in paths) {
      final body = bodies[p];
      if (body != null) {
        zip.addArchiveFile(ArchiveFile.bytes(p, body));
      } else {
        // The .db.gz, always last.
        db = InputFileStream(databaseGz!.path);
        zip.addArchiveFile(ArchiveFile.stream(p, db)
          ..compression = CompressionType.none);
      }
    }
  } finally {
    await zip.close();
    await db?.close();
  }
  return File(path);
}

/// The plaintext `meta` field the Worker shows in the tracker. Nothing in it
/// is health data.
Map<String, Object?> reportServerMeta(
        ReportDraft d, Map<String, Object?> meta) =>
    {
      'v': 1,
      'installId': meta['installId'],
      'category': d.category.name,
      'title': _clip(d.title, 120),
      'description': _clip(d.description, 4000),
      'appVersion': meta['appVersion'],
      'platform': meta['platform'],
      'osVersion': meta['osVersion'],
      'deviceModel': meta['deviceModel'],
      'hasDatabase': d.includeDatabase && !d.fullDatabase,
      'hasScreenshot': d.screenshotPath != null,
      if (d.includeDatabase && !d.fullDatabase) 'rawDays': ?meta['rawDays'],
    };

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

/// The steps [collectReport] reports, in order (slice or database only when
/// one is attached).
enum ReportStage { collecting, logs, slice, database, packing }

/// Gzip [path] into [to], disk to disk (neither file is held in memory).
Future<File> gzipFile(String path, String to) async {
  await File(path).openRead().transform(gzip.encoder).pipe(File(to).openWrite());
  return File(to);
}

const _kReportPrefix = 'openstrap_report_';

String _tmp(String dir, String ext) =>
    '$dir/$_kReportPrefix${DateTime.now().microsecondsSinceEpoch}$ext';

/// Delete report files left in [dir] by earlier runs: a Share locally whose
/// cleanup never ran, or a run the OS killed mid-build. Each run writes a new
/// name, and with the full database each one is a plaintext copy of the whole
/// health record, so without this they pile up in the cache dir. Files newer
/// than [olderThan] are left alone in case another build is still using them.
Future<int> sweepStaleReports(String dir,
    {Duration olderThan = const Duration(minutes: 10), DateTime? now}) async {
  final cutoff = (now ?? DateTime.now()).subtract(olderThan);
  var n = 0;
  try {
    await for (final e in Directory(dir).list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.startsWith(_kReportPrefix)) continue;
      try {
        if (e.lastModifiedSync().isBefore(cutoff)) {
          await e.delete();
          n++;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return n;
}

/// Gather everything from the running app and write the archive to a temp
/// file (the caller deletes it). Built on disk, so even the full database
/// never sits in memory.
///
/// [maxBytes] (uploads only) is the cap on the SEALED ticket: a 2-week slice
/// that does not fit is rebuilt with fewer days of second-by-second data
/// ([kRawDaysSteps]); still too big, or too big with no slice, throws
/// [ReportSendError] 413. Local shares pass none and get the full 14 days.
Future<({File zip, Map<String, Object?> meta})> collectReport(
    AppState app, ReportDraft draft,
    {void Function(ReportStage)? onStage, int? maxBytes}) async {
  onStage?.call(ReportStage.collecting);
  final t = TelemetryService.instance;
  final s = await t.staticDevice();
  final now = DateTime.now();
  final build = s['app_build'];
  final meta = <String, Object?>{
    'appVersion': '${s['app_version'] ?? '?'}${build == null ? '' : '+$build'}',
    'algoVersion': kAlgoVersion,
    'schemaVersion': LocalDb.schemaVersion,
    'platform': s['platform'] ?? Platform.operatingSystem,
    'osVersion': s['os_version'] ?? Platform.operatingSystemVersion,
    'deviceModel': s['model'],
    'deviceMaker': s['oem'],
    'locale': Platform.localeName,
    'timezone': now.timeZoneName,
    'tzOffsetMinutes': now.timeZoneOffset.inMinutes,
    'installId': app.deviceId,
    'createdAt': _iso(now),
  };
  final d = app.device;
  final device = <String, Object?>{
    'band': {
      'paired': app.isPaired,
      'generation': app.paired?.generation ?? d.generation,
      'connection': d.connection,
      'batteryPct': d.batteryPct,
      'charging': d.charging,
      'batteryPackPct': d.batteryPackPct,
      'wristOn': d.wristOn,
      'lastSyncedRecord': app.lastSynced?.tsEpoch,
      'bandDataOldest': d.dataRangeOldest,
      'bandDataNewest': d.dataRangeNewest,
      // Firmware is not held in app state; the HELLO lines in logs/sync.log
      // carry it.
    },
    'sensors': [
      for (final r in app.sensors)
        {
          for (final k in const [
            'adapter_id', 'label', 'tier', 'role', 'wearing',
            'first_seen', 'last_seen'
          ])
            k: r[k],
        }
    ],
  };
  final weekAgo = now.millisecondsSinceEpoch ~/ 1000 - 7 * 86400;
  final records = [
    for (final r in t.outboxSnapshot)
      if ((r['ts'] as int? ?? 0) >= weekAgo) r
  ];
  final state = <String, Object?>{
    'syncStatus': app.status,
    'syncingNow': app.syncingNow,
    'busy': app.busy,
    'lastDataAt': _iso(app.lastDataAt),
    'lastRecordAt': _iso(app.lastRecordAt),
    'deriving': app.deriving,
    'derivePending': app.derivePending,
    'standardHrFallback': d.standardHrFallback,
    'needsRepairGuide': d.needsRepairGuide,
    'bondRefusals': d.bondRefusals,
    'autoReconnectPaused': d.autoReconnectPaused,
    'syncClockLost': d.syncClockLost,
    'strapNeedsReboot': d.strapNeedsReboot,
    'syncChunkQuarantined': d.syncChunkQuarantined,
    'initError': app.initError,
    'importRollupError': app.importRollupError,
    'lastBackupError': app.lastBackupError,
    'recentErrors': [
      for (final r in records)
        if (r['kind'] == 'error' || r['kind'] == 'crash') r
    ].reversed.take(20).toList(),
  };
  onStage?.call(ReportStage.logs);
  // No log file (older iOS builds never wrote one): fall back to the lines
  // this session kept in memory, oldest first.
  var syncLog = await _recentLog();
  if (syncLog.isEmpty) syncLog = app.logLines.reversed.join('\n');
  final shot = draft.screenshotPath == null
      ? null
      : await File(draft.screenshotPath!).readAsBytes();
  final tmp = (await getTemporaryDirectory()).path;
  await sweepStaleReports(tmp);
  final slice = draft.includeDatabase && !draft.fullDatabase;
  Future<File> zipWith(File? dbGz, int? rawDays) {
    onStage?.call(ReportStage.packing);
    return writeReportZip(
      _tmp(tmp, '.zip'),
      draft: draft,
      meta: meta,
      device: device,
      state: state,
      syncLog: syncLog,
      telemetry: records,
      screenshot: shot,
      databaseGz: dbGz,
      rawDays: rawDays,
    );
  }

  bool fits(File zip) =>
      maxBytes == null || zip.lengthSync() + kOsr1Overhead <= maxBytes;

  if (!draft.fullDatabase && !draft.includeDatabase) {
    final zip = await zipWith(null, null);
    if (fits(zip)) return (zip: zip, meta: meta);
    await _rm(zip.path);
    throw const ReportSendError(413);
  }
  for (final days in slice && maxBytes != null ? kRawDaysSteps : [kSliceDays]) {
    final String path;
    if (draft.fullDatabase) {
      onStage?.call(ReportStage.database);
      // The existing export path: a VACUUM INTO snapshot, not a file copy.
      path = await LocalDb.exportCopy(includeSubstrateArchive: false);
    } else {
      onStage?.call(ReportStage.slice);
      path = await exportRecentSlice(rawDays: days);
    }
    final File gz;
    try {
      gz = await gzipFile(path, _tmp(tmp, '.db.gz'));
    } finally {
      await _rm(path);
    }
    if (slice) meta['rawDays'] = days;
    final File zip;
    try {
      zip = await zipWith(gz, slice ? days : null);
    } finally {
      await _rm(gz.path);
    }
    if (fits(zip)) {
      if (days != kSliceDays) {
        unawaited(FileLog.write('[report] slice cut to $days days of '
            'second-by-second data to fit ${zip.lengthSync()} bytes'));
      }
      return (zip: zip, meta: meta);
    }
    await _rm(zip.path);
  }
  throw const ReportSendError(413);
}

Future<void> _rm(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}

/// The newest [kReportLogBytes] of the sync log, across its one rotation.
///
/// ponytail: capped by size, not by a 7-day cut; the log lines carry no
/// parseable date, and 1.5 MB is already well past a week of normal syncing.
Future<String> _recentLog() async {
  final path = await FileLog.path();
  if (path == null) return '';
  final parts = <List<int>>[];
  var left = kReportLogBytes;
  for (final f in [File(path), File('$path.1')]) {
    if (left <= 0) break;
    try {
      if (!await f.exists()) continue;
      final b = await f.readAsBytes();
      final take = b.length < left ? b.length : left;
      parts.insert(0, b.sublist(b.length - take));
      left -= take;
    } catch (_) {}
  }
  return utf8.decode(parts.expand((e) => e).toList(), allowMalformed: true);
}

/// A report the Worker accepted, kept on this phone so it can be deleted.
class SentReport {
  final String id, deleteToken;
  final DateTime expiresAt;
  const SentReport(this.id, this.deleteToken, this.expiresAt);

  Map<String, Object?> toJson() => {
        'id': id,
        'deleteToken': deleteToken,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static SentReport fromJson(Map<String, dynamic> j) => SentReport(
      j['id'] as String,
      j['deleteToken'] as String,
      DateTime.parse(j['expiresAt'] as String));
}

/// A non-201 answer. [status] 0 means the request never got an answer.
class ReportSendError implements Exception {
  final int status;
  final String? error;
  const ReportSendError(this.status, [this.error]);
  @override
  String toString() => 'ReportSendError($status${error == null ? '' : ', $error'})';
}

/// Seal [zip] into a new file next to it, off the UI thread, streaming
/// (lib/support/report_crypto.dart osr1EncryptFile). Top-level on purpose: a
/// closure created inside a widget's State can capture the State itself,
/// which cannot cross an isolate boundary, and Isolate.run then throws before
/// anything is sent.
Future<File> sealReport(File zip) async {
  final inPath = zip.path, outPath = '${zip.path}.osr1';
  await Isolate.run(() => osr1EncryptFile(inPath, outPath));
  return File(outPath);
}

/// base64url without padding, as the Worker reads X-Report-Meta.
String reportMetaHeader(Map<String, Object?> serverMeta) =>
    base64Url.encode(utf8.encode(jsonEncode(serverMeta))).replaceAll('=', '');

/// POST the sealed file as the raw request body, streamed from disk with its
/// length up front (the Worker refuses a body without one). Throws
/// [ReportSendError] on anything but 201.
Future<SentReport> sendReport(Map<String, Object?> serverMeta, File blob,
    {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final req = http.StreamedRequest('POST', Uri.parse('$kReportBaseUrl/v1/reports'))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..headers['X-Report-Meta'] = reportMetaHeader(serverMeta)
      ..contentLength = await blob.length();
    unawaited(req.sink.addStream(blob.openRead()).whenComplete(req.sink.close));
    // ponytail: one overall timeout; a 95 MB upload on a slow link needs
    // minutes, so it scales with size. Add progress-based stall detection if
    // uploads hang in practice.
    final timeout = Duration(seconds: 90 + req.contentLength! ~/ (100 * 1024));
    final res = await http.Response.fromStream(
        await c.send(req).timeout(timeout));
    if (res.statusCode != 201) {
      String? err;
      try {
        err = (jsonDecode(res.body) as Map)['error'] as String?;
      } catch (_) {}
      throw ReportSendError(res.statusCode, err);
    }
    final sent = SentReport.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    // The Worker has the report: a local bookkeeping failure must not look
    // like a failed send (a retry would burn another daily slot).
    try {
      await _store([...await loadSentReports(), sent]);
    } catch (_) {}
    return sent;
  } on ReportSendError {
    rethrow;
  } catch (e) {
    throw ReportSendError(0, '$e');
  } finally {
    if (client == null) c.close();
  }
}

/// DELETE a report this phone sent. A 404 counts as gone (it expired).
Future<void> deleteReport(SentReport r, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c.delete(Uri.parse('$kReportBaseUrl/v1/reports/${r.id}'),
        headers: {'X-Delete-Token': r.deleteToken}).timeout(
        const Duration(seconds: 30));
    if (res.statusCode != 204 && res.statusCode != 404) {
      throw ReportSendError(res.statusCode);
    }
  } on ReportSendError {
    rethrow;
  } catch (e) {
    throw ReportSendError(0, '$e');
  } finally {
    if (client == null) c.close();
  }
  await _store([
    for (final s in await loadSentReports())
      if (s.id != r.id) s
  ]);
}

const String _kSentReports = 'issue_reports_sent';

/// Reports sent from this phone that have not expired yet, newest last.
Future<List<SentReport>> loadSentReports() async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();
  try {
    final list = jsonDecode(prefs.getString(_kSentReports) ?? '[]') as List;
    return [
      for (final e in list)
        if (SentReport.fromJson((e as Map).cast()).expiresAt.isAfter(now))
          SentReport.fromJson(e.cast())
    ];
  } catch (_) {
    return [];
  }
}

Future<void> _store(List<SentReport> list) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kSentReports, jsonEncode([for (final s in list) s.toJson()]));
}
