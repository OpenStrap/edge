// Profile.
//
// Reached from the Home avatar, never a sixth tab — the shell has five
// destinations and the type system says so.
//
// The reference design had a Premium badge and a Following/Followers pair.
// Both are gone, and not for lack of screen space: there is no account and no
// social graph, so a follower count would have to be invented and a premium
// tier would have to be sold. What replaces them is what this app actually
// knows — how much it has measured, and from what.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../health/health_import_state.dart' show storeName;
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/locale_controller.dart';
import '../ui2.dart';
import '../screens/coach.dart' show CoachSetup, coachSubtitle;
import 'devices.dart';
import 'settings.dart';

// ══════════════════ shared list furniture ══════════════════

/// One row in a settings list. Shared by all three profile screens.
class SetRow extends StatelessWidget {
  final IconData? icon;
  final Color color;
  final String title, sub, value;
  final bool danger, chevron;
  final VoidCallback? onTap;

  /// A brand mark in place of [icon] — Lucide has no GitHub/Discord/Reddit
  /// logo, and a generic glyph standing in for one of those is worse than
  /// the extra param. Sized and tinted the same as the [Icon] it replaces.
  final Widget Function(Color tint)? glyph;

  const SetRow(IconData this.icon, this.color, this.title,
      {super.key,
      this.sub = '',
      this.value = '',
      this.danger = false,
      this.chevron = true,
      this.onTap})
      : glyph = null;

  const SetRow.brand(this.glyph, this.color, this.title,
      {super.key,
      this.sub = '',
      this.value = '',
      this.danger = false,
      this.chevron = true,
      this.onTap})
      : icon = null;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final accent = danger ? C.red : color;
    return Pressable(
      onTap: onTap,
      semanticLabel: sub.isEmpty ? title : '$title. $sub',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: p.wash(accent), borderRadius: R.rSm),
            child: glyph != null
                ? glyph!(p.on(accent))
                : Icon(icon, size: 16, color: p.on(accent)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: F.body.copyWith(color: danger ? p.on(C.red) : p.ink)),
              if (value.isNotEmpty && bigText(c))
                Text(value,
                    style: F.cap.copyWith(
                        color: p.ink3, fontWeight: FontWeight.w600)),
              if (sub.isNotEmpty)
                Text(sub, style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          // THE ROW RULE (see MetricRow): the title is the only flexible part,
          // so every value in a settings list ends on one right edge. Two flex
          // children would split the width by ratio and break that column.
          // The value moves UNDER the title at accessibility sizes instead —
          // "2026-08-16 04:12" is arbitrary-length, and at 3.1× it pushed
          // itself and the chevron off the right of every settings screen.
          if (value.isNotEmpty && !bigText(c)) ...[
            const SizedBox(width: S.x2),
            Text(value, style: F.cap.copyWith(color: p.ink3)),
          ],
          if (chevron && !danger) ...[
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
          ],
        ]),
      ),
    );
  }
}

/// A titled card of [SetRow]s, hairline-separated.
Widget settingsGroup(BuildContext c, String title, List<Widget> rows) {
  final p = P.of(c);
  return Section(
    title,
    Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i < rows.length - 1) Divider(color: p.line, height: 1),
        ],
      ]),
    ),
  );
}

/// Push a screen, keeping the enclosing domain accent. Returns when it pops,
/// so a caller whose own numbers the pushed screen can change is able to
/// re-read them.
Future<void> goto(BuildContext c, Widget w) =>
    Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => w));

/// The one way into the profile stack. Home's avatar calls this — profile is
/// a pushed route, never a sixth tab.
void openProfile(BuildContext c) => goto(c, const ProfileHome());

/// Display name for a language code, sourced from a small hardcoded table.
/// Add a row here when a contributor's `app_<code>.arb` lands — nothing else
/// to touch; the picker below only ever offers what [AppLocalizations]
/// actually has translations for.
const Map<String, String> _kLanguageNames = {
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'zh': '中文',
  'hi': 'हिन्दी',
};

String _languageLabel(BuildContext c, String? code) => code == null
    ? (AppLocalizations.of(c)?.languageSystemDefault ?? 'System default')
    : (_kLanguageNames[code] ?? code);

Future<void> _pickLanguage(BuildContext c) async {
  final p = P.of(c);
  final ctrl = c.read<LocaleController>();
  final options = <String?>[null, ...AppLocalizations.supportedLocales.map((l) => l.languageCode)];
  await showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final code in options)
            ListTile(
              title: Text(_languageLabel(sheet, code), style: F.body.copyWith(color: p.ink)),
              trailing: ctrl.code == code
                  ? Icon(LucideIcons.check, size: 18, color: p.on(C.blue))
                  : null,
              onTap: () async {
                await ctrl.setCode(code);
                if (sheet.mounted) Navigator.of(sheet).pop();
              },
            ),
        ],
      ),
    ),
  );
}

/// Human-readable byte size. No dependency for four lines of arithmetic.
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}

// ══════════════════ 1 · PROFILE HOME ══════════════════

/// What the profile screen still shows: who you are, how many sources are
/// live, and how much room the data takes.
///
/// The workouts / records / days / sessions counters are gone with the tile
/// that displayed them. They cost a `getRecords()` and a whole year-of-workouts
/// query on every open, so leaving the fields behind would have kept paying for
/// numbers nobody reads.
class ProfileStats {
  final String? name;
  final int sources;
  final int? storageBytes;

  const ProfileStats({this.name, this.sources = 0, this.storageBytes});
}

class ProfileHome extends StatefulWidget {
  const ProfileHome({super.key});

  @override
  State<ProfileHome> createState() => _ProfileHomeState();
}

class _ProfileHomeState extends State<ProfileHome> {
  /// Re-read after every screen this one pushes. It used to be a single
  /// `late final` Future, so pairing a band from My sources (which auto-pops
  /// straight back here) left the row reading "0 sources", and an import or a
  /// reset left Storage on the old size until the screen was left and
  /// re-entered.
  late Future<ProfileStats> _stats = _load();

  Future<ProfileStats> _load() async {
    final app = context.read<AppState>();
    final repo = app.repo;
    final sources = liveSources(app).length;
    if (repo == null) {
      return ProfileStats(
          name: app.user?['name'] as String?, sources: sources);
    }
    final bytes = await app.dataFileBytes();
    return ProfileStats(
      name: app.user?['name'] as String?,
      sources: sources,
      storageBytes: bytes,
    );
  }

  Future<void> _open(BuildContext c, Widget w) async {
    await goto(c, w);
    // A block body, not `=>`: the arrow form returns the assigned Future, which
    // setState asserts against (debug builds throw and skip the rebuild).
    if (!mounted) return;
    setState(() {
      _stats = _load();
    });
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<ProfileStats>(
        future: _stats,
        builder: (c, snap) => ProfileHomeView(
          stats: snap.data,
          onDevices: () => _open(c, const MyDevices()),
          onSettings: () => _open(c, const MoreSettings()),
          onEdit: () => _open(c, const EditProfile()),
          onCoach: () => _open(c, const CoachSetup()),
        ),
      );
}

class ProfileHomeView extends StatelessWidget {
  /// Null while the counts are still being read — the numbers are absent, not
  /// zero, and a zero rendered during a load is a wrong number on screen.
  final ProfileStats? stats;
  final VoidCallback? onDevices, onSettings, onEdit, onCoach;

  const ProfileHomeView(
      {super.key,
      this.stats,
      this.onDevices,
      this.onCoach,
      this.onSettings,
      this.onEdit,
      });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final s = stats;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.profileTitle ?? 'Profile'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                const SizedBox(height: S.x4),
                settingsGroup(c, l?.profileQuickAccessGroup ?? 'Quick access', [
                  SetRow(LucideIcons.watch, C.blue,
                      l?.profileMyDevices ?? 'My devices',
                      sub: s == null
                          ? ''
                          : (l?.profileSourcesCount(s.sources) ??
                              '${s.sources} source${s.sources == 1 ? '' : 's'}'),
                      onTap: onDevices),
                  SetRow(LucideIcons.userPen, C.purple,
                      l?.profileEditProfile ?? 'Edit profile',
                      sub: l?.profileEditProfileSub ??
                          'Sex, age, height, weight',
                      onTap: onEdit),
                  // THE ONLY DOOR TO THE COACH'S SETUP, and it has to be —
                  // Home's sparkles button is now gated on `coachReady`, so on
                  // a fresh install there is no icon to find it behind. It
                  // belongs here anyway: a model, a base URL and a key are
                  // settings, and the coach's own overflow menu offering the
                  // same form was two doors onto one state.
                  //
                  // `watch` rather than `read` so the sub-line stops saying
                  // "Not set up" the moment it is.
                  Builder(builder: (c) => SetRow(
                      LucideIcons.sparkles, C.purple,
                      AppLocalizations.of(c)?.profileAiCoach ?? 'AI coach',
                      sub: coachSubtitle(c) ??
                          (AppLocalizations.of(c)?.profileNotSetUp ??
                              'Not set up'),
                      onTap: onCoach)),
                  Builder(builder: (c) => SetRow(
                      LucideIcons.languages, C.blue,
                      AppLocalizations.of(c)?.profileLanguage ?? 'Language',
                      sub: _languageLabel(c, c.watch<LocaleController>().code),
                      onTap: () => _pickLanguage(c))),
                ]),
                settingsGroup(c, l?.profileYourDataGroup ?? 'Your data', [
                  SetRow(LucideIcons.database, C.green,
                      l?.profileStorage ?? 'Storage',
                      value: s?.storageBytes == null
                          ? ''
                          : formatBytes(s!.storageBytes!),
                      chevron: false),
                  SetRow(LucideIcons.settings, C.n500,
                      l?.profileMoreSettings ?? 'More settings',
                      // `From $storeName` used to sit on Quick access too. It
                      // came off: height, weight and workouts already moved to
                      // the screens they fill, and what is left — a resting
                      // heart rate the app does not use yet, plus readings from
                      // instruments this band does not have — is not quick and
                      // is not accessed often. It keeps its one door here, and
                      // this line names it so the door is findable.
                      sub: l?.profileMoreSettingsSub(storeName) ??
                          'Import from $storeName, export, backup, units, '
                              'privacy, reset',
                      onTap: onSettings),
                ]),
                settingsGroup(c, l?.profileCommunityGroup ?? 'Community', [
                  SetRow.brand(brandGlyph('assets/icons/github.svg'), C.n500,
                      l?.profileGithubTitle ?? 'GitHub',
                      sub: l?.profileGithubSub ??
                          'Please star and show your support — it helps '
                              'the project grow',
                      onTap: () => open3rdPartyLink(kGithubUrl)),
                  SetRow.brand(brandGlyph('assets/icons/reddit.svg'), C.orange,
                      l?.profileRedditTitle ?? 'Reddit',
                      sub: l?.profileRedditSub ??
                          'Join r/OpenStrap — post your achievements, '
                              'questions, anything',
                      onTap: () => open3rdPartyLink(kRedditUrl)),
                  SetRow.brand(brandGlyph('assets/icons/discord.svg'),
                      C.indigo, l?.profileDiscordTitle ?? 'Discord',
                      sub: l?.profileDiscordSub ??
                          'Hang out with other users and the people '
                              'building this',
                      onTap: () => open3rdPartyLink(kDiscordUrl)),
                  SetRow(LucideIcons.heartHandshake, C.pink,
                      l?.profileSponsorTitle ?? 'Sponsor',
                      sub: l?.profileSponsorSub ??
                          'This is a free, open-source project — '
                              'sponsoring keeps it going',
                      onTap: () => open3rdPartyLink(kSponsorUrl)),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

}
