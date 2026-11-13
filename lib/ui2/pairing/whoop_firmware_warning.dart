import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../ui2.dart';

/// Shared by the connection picker and WHOOP pairing, including retries.
/// Keep this advisory: a firmware number alone cannot prove a band is locked.
class WhoopFirmwareWarning extends StatelessWidget {
  const WhoopFirmwareWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(
        color: p.on(C.orange).withValues(alpha: 0.12),
        border: Border.all(color: p.on(C.orange), width: 2),
        borderRadius: R.rLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.triangleAlert, color: p.on(C.orange)),
              const SizedBox(width: S.x3),
              Expanded(
                child: Text(
                  l?.whoopFirmwareWarningTitle ??
                      'WHOOP users: do not reconnect to the WHOOP app',
                  style: F.body.copyWith(
                    color: p.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: S.x3),
          Text(
            l?.whoopFirmwareWarningAction ??
                'If you use OpenStrap or another open-source app, or plan to '
                    'switch to one later, do not connect your band to the '
                    'official WHOOP app again. It can install firmware updates '
                    'automatically. Uninstall or disable the WHOOP app to '
                    'prevent it from updating your band.',
            style: F.body.copyWith(color: p.ink, height: 1.4),
          ),
          const SizedBox(height: S.x3),
          Text(
            l?.whoopFirmwareWarningDetails ??
                'Reports on WHOOP 5.0 / MG firmware 50.43.1.0 and 50.43.2.0 '
                    'describe blocked data access. Bluetooth may still '
                    'connect. OpenStrap cannot issue the WHOOP-signed '
                    'membership token needed to unlock affected bands. '
                    'We are working on a solution, but no fix is available yet.',
            style: F.cap.copyWith(color: p.ink2, height: 1.4),
          ),
        ],
      ),
    );
  }
}
