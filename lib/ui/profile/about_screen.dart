// about_screen.dart — Settings → About. Surfaces the affiliation/health-claim
// disclaimer (same attorney-reviewed wording shown once at first run — see
// AffiliationDisclaimer in lib/ui/onboarding/welcome_screen.dart), links to the
// Privacy Policy and NOTICE, the open-source license attribution page, and the
// installed app version. Added as part of app-store-readiness prep; the
// disclaimer wording must not be edited without re-running it past legal
// review.

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/design.dart';
import '../onboarding/welcome_screen.dart' show AffiliationDisclaimer;

/// TODO(legal): both app stores require a *hosted* URL, not a repo file. Point
/// this at the GitHub Pages (or wtf.openstrap.* domain) page once PRIVACY.md
/// is published there — see PRIVACY.md's own TODO for the same gap.
const String kPrivacyPolicyUrl = 'https://openstrap.github.io/edge/PRIVACY.md';

const String kNoticeUrl =
    'https://github.com/OpenStrap/edge/blob/main/NOTICE.md';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _pkg;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (mounted) setState(() => _pkg = p);
    });
  }

  static Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final versionLabel = _pkg == null
        ? null
        : '${_pkg!.version}+${_pkg!.buildNumber}';

    return AppScaffold(
      title: 'About',
      children: [
        const SizedBox(height: Sp.x4),
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: const AffiliationDisclaimer(),
        ),
        const SizedBox(height: Sp.x6),
        const SectionHeader('Legal'),
        _SettingsCard(rows: [
          ListRow(
            icon: OsIcon.activity,
            title: 'Privacy policy',
            divider: true,
            onTap: () => _openUrl(kPrivacyPolicyUrl),
          ),
          ListRow(
            icon: OsIcon.activity,
            title: 'Notice & attribution',
            subtitle: 'Trademark + reverse-engineering disclosure',
            divider: true,
            onTap: () => _openUrl(kNoticeUrl),
          ),
          ListRow(
            icon: OsIcon.activity,
            title: 'Open-source licenses',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Edge',
              applicationVersion: versionLabel,
            ),
          ),
        ]),
        const SizedBox(height: Sp.x6),
        const SectionHeader('Version'),
        _SettingsCard(rows: [
          ListRow(
            icon: OsIcon.activity,
            title: 'Edge',
            value: versionLabel ?? '…',
          ),
        ]),
        const SizedBox(height: Sp.x8),
      ],
    );
  }
}

/// Local copy of ProfileScreen's private `_SettingsCard` shape (a SurfaceCard
/// wrapping stacked ListRows) — kept tiny and duplicated rather than exporting
/// the private widget across files for one screen.
class _SettingsCard extends StatelessWidget {
  final List<ListRow> rows;
  const _SettingsCard({required this.rows});

  @override
  Widget build(BuildContext context) => SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x1),
        child: Column(children: rows),
      );
}
