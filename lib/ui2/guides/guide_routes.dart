import 'package:flutter/widgets.dart';

/// Reads the Navigator's actual top route without subscribing foreign elements
/// to inherited widgets. Mounted once beside the app's other route observers.
class GuideRouteObserver extends NavigatorObserver {
  Route<dynamic>? _top;

  Route<dynamic>? get topRoute => _top;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _top = topRoute;
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
