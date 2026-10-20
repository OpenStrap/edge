// Report an issue: category, title, what happened, an optional screenshot and
// an optional database. Uploaded only when the user taps Create ticket, sealed
// on the phone (lib/support/report_crypto.dart). "Share locally" hands the same
// archive to the share sheet with no network and no size limit.

import 'dart:io';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../support/issue_report.dart';
import '../../sync/file_log.dart';
import '../activity/share.dart' show shareOrigin;
import '../ui2.dart';
import 'profile.dart';

class ReportIssueScreen extends StatefulWidget {
  const ReportIssueScreen({super.key});

  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  ReportCategory _category = ReportCategory.other;
  String? _shot;
  bool _db = false; // OFF by default: 2 weeks of the user's health record
  bool _full = false; // whole database, Share locally only; OFF by default
  bool _busy = false;
  String? _step; // what the tapped button says while it works
  bool _ticketBusy = false; // which button is the busy one
  SentReport? _sent;
  int? _error; // HTTP status of a failed send, 0 = no answer, -1 = no title, -2 = save failed
  List<SentReport> _reports = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final r = await loadSentReports();
    if (mounted) setState(() => _reports = r);
  }

  ReportDraft _draft() => ReportDraft(
        category: _category,
        title: _title.text.trim(),
        description: _body.text.trim(),
        screenshotPath: _shot,
        includeDatabase: _db,
        fullDatabase: _full,
      );

  String _stageText(AppLocalizations l, ReportStage s) => switch (s) {
        ReportStage.collecting => l.reportStageCollecting,
        ReportStage.logs => l.reportStageLogs,
        ReportStage.slice => l.reportStageSlice,
        ReportStage.database => l.reportStageDatabase,
        ReportStage.packing => l.reportStagePacking,
      };

  void _setStep(String s) {
    if (mounted) setState(() => _step = s);
  }

  Future<void> _send() async {
    if (_full) return; // the full database is never uploaded
    if (_title.text.trim().isEmpty) {
      setState(() => _error = -1);
      return;
    }
    final l = _l(context);
    setState(() {
      _ticketBusy = true;
      _step = l.reportStageCollecting;
      _busy = true;
      _error = null;
      _sent = null;
    });
    final files = <File>[];
    try {
      final draft = _draft();
      // Too big even with 1 day of second-by-second data: 413, which points
      // to Share locally.
      final r = await collectReport(context.read<AppState>(), draft,
          onStage: (st) => _setStep(_stageText(l, st)),
          maxBytes:
              draft.includeDatabase ? kReportMaxBytesWithDb : kReportMaxBytes);
      files.add(r.zip);
      _setStep(l.reportStageEncrypting);
      final blob = await sealReport(r.zip);
      files.add(blob);
      final mb = blob.lengthSync() / (1024 * 1024);
      _setStep(l.reportStageUploading(
          mb >= 10 ? '${mb.round()}' : mb.toStringAsFixed(1)));
      final sent = await sendReport(reportServerMeta(draft, r.meta), blob);
      if (mounted) setState(() => _sent = sent);
      await _reload();
    } on ReportSendError catch (e) {
      unawaited(FileLog.write('[report] create ticket failed: $e'));
      if (mounted) setState(() => _error = e.status);
    } catch (e, st) {
      // Kept in the sync log, so the next report (or Share locally) carries it.
      unawaited(FileLog.write('[report] create ticket failed: $e\n$st'));
      if (mounted) setState(() => _error = 0);
    } finally {
      for (final f in files) {
        try {
          await f.delete();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
        });
      }
    }
  }

  Future<void> _save() async {
    final origin = shareOrigin(context);
    final l = _l(context);
    setState(() {
      _ticketBusy = false;
      _step = l.reportStageCollecting;
      _busy = true;
      _error = null;
    });
    try {
      final r = await collectReport(context.read<AppState>(), _draft(),
          onStage: (st) => _setStep(_stageText(l, st)));
      _setStep(l.reportStageSharing);
      await Share.shareXFiles([XFile(r.zip.path)],
          subject: 'Locus issue report', sharePositionOrigin: origin);
    } catch (e) {
      if (mounted) setState(() => _error = e is ReportSendError ? e.status : -2);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
        });
      }
    }
  }

  Future<void> _pickShot() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = picked?.files.single.path;
    if (path != null && mounted) setState(() => _shot = path);
  }

  Future<void> _delete(SentReport r) async {
    final l = _l(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await deleteReport(r);
      await _reload();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.reportDeleteFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static AppLocalizations _l(BuildContext c) =>
      AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));

  String _why(AppLocalizations l, int status) => switch (status) {
        -1 => l.reportNeedTitle,
        413 => l.reportTooLarge,
        429 => l.reportRateLimited,
        507 => l.reportStorageFull,
        _ => l.reportSendFailed,
      };

  Widget _field(BuildContext c, TextEditingController ctl, String label,
      String hint, {int lines = 1, int? max}) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: F.over.copyWith(color: p.ink3)),
        AppField(
          controller: ctl,
          minLines: lines,
          maxLines: lines == 1 ? 1 : null,
          maxLength: max,
          hint: hint,
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = _l(c);
    final draft = _draft();
    final names = {
      ReportCategory.sync: l.reportCategorySync,
      ReportCategory.sleep: l.reportCategorySleep,
      ReportCategory.recovery: l.reportCategoryRecovery,
      ReportCategory.workout: l.reportCategoryWorkout,
      ReportCategory.pairing: l.reportCategoryPairing,
      ReportCategory.other: l.reportCategoryOther,
    };
    final err = _error;
    final sent = _sent;
    final date = MaterialLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l.reportNavTitle),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Text(l.reportCategoryGroup,
                    style: F.over.copyWith(color: p.ink3)),
                const SizedBox(height: S.x2),
                Wrap(spacing: S.x2, runSpacing: S.x2, children: [
                  for (final e in names.entries)
                    Pressable(
                      onTap: () => setState(() => _category = e.key),
                      semanticLabel: e.value,
                      child: Pill(e.value,
                          e.key == _category ? C.green : C.n500,
                          icon: e.key == _category ? LucideIcons.check : null),
                    ),
                ]),
                const SizedBox(height: S.x5),
                _field(c, _title, l.reportTitleLabel, l.reportTitleHint,
                    max: 120),
                _field(c, _body, l.reportDescriptionLabel,
                    l.reportDescriptionHint,
                    lines: 4, max: 4000),
                settingsGroup(c, l.reportAttachGroup, [
                  SetRow(LucideIcons.image, C.blue,
                      _shot == null
                          ? l.reportScreenshotRow
                          : l.reportScreenshotRemove,
                      sub: _shot?.split(Platform.pathSeparator).last ?? '',
                      onTap: _busy
                          ? null
                          : _shot == null
                              ? _pickShot
                              : () => setState(() => _shot = null)),
                  SetRow(LucideIcons.database, C.red, l.reportDatabaseRow,
                      sub: _full
                          ? l.reportDatabaseCovered
                          : l.reportDatabaseWarning,
                      trailing: AppSwitch(_db || _full, _busy || _full
                              ? null
                              : (v) => setState(() => _db = v)),
                      chevron: false,
                      onTap: _busy || _full
                          ? null
                          : () => setState(() => _db = !_db)),
                  SetRow(LucideIcons.database, C.red, l.reportFullDatabaseRow,
                      sub: l.reportFullDatabaseWarning,
                      trailing: AppSwitch(_full, _busy ? null : (v) => setState(() => _full = v)),
                      chevron: false,
                      onTap:
                          _busy ? null : () => setState(() => _full = !_full)),
                ]),
                const SizedBox(height: S.x5),
                settingsGroup(c, l.reportIncludedGroup, [
                  for (final path in reportPaths(
                      screenshotExt: draft.screenshotExt,
                      database: draft.includeDatabase,
                      fullDatabase: draft.fullDatabase))
                    SetRow(LucideIcons.fileText, C.n500, path,
                        sub: describeReportFile(l, path), chevron: false),
                ]),
                const SizedBox(height: S.x2),
                Text(l.reportIncludedNote,
                    style: F.cap.copyWith(color: p.ink2, height: 1.5)),
                const SizedBox(height: S.x5),
                Opacity(
                  opacity: _full ? 0.4 : 1,
                  child: BigButton(
                      _step != null && _ticketBusy ? _step! : l.reportSend,
                      icon: LucideIcons.send,
                      busy: _step != null && _ticketBusy,
                      onTap: _busy || _full ? null : _send),
                ),
                if (_full) ...[
                  const SizedBox(height: S.x2),
                  Text(l.reportFullDatabaseNoUpload,
                      style: F.cap.copyWith(color: p.ink2, height: 1.5)),
                ],
                const SizedBox(height: S.x3),
                BigButton(
                    _step != null && !_ticketBusy
                        ? _step!
                        : l.reportSaveInstead,
                    icon: LucideIcons.share2,
                    soft: true,
                    busy: _step != null && !_ticketBusy,
                    onTap: _busy ? null : _save),
                if (sent != null) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(l.reportSentTitle, l.reportSentBody(sent.id),
                      icon: LucideIcons.check,
                      fix: l.reportCopyId,
                      onFix: () async {
                        final messenger = ScaffoldMessenger.of(c);
                        await Clipboard.setData(ClipboardData(text: sent.id));
                        HapticFeedback.selectionClick();
                        messenger.showSnackBar(
                            SnackBar(content: Text(l.reportIdCopied(sent.id))));
                      }),
                ],
                if (err != null) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(
                      err == -2 ? l.reportSaveFailedTitle : l.reportNotSentTitle,
                      err == -2 ? l.reportSaveFailedBody : _why(l, err),
                      icon: LucideIcons.triangleAlert,
                      fix: err == -1
                          ? ''
                          : err == -2
                              ? l.reportSaveRetry
                              : err == 507
                                  ? l.reportSendWithoutDb
                                  : l.reportSaveInstead,
                      onFix: err == -1
                          ? null
                          : err == 507
                              ? () {
                                  setState(() => _db = false);
                                  _send();
                                }
                              : _save),
                ],
                if (_reports.isNotEmpty) ...[
                  const SizedBox(height: S.x5),
                  settingsGroup(c, l.reportMyReportsGroup, [
                    for (final r in _reports.reversed)
                      SetRow(LucideIcons.fileText, C.n500, r.id,
                          sub: l.reportMyReportsSub(
                              date.formatMediumDate(r.expiresAt.toLocal())),
                          value: l.reportDelete,
                          chevron: false,
                          onTap: _busy ? null : () => _delete(r)),
                  ]),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
