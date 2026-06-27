// import_screen.dart — "Import data" hub. Pull history in from another source:
//   • NOOP raw-sensor CSV → FULL 1 Hz re-derivation (same analytics as a live sync)
//   • Edge backup (.db)    → merge another OpenStrap device's exported database
//   • WHOOP export CSV      → derived-snapshot days + workouts (BETA)
//
// Reachable from onboarding (welcome) AND Profile → Data (a returning user is past
// the welcome gate). Each option: pick file → run via AppState → progress → result.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  String? _progress;
  String? _result;
  String? _error;

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  // FileType.any (not custom/allowedExtensions): Android maps extensions to MIME
  // types and rejects unmapped ones like `db` (and often `csv`) with "Unsupported
  // filter". The importers are content-aware (NOOP/WHOOP detect by CSV header,
  // Edge opens the file as SQLite), so we accept any file and validate on parse.
  Future<List<String>> _pick({bool multiple = false}) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: multiple,
      withData: false,
    );
    if (res == null) return const [];
    return [for (final f in res.files) if (f.path != null) f.path!];
  }

  Future<void> _run(String label, Future<int> Function() task,
      {String unit = 'day'}) async {
    _set(() {
      _busy = true;
      _progress = 'Importing…';
      _result = null;
      _error = null;
    });
    try {
      final n = await task();
      _set(() {
        _busy = false;
        _progress = null;
        _result = '$label: imported $n $unit${n == 1 ? '' : 's'}.';
      });
    } catch (e) {
      _set(() {
        _busy = false;
        _progress = null;
        _error = '$label failed: $e';
      });
    }
  }

  Future<void> _importNoop() async {
    final app = context.read<AppState>(); // before the async picker
    final paths = await _pick();
    if (paths.isEmpty) return;
    await _run('NOOP', () => app.importNoopCsv(paths.first,
        onProgress: (d) => _set(() => _progress = 'Re-deriving day $d…')));
  }

  Future<void> _importEdge() async {
    final app = context.read<AppState>();
    final paths = await _pick();
    if (paths.isEmpty) return;
    await _run('Edge backup', () => app.importEdgeBackup(paths.first),
        unit: 'row');
  }

  Future<void> _importWhoop() async {
    final app = context.read<AppState>();
    final paths = await _pick(multiple: true);
    if (paths.isEmpty) return;
    await _run('WHOOP', () => app.importWhoopCsvs(paths,
        onProgress: (d) => _set(() => _progress = 'Importing day $d…')));
  }

  /// Finish: if still in onboarding (no choice made yet) mark it done so the gate
  /// advances past `welcome` (→ pairing → shell); then leave the import screen.
  /// A returning user (choice already set) simply returns to where they were.
  Future<void> _continue() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    await app.completeImportOnboard(); // no-op if already onboarded
    if (mounted) nav.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            Row(children: [
              if (Navigator.of(context).canPop())
                RoundIconButton(Ic.arrowLeft,
                    onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: Sp.x3),
              Text('Import data', style: AppText.h1),
            ]),
            const SizedBox(height: Sp.x3),
            Text(
                'Bring history in from another source. Imported days sit alongside '
                'your band data; new band syncs always take priority on overlap.',
                style: AppText.bodySoft),
            const SizedBox(height: Sp.x6),

            _card(
              icon: Ic.cloud,
              title: 'Import from NOOP',
              body: 'Raw 1 Hz sensor CSV. Re-analyzed end-to-end on this phone — '
                  'full-fidelity sleep, HRV, strain & workouts.',
              onTap: _busy ? null : _importNoop,
            ),
            const SizedBox(height: Sp.x4),
            _card(
              icon: Ic.cloud,
              title: 'Import from Edge backup',
              body: 'A .db file exported from another OpenStrap device '
                  '(Profile → Export data). Merges its full history.',
              onTap: _busy ? null : _importEdge,
            ),
            const SizedBox(height: Sp.x4),
            _card(
              icon: Ic.cloud,
              title: 'Import from WHOOP',
              tag: 'BETA',
              body: 'Your WHOOP data export CSVs (physiological cycles / sleeps / '
                  'workouts). Derived summaries only — WHOOP has no raw 1 Hz.',
              onTap: _busy ? null : _importWhoop,
            ),

            const SizedBox(height: Sp.x6),
            if (_busy) ...[
              Row(children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.coral)),
                const SizedBox(width: Sp.x3),
                Expanded(
                    child: Text(_progress ?? 'Importing…',
                        style: AppText.bodySoft)),
              ]),
            ],
            if (_result != null) ...[
              Row(children: [
                AppIcon(Ic.check, size: 18, color: AppColors.good),
                const SizedBox(width: Sp.x2),
                Expanded(
                    child: Text(_result!,
                        style: AppText.body.copyWith(color: AppColors.good))),
              ]),
              const SizedBox(height: Sp.x5),
              SizedBox(
                height: 54,
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _continue,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.coral,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(R.pill)),
                  ),
                  child: Text('Continue',
                      style: AppText.title.copyWith(color: Colors.white)),
                ),
              ),
              const SizedBox(height: Sp.x3),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : () => _set(() => _result = null),
                  child: Text('Import another file',
                      style: AppText.bodySoft.copyWith(color: AppColors.coralInk)),
                ),
              ),
            ],
            if (_error != null)
              Text(_error!, style: AppText.bodySoft.copyWith(color: AppColors.bad)),
            const SizedBox(height: Sp.x8),
          ],
        ),
      ),
    );
  }

  Widget _card({
    required IconData icon,
    required String title,
    required String body,
    required VoidCallback? onTap,
    String? tag,
  }) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: ProCard(
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  borderRadius: BorderRadius.circular(R.chip)),
              child: AppIcon(icon, size: 20, color: AppColors.coralInk),
            ),
            const SizedBox(width: Sp.x4),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(title, style: AppText.title)),
                      if (tag != null) ...[
                        const SizedBox(width: Sp.x2),
                        Tag(tag, color: AppColors.warn),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Text(body, style: AppText.captionMuted),
                  ]),
            ),
            const SizedBox(width: Sp.x2),
            AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
          ]),
        ),
      ),
    );
  }
}
