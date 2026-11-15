import 'package:flutter/widgets.dart';
import 'guide_navigation.dart';
import 'guide_target.dart';
import '../../l10n/app_localizations.dart';

/// Reads the Navigator's actual top route without subscribing foreign elements
/// to inherited widgets. Mounted once beside the app's other route observers.
class GuideRouteObserver extends NavigatorObserver with ChangeNotifier {
  Route<dynamic>? _top;
  // This observer owns the actual Navigator stack. The declaration supplies
  // destinations; this stack supplies Back hops for pages with multiple entries.
  final _stack = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) { _stack.add(route); }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) { _stack.remove(route); }
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) { _stack.remove(route); }
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (at >= 0) {
      if (newRoute == null) { _stack.removeAt(at); } else { _stack[at] = newRoute; }
    }
  }

  /// Actual Back hops, then the declared tab/sub-tab/page entry path. A page
  /// reachable from two tabs returns to the tab it was opened from.
  List<GuideHop> routeTo(GuideNode destination) {
    final pages = _stack.whereType<PageRoute<dynamic>>().toList();
    final hops = <GuideHop>[];
    GuideNode? here;
    Element? rootPage;
    for (var i = pages.length - 1; i >= 0; i--) {
      final root = pages[i].subtreeContext;
      rootPage = root is Element && root.mounted ? root : null;
      here = root is Element && root.mounted ? GuideNavigation.location(root) : null;
      if (here != null && GuideNavigation.onPath(here, destination)) break;
      if (i == 0) break;
      final previous = pages[i - 1].subtreeContext;
      final back = previous is Element && previous.mounted ? GuideNavigation.location(previous) : null;
      hops.add(GuideHop(back ?? destination, GuideHopKind.back));
    }
    if (here != null) {
      final tail = GuideNavigation.route(here, destination);
      final first = tail.firstOrNull;
      final parked = first?.kind == GuideHopKind.tab && rootPage != null
          ? GuideNavigation.parkedLocation(rootPage, GuideNavigation.tabOf(first!.node))
          : null;
      if (parked == null) {
        hops.addAll(tail);
      } else {
        hops.add(GuideHop(parked, GuideHopKind.tab));
        hops.addAll(GuideNavigation.route(parked, destination));
      }
    }
    return hops;
  }

  /// Count only expansions discoverable on the retained destination page.
  /// Unvisited pages are re-evaluated once navigation builds them.
  int accordionHopsTo(GuideNode destination, GuideTarget target, AppLocalizations l) {
    for (final route in _stack.whereType<PageRoute<dynamic>>().toList().reversed) {
      final root = route.subtreeContext;
      if (root is! Element || !root.mounted) continue;
      final page = GuideNavigation.parkedPage(root, GuideNavigation.tabOf(destination)) ?? root;
      if (GuideNavigation.location(page, includeOffstage: true) != destination) continue;
      final found = target.resolve(page, l);
      if (found is TargetBehindAccordion) return found.accordions.length;
    }
    return 0;
  }

  Route<dynamic>? get topRoute => _top;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _top = topRoute;
    notifyListeners(); // the overlay hides under a dialog in the next frame
  }

  /// Includes the departing route above the newly current page after a pop.
  bool get isTransitioning {
    final route = _top;
    return route is PageRoute && (route.animation?.isCompleted == false ||
        route.secondaryAnimation?.isDismissed == false);
  }

  /// Null for popups and while the page is entering or leaving.
  Element? get page {
    final route = _top;
    if (route is! PageRoute || !route.isCurrent || isTransitioning) return null;
    final root = route.subtreeContext;
    return root is Element && root.mounted ? root : null;
  }
}
