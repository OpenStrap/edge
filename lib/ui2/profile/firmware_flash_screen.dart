// Install an image you supply yourself. Reached from a WHOOP 5 band's own
// device page only.
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/firmware_flash.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';

const _warningFallback =
    'Installing an image you supply yourself can permanently damage your '
    'strap, void its warranty and stop it working. It cannot be undone from '
    'this app. OpenStrap does not provide, review or endorse any image, and '
    'OpenStrap and its contributors accept no responsibility or liability for '
    'any loss or damage. You do this entirely at your own risk.';

enum _PickProblem { tooLarge, unreadable }

class FirmwareFlashScreen extends StatefulWidget {
  const FirmwareFlashScreen({super.key});
  @override
  State<FirmwareFlashScreen> createState() => _FirmwareFlashScreenState();
}

class _FirmwareFlashScreenState extends State<FirmwareFlashScreen> {
  FirmwareFlashController? _f;
  bool _accepted = false;
  _PickProblem? _pickProblem;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _f ??= FirmwareFlashController(
        EngineFlashLink(context.read<AppState>().engine));
  }

  @override
  void dispose() {
    _f?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    // Metadata only: the bytes are read after the size is known, so a wrong
    // pick (a video, say) is never pulled into memory.
    final r = await FilePicker.platform.pickFiles(withData: false);
    if (!mounted || r == null || r.files.isEmpty) return;
    final file = r.files.first;
    if (file.size > FirmwareFlashController.maxImageBytes) {
      setState(() => _pickProblem = _PickProblem.tooLarge);
      return;
    }
    final path = file.path;
    if (path == null) {
      setState(() => _pickProblem = _PickProblem.unreadable);
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      setState(() => _pickProblem = null);
      _f!.load(file.name, bytes);
    } catch (_) {
      if (mounted) setState(() => _pickProblem = _PickProblem.unreadable);
    }
  }

  Future<void> _stage() async {
    final f = _f!;
    await f.stage();
    if (!mounted || f.phase != FlashPhase.verified) return;
    final l = AppLocalizations.of(context);
    final sure = await confirmRemove(
      context,
      title: l?.flashConfirmTitle ?? 'Install this image?',
      body: l?.flashConfirmBody(f.fileName ?? '', f.sha ?? '') ??
          'The strap has the file and verified it. Nothing is installed '
              'until you press Sure, and that cannot be undone.\n\n'
              '${f.fileName}\nsha256 ${f.sha}',
      remove: l?.flashConfirmSure ?? 'Sure',
      keep: l?.flashConfirmCancel ?? 'Cancel',
    );
    if (sure) {
      await f.commit();
    } else {
      f.abandon();
    }
  }

  String _blockText(AppLocalizations? l, FirmwareFlashController f) {
    switch (f.blocker!) {
      case FlashBlock.noImage:
        return l?.flashBlockNoImage ?? 'Choose an image file first.';
      case FlashBlock.tooLarge:
        return l?.flashBlockTooLarge ?? 'That file is too large for an image.';
      case FlashBlock.noLink:
        return l?.flashBlockNoLink ??
            'Connect a WHOOP 5 and wait for any sync to finish.';
      case FlashBlock.batteryUnknown:
        return l?.flashBlockBatteryUnknown ??
            'Battery level unknown. Wait for it to be read.';
      case FlashBlock.batteryLow:
        final pct = (f.batteryNow ?? 0).round();
        final min = FirmwareFlashController.minBatteryPct.round();
        return l?.flashBlockBatteryLow(pct, min) ??
            'Battery is $pct%. Charge to at least $min% first.';
    }
  }

  String _failureText(AppLocalizations? l, FirmwareFlashController f) {
    switch (f.failure!) {
      case FlashFailure.takeover:
        return l?.flashFailTakeover ?? 'Could not take over the connection.';
      case FlashFailure.start:
        return l?.flashFailStart ??
            'The strap did not accept the start of the update.';
      case FlashFailure.data:
        return l?.flashFailData(f.failureOffset) ??
            'The strap rejected data at byte ${f.failureOffset}. '
                'Nothing was committed.';
      case FlashFailure.verify:
        return l?.flashFailVerify ??
            'The strap did not verify the image. Nothing was committed.';
      case FlashFailure.cancelled:
        return l?.flashFailCancelled ?? 'Cancelled. Nothing was committed.';
      case FlashFailure.commitRejected:
        return l?.flashFailCommitRejected ??
            'The strap did not accept the commit.';
      case FlashFailure.commitUnknown:
        return l?.flashCommitUnknown ?? _commitUnknownFallback;
    }
  }

  static const _commitUnknownFallback =
      'The commit was sent but the strap did not answer. It may or may not '
      'have been applied. Do not try again. Check the strap\'s firmware '
      'version after it restarts.';

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final f = _f!;
    final l = AppLocalizations.of(c);
    // Connection, sync and battery state gate the Send button; the controller
    // does not hear about those, the app state does.
    c.watch<AppState>();
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.devicesInstallImage ?? 'Install an image'),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: f,
              builder: (c, _) => ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  Surface(
                    child: Text(l?.flashWarning ?? _warningFallback,
                        style: F.body.copyWith(color: p.ink2, height: 1.4)),
                  ),
                  const SizedBox(height: S.x4),
                  if (!_accepted)
                    BigButton(
                        l?.flashAccept ?? 'I understand and accept the risk',
                        color: C.red,
                        onTap: () => setState(() => _accepted = true))
                  else
                    ..._body(c, l, f, p),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _body(
      BuildContext c, AppLocalizations? l, FirmwareFlashController f, P p) {
    final done = f.phase == FlashPhase.committed;
    return [
      if (f.fileName != null)
        Surface(
          child: Text(
            l?.flashFileInfo(f.fileName!, f.imageBytes, f.sha ?? '') ??
                '${f.fileName}\n${f.imageBytes} bytes\nsha256 ${f.sha}',
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
        ),
      const SizedBox(height: S.x3),
      if (!f.busy && !f.settled)
        BigButton(
            f.fileName == null
                ? (l?.flashChoose ?? 'Choose image file')
                : (l?.flashChooseAnother ?? 'Choose another'),
            soft: true,
            onTap: _pick),
      if (_pickProblem != null) ...[
        const SizedBox(height: S.x2),
        Text(
            _pickProblem == _PickProblem.tooLarge
                ? (l?.flashBlockTooLarge ?? 'That file is too large for an image.')
                : (l?.flashPickUnreadable ?? 'That file could not be read.'),
            style: F.cap.copyWith(color: C.red)),
      ],
      const SizedBox(height: S.x3),
      if (f.phase == FlashPhase.idle || f.phase == FlashPhase.failed) ...[
        if (f.blocker != null)
          Text(_blockText(l, f), style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x3),
        BigButton(l?.flashSend ?? 'Send to strap',
            icon: LucideIcons.upload,
            color: C.red,
            onTap: f.blocker == null ? _stage : null),
      ],
      if (f.phase == FlashPhase.staging) ...[
        LinearProgressIndicator(value: f.progress),
        const SizedBox(height: S.x2),
        Text(
            l?.flashProgress(f.chunksDone, f.chunksTotal) ??
                '${f.chunksDone} of ${f.chunksTotal} blocks sent. '
                    'Keep the app open and the strap close.',
            style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x3),
        BigButton(l?.flashStop ?? 'Stop', soft: true, onTap: f.cancel),
      ],
      if (f.phase == FlashPhase.committing)
        Text(l?.flashCommitting ?? 'Sending the commit…',
            style: F.cap.copyWith(color: p.ink2)),
      if (done)
        Text(
            l?.flashCommitted ??
                'The strap accepted the image. That does not confirm it is '
                    'running. Check the strap\'s firmware version after it '
                    'restarts.',
            style: F.body.copyWith(color: p.ink2, height: 1.4)),
      if (f.phase == FlashPhase.commitUnknown) ...[
        const SizedBox(height: S.x3),
        BigButton(
            l?.flashAcknowledge ??
                'I checked the firmware version. Allow another install.',
            soft: true,
            onTap: f.acknowledgeUnresolved),
      ],
      if (f.failure != null) ...[
        const SizedBox(height: S.x3),
        Text(_failureText(l, f),
            style: F.cap.copyWith(
                color: f.phase == FlashPhase.commitUnknown ? p.ink : C.red,
                height: 1.4)),
      ],
    ];
  }
}
