// import_screen.dart — "Import data" hub. Pull history in from another source:
//   • NOOP raw-sensor CSV → FULL 1 Hz re-derivation (same analytics as a live sync)
//   • Edge backup (.db)    → merge another OpenStrap device's exported database
//   • WHOOP export CSV      → derived-snapshot days + workouts (BETA)
//
// Reachable from onboarding (welcome) AND Profile → Data (a returning user is past
// the welcome gate). Each option: pick file → run via AppState → progress → result.
// Presentation: design-system language; the import logic is untouched.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../design/design.dart';

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
    return AppScaffold(
      title: 'Import data',
      subtitle: 'Bring history from another source',
      children: [
        ...dsStaggered([
          ImportOptionCard(
            icon: Ic.pulse,
            title: 'Import from NOOP',
            body: 'Raw 1 Hz CSV — re-analyzed end-to-end on this phone.',
            onTap: _busy ? null : _importNoop,
          ),
          const SizedBox(height: Sp.x3),
          ImportOptionCard(
            icon: Ic.server,
            title: 'Import from Edge backup',
            body: 'A .db exported from another OpenStrap device.',
            onTap: _busy ? null : _importEdge,
          ),
          const SizedBox(height: Sp.x3),
          ImportOptionCard(
            icon: Ic.history,
            title: 'Import from WHOOP',
            tag: 'BETA',
            body: 'WHOOP export CSVs — derived summaries only.',
            onTap: _busy ? null : _importWhoop,
          ),
        ]),
        const SizedBox(height: Sp.x2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'Imported days sit alongside your band data; band data wins '
                'on overlap.',
                style: AppText.captionMuted,
              ),
            ),
            const InfoDot(
              title: 'How imports work',
              bullets: [
                'NOOP CSVs carry raw 1 Hz sensor data — they get the same '
                    'full analysis as a live sync.',
                'Edge backups merge another device\'s complete history.',
                'WHOOP exports have no raw 1 Hz, so those days import as '
                    'derived summaries.',
                'New band syncs always take priority where days overlap.',
              ],
            ),
          ],
        ),
        const SizedBox(height: Sp.x4),
        if (_busy)
          SurfaceCard(
            level: 0,
            padding: const EdgeInsets.all(Sp.x4),
            child: Row(children: [
              SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accent)),
              const SizedBox(width: Sp.x3),
              Expanded(
                  child:
                      Text(_progress ?? 'Importing…', style: AppText.bodySoft)),
            ]),
          ),
        if (_result != null) ...[
          SurfaceCard(
            level: 0,
            color: AppColors.positiveSoft,
            padding: const EdgeInsets.all(Sp.x4),
            child: Row(children: [
              AppIcon(Ic.check, size: 18, color: AppColors.positive),
              const SizedBox(width: Sp.x3),
              Expanded(
                  child: Text(_result!,
                      style: AppText.body.copyWith(color: AppColors.positive))),
            ]),
          ).dsPop(),
          const SizedBox(height: Sp.x5),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _continue,
              child: const Text('Continue'),
            ),
          ),
          const SizedBox(height: Sp.x2),
          Center(
            child: TextButton(
              onPressed: _busy ? null : () => _set(() => _result = null),
              child: const Text('Import another file'),
            ),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x3),
            child: Text(_error!,
                style: AppText.bodySoft.copyWith(color: AppColors.critical)),
          ),
      ],
    );
  }
}

/// One import source — SurfaceCard + ListRow; disabled while a run is busy.
class ImportOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onTap;
  final String? tag;

  const ImportOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.tag,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: Motion.fast,
      opacity: onTap == null ? 0.5 : 1,
      child: SurfaceCard(
        onTap: onTap,
        padding:
            const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        child: ListRow(
          icon: icon,
          iconColor: AppColors.accent,
          title: title,
          subtitle: body,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tag != null) ...[
                Tag(tag!, color: AppColors.warn),
                const SizedBox(width: Sp.x2),
              ],
              AppIcon(Ic.arrowRight,
                  size: 16, color: AppColors.onSurfaceFaint),
            ],
          ),
        ),
      ),
    );
  }
}
