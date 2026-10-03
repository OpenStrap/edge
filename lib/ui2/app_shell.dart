// The five-tab shell.
//
// Home · Health · Nutrition · Workout · Wellness. Stable forever: the contents
// personalise, the mental map does not. Each domain owns an accent, so colour
// tells you where you are before the label does.
//
// There is no sixth tab, and the type system is what says so — [ShellDomain]
// is a closed enum and [AppShell] takes a builder keyed by it, so "just add a
// tab for X" is a change to this file with a reviewer attached, not something
// a screen can do on its own. Anything that feels like a sixth destination is
// a `SubTabs` inside the domain that owns it.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import 'grammar.dart';
import 'theme.dart';

/// The five primary destinations, in bar order.
enum ShellDomain {
  home('Home', LucideIcons.house, C.domHome),
  health('Health', LucideIcons.heartPulse, C.domHealth),
  nutrition('Nutrition', LucideIcons.utensils, C.domFood),
  workout('Workout', LucideIcons.dumbbell, C.domMove),
  wellness('Wellness', LucideIcons.leaf, C.domMind);

  const ShellDomain(this.label, this.icon, this.accent);

  final String label;
  final IconData icon;

  /// [label] in the user's language. Own keys rather than the screen titles:
  /// zh has Health and Wellness both as 健康, two identical tabs.
  String title(BuildContext c) {
    final l = AppLocalizations.of(c);
    return switch (this) {
          ShellDomain.home => l?.tabHome,
          ShellDomain.health => l?.tabHealth,
          ShellDomain.nutrition => l?.tabNutrition,
          ShellDomain.workout => l?.tabWorkout,
          ShellDomain.wellness => l?.tabWellness,
        } ??
        label;
  }

  /// The domain's pigment. Use `P.of(context).on(accent)` for text and
  /// `.fill(accent)` for a filled surface — the raw value is not AA-safe.
  final Color accent;
}

// There is no `Domain` InheritedWidget. There was one, promising that a screen
// "and anything it pushes" could pick up its accent without threading it — but
// nothing ever read it, and a pushed route could not have: `MaterialApp.home`
// is the gate, so `Navigator.of` pushes above the shell entirely. Screens take
// their accent as a parameter, which is honest about where it comes from.

class AppShell extends StatefulWidget {
  /// Builds the body of one domain. Called lazily — a tab is not built until
  /// it is first selected, then kept alive by the [IndexedStack].
  final Widget Function(BuildContext context, ShellDomain domain) builder;

  final ShellDomain initial;

  /// Notified on every tab change, including a re-tap of the current tab
  /// (which domains conventionally use to scroll to top).
  final void Function(ShellDomain domain)? onSelect;

  /// Pinned between the domain and the tab bar, above every tab. This is not
  /// a general slot — it exists for state that is RUNNING and is not on
  /// screen, which today means a minimised workout. A domain's own content
  /// belongs inside the domain.
  final Widget? banner;

  const AppShell({
    super.key,
    required this.builder,
    this.initial = ShellDomain.home,
    this.onSelect,
    this.banner,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late ShellDomain _current = widget.initial;
  late final Set<ShellDomain> _built = {widget.initial};

  void _select(ShellDomain d) {
    setState(() {
      _current = d;
      _built.add(d);
    });
    widget.onSelect?.call(d);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
            child: IndexedStack(
              index: _current.index,
              children: [
                // An unvisited tab is an empty box, not a built screen — the
                // old shell built all forty screens' worth of state on launch.
                for (final d in ShellDomain.values)
                  if (_built.contains(d))
                    widget.builder(c, d)
                  else
                    const SizedBox.shrink(),
              ],
            ),
          ),
          if (widget.banner != null) widget.banner!,
        ]),
      ),
      bottomNavigationBar: _TabBar(current: _current, onTap: _select),
    );
  }
}

class _TabBar extends StatelessWidget {
  final ShellDomain current;
  final ValueChanged<ShellDomain> onTap;

  const _TabBar({required this.current, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (final d in ShellDomain.values)
                Expanded(
                  child: _Tab(
                    domain: d,
                    on: d == current,
                    onTap: () => onTap(d),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final ShellDomain domain;
  final bool on;
  final VoidCallback onTap;

  const _Tab({required this.domain, required this.on, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = on ? p.on(domain.accent) : p.ink3;
    final label = domain.title(c);
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: motion(c, Motion.base),
              padding: EdgeInsets.symmetric(
                  horizontal: on ? S.x3 : 0, vertical: S.x1),
              decoration: BoxDecoration(
                color: on ? p.wash(domain.accent) : const Color(0x00000000),
                borderRadius: R.rPill,
              ),
              child: Icon(domain.icon, size: 20, color: ink),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: F.over.copyWith(
                color: ink,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
