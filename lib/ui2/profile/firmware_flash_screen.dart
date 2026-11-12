// Install an image you supply yourself (WHOOP 5, opt-in builds). Developer
// group only. English-only on purpose: it is not a user-facing feature.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/firmware_flash.dart';
import '../../state/app_state.dart';
import '../ui2.dart';

const _warning =
    'Installing an image you supply yourself can permanently damage your '
    'strap, void its warranty and stop it working. It cannot be undone from '
    'this app. OpenStrap does not provide, review or endorse any image, and '
    'OpenStrap and its contributors accept no responsibility or liability for '
    'any loss or damage. You do this entirely at your own risk.';

class FirmwareFlashScreen extends StatefulWidget {
  const FirmwareFlashScreen({super.key});
  @override
  State<FirmwareFlashScreen> createState() => _FirmwareFlashScreenState();
}

class _FirmwareFlashScreenState extends State<FirmwareFlashScreen> {
  FirmwareFlashController? _f;
  bool _accepted = false;

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
    final r = await FilePicker.platform.pickFiles(withData: true);
    final file = r?.files.single;
    if (file?.bytes == null) return;
    _f!.load(file!.name, file.bytes!);
  }

  Future<void> _stage() async {
    final f = _f!;
    await f.stage();
    if (!mounted || f.phase != FlashPhase.verified) return;
    final sure = await confirmRemove(
      context,
      title: 'Install this image?',
      body: 'The strap has the file and verified it. Nothing is installed '
          'until you press Sure, and that cannot be undone.\n\n'
          '${f.fileName}\nsha256 ${f.sha}',
      remove: 'Sure',
      keep: 'Cancel',
    );
    if (sure) {
      await f.commit();
    } else {
      f.abandon();
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final f = _f!;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Install an image'),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: f,
              builder: (c, _) => ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  Surface(
                    child: Text(_warning,
                        style: F.body.copyWith(color: p.ink2, height: 1.4)),
                  ),
                  const SizedBox(height: S.x4),
                  if (!_accepted)
                    BigButton('I understand and accept the risk',
                        color: C.red,
                        onTap: () => setState(() => _accepted = true))
                  else
                    ..._body(c, f, p),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _body(BuildContext c, FirmwareFlashController f, P p) {
    final done = f.phase == FlashPhase.committed;
    return [
      if (f.fileName != null)
        Surface(
          child: Text(
            '${f.fileName}\n${f.imageBytes} bytes\nsha256 ${f.sha}',
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
        ),
      const SizedBox(height: S.x3),
      if (!f.busy && !done)
        BigButton(f.fileName == null ? 'Choose image file' : 'Choose another',
            soft: true, onTap: _pick),
      const SizedBox(height: S.x3),
      if (f.phase == FlashPhase.idle || f.phase == FlashPhase.failed) ...[
        if (f.blocker != null)
          Text(f.blocker!, style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x3),
        BigButton('Send to strap',
            icon: LucideIcons.upload,
            color: C.red,
            onTap: f.blocker == null ? _stage : null),
      ],
      if (f.phase == FlashPhase.staging) ...[
        LinearProgressIndicator(value: f.progress),
        const SizedBox(height: S.x2),
        Text('${f.chunksDone} of ${f.chunksTotal} blocks sent. '
            'Keep the app open and the strap close.',
            style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x3),
        BigButton('Stop', soft: true, onTap: f.cancel),
      ],
      if (f.phase == FlashPhase.committing)
        Text('Sending the commit…', style: F.cap.copyWith(color: p.ink2)),
      if (done)
        Text(
            'The strap accepted the image. That does not confirm it is '
            'running. Check the strap\'s firmware version after it restarts.',
            style: F.body.copyWith(color: p.ink2, height: 1.4)),
      if (f.error != null) ...[
        const SizedBox(height: S.x3),
        Text(f.error!, style: F.cap.copyWith(color: C.red)),
      ],
    ];
  }
}
