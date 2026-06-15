// StatusBanner — the home-screen strip for two admin/ops signals:
//   • an OTA "Update available" card (Android installs in-app; iOS / unsupported
//     falls back to opening the download in a browser), and
//   • an admin-pushed alert banner (info / warn / critical) set via the backend
//     admin token. Critical banners can't be dismissed.
// Self-contained: reads AppState, renders nothing when there's nothing to show.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_status.dart';
import '../../state/app_state.dart';
import '../../sync/update_service.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final banner = app.activeBanner;
    final showUpdate = app.updateAvailable;
    if (banner == null && !showUpdate) return const SizedBox.shrink();

    return Column(
      children: [
        if (showUpdate) ...[
          const SizedBox(height: Sp.x4),
          _UpdateCard(update: app.update!, mandatory: app.updateMandatory),
        ],
        if (banner != null) ...[
          const SizedBox(height: Sp.x4),
          _AlertCard(banner: banner, onDismiss: () => app.dismissBanner(banner.id)),
        ],
      ],
    );
  }
}

// ── OTA update card ───────────────────────────────────────────────────────────
class _UpdateCard extends StatelessWidget {
  final UpdateInfo update;
  final bool mandatory;
  const _UpdateCard({required this.update, required this.mandatory});

  @override
  Widget build(BuildContext context) {
    final ver = update.latestVersion != null ? 'v${update.latestVersion}' : 'A new version';
    return ProCard(
      color: AppColors.coralSoft,
      onTap: () => _startUpdate(context, update),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(Ic.cloud, size: 20, color: AppColors.coralDeep),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mandatory ? 'Update required' : 'Update available', style: AppText.title),
                const SizedBox(height: 2),
                Text('$ver is ready to install.', style: AppText.bodySoft),
              ],
            ),
          ),
          const SizedBox(width: Sp.x2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
            decoration: BoxDecoration(
              color: AppColors.coralDeep,
              borderRadius: BorderRadius.circular(R.pill),
            ),
            child: Text('Update',
                style: AppText.label.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// Kick off the update: in-app OTA on Android, browser download elsewhere.
Future<void> _startUpdate(BuildContext context, UpdateInfo update) async {
  final url = update.apkUrl;
  if (url == null || url.isEmpty) return;
  if (!UpdateService.supported) {
    await UpdateService.openInBrowser(url);
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _UpdateDialog(update: update),
  );
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo update;
  const _UpdateDialog({required this.update});
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _running = false;
  int _percent = 0;
  String _phase = '';
  String? _error;

  void _run() {
    setState(() {
      _running = true;
      _error = null;
      _phase = 'downloading';
    });
    UpdateService.install(widget.update.apkUrl!).listen(
      (p) {
        if (!mounted) return;
        if (p.phase == 'error') {
          setState(() => _error = p.message ?? 'Update failed');
        } else {
          setState(() {
            _phase = p.phase;
            _percent = p.percent;
          });
        }
      },
      onError: (e) {
        if (mounted) setState(() => _error = '$e');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final ver = u.latestVersion != null ? 'v${u.latestVersion}' : 'New version';
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(ver, style: AppText.h2),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_running && (u.notes?.isNotEmpty ?? false))
            Text(u.notes!, style: AppText.bodySoft)
          else if (!_running)
            Text("Download and install the latest OpenStrap.", style: AppText.bodySoft),
          if (_running) ...[
            const SizedBox(height: Sp.x2),
            Text(
              _error != null
                  ? 'Could not install automatically.'
                  : _phase == 'installing'
                      ? 'Opening installer…'
                      : 'Downloading… $_percent%',
              style: AppText.bodySoft,
            ),
            const SizedBox(height: Sp.x3),
            if (_error == null)
              ClipRRect(
                borderRadius: BorderRadius.circular(R.pill),
                child: LinearProgressIndicator(
                  value: _phase == 'installing' ? null : (_percent / 100).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: AppColors.coralSoft,
                  color: AppColors.coralDeep,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: Sp.x2),
              Text('Tip: allow "install unknown apps" for OpenStrap, or download in your browser.',
                  style: AppText.captionMuted),
            ],
          ],
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => UpdateService.openInBrowser(widget.update.apkUrl!),
            child: Text('Open in browser', style: AppText.label.copyWith(color: AppColors.coralDeep)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close', style: AppText.label.copyWith(color: AppColors.inkMuted)),
        ),
        if (!_running || _error != null)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.coralDeep),
            onPressed: _run,
            child: Text(_error != null ? 'Retry' : 'Update now'),
          ),
      ],
    );
  }
}

// ── admin alert banner ──────────────────────────────────────────────────────
class _AlertCard extends StatelessWidget {
  final BannerInfo banner;
  final VoidCallback onDismiss;
  const _AlertCard({required this.banner, required this.onDismiss});

  ({Color bg, Color fg, IconData icon}) get _style {
    switch (banner.level) {
      case BannerLevel.critical:
        return (bg: AppColors.warnSoft, fg: AppColors.coralDeep, icon: Ic.shield);
      case BannerLevel.warn:
        return (bg: AppColors.warnSoft, fg: AppColors.warn, icon: Ic.bell);
      case BannerLevel.info:
        return (bg: AppColors.coralSoft, fg: AppColors.coralDeep, icon: Ic.info);
    }
  }

  bool get _hasLink => banner.actionUrl?.isNotEmpty ?? false;

  @override
  Widget build(BuildContext context) {
    final s = _style;
    // Link given → whole card is tappable and opens it. No link → not tappable.
    return ProCard(
      color: s.bg,
      onTap: _hasLink ? () => UpdateService.openInBrowser(banner.actionUrl!) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(s.icon, size: 20, color: s.fg),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (banner.title?.isNotEmpty ?? false) ...[
                  Text(banner.title!, style: AppText.title),
                  const SizedBox(height: Sp.x1),
                ],
                if (banner.text.isNotEmpty) Text(banner.text, style: AppText.bodySoft),
                // Tappable affordance — only when a link is attached.
                if (_hasLink) ...[
                  const SizedBox(height: Sp.x2),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Open', style: AppText.label.copyWith(color: s.fg, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 3),
                    AppIcon(Ic.arrowRight, size: 14, color: s.fg),
                  ]),
                ],
              ],
            ),
          ),
          if (banner.dismissible)
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.only(left: Sp.x2),
                child: AppIcon(Ic.cancel, size: 18, color: AppColors.inkMuted),
              ),
            ),
        ],
      ),
    );
  }
}
