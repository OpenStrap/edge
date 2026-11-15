// Fixture for the reusable accordion boundary; main's Sleep page has no accordions.
import 'package:flutter/material.dart'; import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ui2/ui2.dart'; import 'package:openstrap_edge/ui2/guides/guide_accordion.dart'; import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
String accordionPrefKey(String id) => 'accordion_$id';
/// A titled card whose rows open and close behind an explicit header tap. It
/// starts expanded: every setting is visible until the person folds a section
/// away. The header always stays in place, so a group never appears or moves
/// because some setting elsewhere changed; only this header's own tap changes
/// its height. Folded, [summary] stays under the title as one line, so a closed
/// section still says what is inside it.
///
/// With an [id] the open or folded state is remembered between visits, through
/// the app-prefs section of [SettingsRepository] (one bool per section, written
/// when it is toggled). A section that was never toggled starts as
/// [initiallyExpanded]. Without an [id] nothing is stored.
///
/// The open flag lives in a State, and the lists these sit in gain and lose
/// neighbours (a permission card, a "not connected" card). Positionally, a
/// neighbour would inherit the folded section's State and fold or open with it.
/// So this widget is a thin const description and the State sits in a card
/// keyed by [id]: an accordion that moves gets the State for its own id.
class SettingsAccordion extends StatelessWidget { const SettingsAccordion(this.title, {super.key, required this.children, this.summary,
      this.id, this.initiallyExpanded = true}); final String title; final List<Widget> children; final String? summary;
  /// Screen id + section id, e.g. "settings_band". See [accordionPrefKey].
  final String? id; final bool initiallyExpanded;
  @override Widget build(BuildContext context) => _SettingsAccordionCard( key: id == null ? null : ValueKey<String>('accordion_$id'), this); }
class _SettingsAccordionCard extends StatefulWidget { const _SettingsAccordionCard(this.a, {super.key}); final SettingsAccordion a;
  @override State<_SettingsAccordionCard> createState() => _SettingsAccordionState(); }
class _SettingsAccordionState extends State<_SettingsAccordionCard> { late bool _open = _remembered(); final _headerKey = GlobalKey();
  /// Set once the person has toggled it: a stored answer that arrives after
  /// that must not undo what they just did.
  /// The stored answer for this id, read synchronously from the start-up
  /// cache ([Prefs.ensureLoaded] runs before runApp), else [initiallyExpanded].
  /// Building in the remembered state on the first frame matters: a folded
  /// section built open and folded a frame later makes a long page shrink under
  /// a person who has already started scrolling it. Before the cache is loaded
  /// this is the default, and [_restore] still corrects it.
  bool _remembered() { final id = widget.a.id; if (id == null) return widget.a.initiallyExpanded; return widget.a.initiallyExpanded; }
  @override void initState() { super.initState(); _restore(); }
  @override void didUpdateWidget(_SettingsAccordionCard old) { super.didUpdateWidget(old); if (old.a.id == widget.a.id) return;
    // This State now belongs to another section: show that section's answer, not the one it held, and let a read still in flight for the old id lapse.
    _open = _remembered(); _restore(); } Future<void> _restore() async {} Future<void> _toggle() async { setState(() { _open = !_open; }); }
  @override Widget build(BuildContext c) { final p = P.of(c); final summary = widget.a.summary;
    final discovery = GuideDimScope.controllerOf(c)?.discovery; if (discovery == null) return _card(c, p, summary, false);
    return ValueListenableBuilder<bool>(valueListenable: discovery, builder: (c, discovering, _) => _card(c, p, summary, discovering)); }
  Widget _card(BuildContext c, P p, String? summary, bool discovering) { return Padding( padding: const EdgeInsets.only(top: S.x3),
      // The card is drawn here rather than by Surface, which wraps its child in an inert Pressable: the first Pressable inside an accordion is its
      // header, the only control a tap or a screen reader should find first.
      child: GuideBox(card: true, child: Container( width: double.infinity, decoration: BoxDecoration( color: p.card, borderRadius: R.rLg,
          boxShadow: p.el(1), ), child: Column(children: [ GuideNavigationHeader(key: _headerKey, child: Pressable( onTap: _toggle,
            semanticLabel: '${widget.a.title}, ${_open ? 'expanded' : 'collapsed'}', child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3), child: Row(children: [ Expanded( child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [ Text(widget.a.title, style: F.body.copyWith(
                                color: p.ink, fontWeight: FontWeight.w600)), if (!_open && summary != null && summary.isNotEmpty)
                          Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: F.over.copyWith(color: p.ink3)), ]), ),
                Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 17, color: p.ink3), ]), ), )),
          GuideAccordionBody(title: widget.a.title, headerKey: _headerKey, offstage: !_open, child: TickerMode(enabled: _open, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4), child: Column(children: [ if (_open || discovering)
                for (final row in widget.a.children) ...[ Divider(color: p.line, height: 1), row, ], ])))), ]), )), ); } }
/// A label with a switch. The switch carries the state, so the row prints no
/// "On"/"Off" word that a screen would then have to count.
