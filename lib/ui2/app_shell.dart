// The four-tab shell.
//
// Today · Sleep · Activity · Health. Stable: the contents personalise, the
// mental map does not. Profile is not a tab; every tab's header carries the
// avatar into it.
//
// Volt (DESIGN_OVERHAUL §5.3): the bar is a frosted Glass pill that FLOATS over
// the tabs, which run full-bleed behind it, and the active tab is volt in every
// domain (decision D1). A domain's hue no longer colours the bar — it feeds
// that screen's hero glow instead. Because the bar floats, every tab's scroll
// view ends in `S.navClear(context)` of padding so its last row can be lifted
// clear of it.
//
// There is no fifth tab, and the type system is what says so — [ShellDomain]
// is a closed enum and [AppShell] takes a builder keyed by it, so "just add a
// tab for X" is a change to this file with a reviewer attached, not something
// a screen can do on its own. Anything that feels like another destination is
// a section or a pushed screen inside the domain that owns it.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import 'grammar.dart';
import 'theme.dart';

/// The four primary destinations, in bar order.
enum ShellDomain {
  today('Today', LucideIcons.house, C.domHome),
  sleep('Sleep', LucideIcons.moon, C.domSleep),
  activity('Activity', LucideIcons.dumbbell, C.domMove),
  health('Health', LucideIcons.heartPulse, C.domHealth);

  const ShellDomain(this.label, this.icon, this.accent);

  final String label;
  final IconData icon;

  /// [label] in the user's language. Own keys rather than the screen titles,
  /// so two tabs can never end up with the same translated word.
  String title(BuildContext c) {
    final l = AppLocalizations.of(c);
    return switch (this) {
          ShellDomain.today => l?.tabToday,
          ShellDomain.sleep => l?.tabSleep,
          ShellDomain.activity => l?.tabActivity,
          ShellDomain.health => l?.tabHealth,
        } ??
        label;
  }

  /// The domain's pigment — the hue of its hero glow and aurora, NOT of the
  /// tab bar (D1). Use `P.of(context).on(accent)` for text and `.fill(accent)`
  /// for a filled surface — the raw value is not AA-safe.
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
  /// (which domains conventionally use to scroll to top) and a return via Back.
  final void Function(ShellDomain domain)? onSelect;

  /// Pinned between the domain and the tab bar, above every tab. This is not
  /// a general slot — it exists for state that is RUNNING and is not on
  /// screen, which today means a minimised workout. A domain's own content
  /// belongs inside the domain.
  final Widget? banner;

  const AppShell({
    super.key,
    required this.builder,
    this.initial = ShellDomain.today,
    this.onSelect,
    this.banner,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late ShellDomain _current = widget.initial;
  late final Set<ShellDomain> _built = {widget.initial};
  // Tabs are kept alive, not pushed onto the Navigator. Keep their history
  // here so Android Back can return to the previous tab. A restored tab or
  // cold-launch deep link has Today as its way back into the app.
  late final List<ShellDomain> _history = [
    if (widget.initial != ShellDomain.today) ShellDomain.today,
  ];

  void _select(ShellDomain d) {
    setState(() {
      // Each tab at most once, most recent last, so switching back and forth
      // between two tabs does not add a Back press per switch. Today stays in
      // as the way back into the app even while it is the tab on screen.
      if (d != _current) {
        _history.remove(_current);
        // Leaving Today puts it back at the bottom, never on top: it is the
        // last stop before Back leaves the app.
        if (_current == ShellDomain.today) {
          _history.insert(0, _current);
        } else {
          _history.add(_current);
        }
        if (d != ShellDomain.today) _history.remove(d);
      }
      _current = d;
      _built.add(d);
    });
    widget.onSelect?.call(d);
  }

  void _back() {
    if (_history.isEmpty) return;
    setState(() {
      _current = _history.removeLast();
      _built.add(_current);
    });
    widget.onSelect?.call(_current);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return PopScope<Object?>(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: p.bg,
        // The tabs run behind the bar; each one clears it with S.navClear.
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: IndexedStack(
                  index: _current.index,
                  children: [
                    // An unvisited tab is an empty box, not a built screen —
                    // the old shell built all forty screens' worth of state on
                    // launch.
                    for (final d in ShellDomain.values)
                      if (_built.contains(d))
                        widget.builder(c, d)
                      else
                        const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
            Positioned(
              left: S.x4,
              right: S.x4,
              bottom: S.x4 + MediaQuery.paddingOf(c).bottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The minimised workout floats just above the bar as its
                  // own glass pill. Two blurs on screen, the §5.7 budget.
                  if (widget.banner != null) ...[
                    Glass(radius: R.rPill, child: widget.banner!),
                    const SizedBox(height: S.x2),
                  ],
                  _TabBar(current: _current, onTap: _select),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final ShellDomain current;
  final ValueChanged<ShellDomain> onTap;

  const _TabBar({required this.current, required this.onTap});

  @override
  Widget build(BuildContext c) {
    return Glass(
      radius: R.rPill,
      // A minimum, not a height: the labels cap their own scale below, but
      // the bar should still be free to grow rather than ever clip.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: S.navBar),
        child: Padding(
          padding: const EdgeInsets.all(S.x1),
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

/// One destination: icon over label. The active one is a volt pill holding
/// dark ink; the rest are bare ink3. The label is on EVERY tab, active or not
/// — for screen readers, and because an icon alone is a guess at 3× text.
class _Tab extends StatelessWidget {
  final ShellDomain domain;
  final bool on;
  final VoidCallback onTap;

  const _Tab({required this.domain, required this.on, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final fill = p.fill(C.volt);
    final ink = on ? p.inkOn(fill) : p.ink3;
    final label = domain.title(c);
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: motion(c, Motion.base),
          curve: Ease.standard,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: S.x1),
          decoration: BoxDecoration(
            color: on ? fill : const Color(0x00000000),
            borderRadius: R.rPill,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(domain.icon, size: I.md, color: ink),
              const SizedBox(height: 2),
              // Four equal slots cannot hold a 3.1x label, so the bar's text
              // stops growing at 1.3x — the way the platform's own bars do.
              // The full label is still spoken, and the content is not capped.
              MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                // Shrinks rather than truncates: "Активность" is a whole word
                // or it is a different word. (A long label scales down a
                // little; it is never cut.)
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: F.over.copyWith(
                      color: ink,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
