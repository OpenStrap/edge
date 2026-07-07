// The app's shared-axis fade-through page transition, packaged as a
// [PageTransitionsBuilder] so it plugs into ThemeData.pageTransitionsTheme
// (see buildOpenStrapTheme).
//
// NAVIGATION CONTRACT — why this is a PageTransitionsBuilder and not a custom
// PageRouteBuilder: routing the transition through the theme lets every push
// stay a plain MaterialPageRoute, which on iOS resolves to the Cupertino
// transition WITH the interactive edge-swipe-back gesture. A raw
// PageRouteBuilder has no back-gesture machinery, so it silently kills
// swipe-back on every pushed screen. This builder is therefore registered for
// Android-likes ONLY; iOS/macOS keep CupertinoPageTransitionsBuilder.

import 'package:flutter/material.dart';

/// Shared-axis fade-through: the incoming page fades in with a subtle rise
/// while the outgoing one recedes — the app's warm, settled motion language.
class SharedAxisPageTransitionsBuilder extends PageTransitionsBuilder {
  const SharedAxisPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final inCurve =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    // Incoming: fade + a small rise. Outgoing (secondary): fade + slight recede.
    final rise = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(inCurve);
    final recede = Tween<double>(begin: 1.0, end: 0.985).animate(
      CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic),
    );
    final dim = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeIn),
    );
    return FadeTransition(
      opacity: dim,
      child: ScaleTransition(
        scale: recede,
        child: FadeTransition(
          opacity: inCurve,
          child: SlideTransition(position: rise, child: child),
        ),
      ),
    );
  }
}
