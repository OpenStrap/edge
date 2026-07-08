// AppScaffold — one consistent screen chrome so every screen gets a correct
// back button, aligned title, safe areas, and the standard gutter for free.
//
//   AppScaffold(
//     title: 'Sleep',
//     subtitle: 'Last night',
//     actions: [RoundIconButton(OsIcon.calendar, onTap: …)],
//     children: [ …cards… ],          // scrolling list with screen gutters
//   )
//
// Pass [body] instead of [children] for full control (custom scroll views,
// non-scrolling screens). The back button appears automatically whenever the
// route can pop (override with [showBack]).

import 'package:flutter/material.dart';
import '../kit/os_icons.dart';
import 'package:flutter/services.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'pressable.dart';

/// The standard circular back button (also usable stand-alone in custom
/// headers). Pops via `Navigator.maybePop`.
class AppBackButton extends StatelessWidget {
  final VoidCallback? onBack;
  const AppBackButton({super.key, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Back',
      child: Pressable(
        pressedScale: 0.92,
        onTap:
            onBack ??
            () {
              HapticFeedback.selectionClick();
              Navigator.of(context).maybePop();
            },
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
            border: AppColors.isDark
                ? Border.all(color: AppColors.divider)
                : null,
            boxShadow: Elevation.shadows(1),
          ),
          child: Center(
            child: OsAppIcon(OsIcon.arrowLeft, size: 18),
          ),
        ),
      ),
    );
  }
}

class AppScaffold extends StatelessWidget {
  final String? title;

  /// Custom title widget (overrides [title]).
  final Widget? titleWidget;

  /// Quiet line under the title ("Last night", a date…).
  final String? subtitle;

  /// Trailing header actions (RoundIconButton and friends).
  final List<Widget> actions;

  /// Force the back button on/off; default = whenever the route can pop.
  final bool? showBack;
  final VoidCallback? onBack;

  /// Convenience: children become a scrolling column with screen gutters.
  final List<Widget>? children;

  /// Full-control body (used when [children] is null). NOT wrapped in a
  /// scroll view or gutter — bring your own.
  final Widget? body;

  /// Rendered above the scroll content, below the header (e.g. a
  /// SegmentedControl period switcher).
  final Widget? header;

  /// Floating bottom overlay (nav pill / primary CTA). Content scrolls
  /// beneath it; scrolling lists get bottom padding to clear it.
  final Widget? bottomBar;

  /// Large (h1) or compact (h2-sized) title.
  final bool largeTitle;

  final ScrollController? scrollController;

  const AppScaffold({
    super.key,
    this.title,
    this.titleWidget,
    this.subtitle,
    this.actions = const [],
    this.showBack,
    this.onBack,
    this.children,
    this.body,
    this.header,
    this.bottomBar,
    this.largeTitle = true,
    this.scrollController,
  }) : assert(
         children != null || body != null,
         'Provide children (managed scroll) or body.',
       );

  @override
  Widget build(BuildContext context) {
    final canPop = showBack ?? (ModalRoute.of(context)?.canPop ?? false);
    final hasHeaderRow =
        canPop || title != null || titleWidget != null || actions.isNotEmpty;

    Widget content;
    if (children != null) {
      content = ListView(
        controller: scrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          Sp.screen,
          Sp.x2,
          Sp.screen,
          bottomBar == null ? Sp.x8 : 120,
        ),
        children: children!,
      );
    } else {
      content = body!;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasHeaderRow)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Sp.screen,
                  Sp.x3,
                  Sp.screen,
                  Sp.x2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (canPop) ...[
                      AppBackButton(onBack: onBack),
                      const SizedBox(width: Sp.x3),
                    ],
                    Expanded(
                      child:
                          titleWidget ??
                          (title == null
                              ? const SizedBox.shrink()
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      title!,
                                      style: largeTitle
                                          ? AppText.h1
                                          : AppText.h2,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (subtitle != null)
                                      Text(
                                        subtitle!,
                                        style: AppText.captionMuted,
                                      ),
                                  ],
                                )),
                    ),
                    for (final a in actions) ...[
                      const SizedBox(width: Sp.x2),
                      a,
                    ],
                  ],
                ),
              ),
            if (header != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Sp.screen,
                  0,
                  Sp.screen,
                  Sp.x2,
                ),
                child: header!,
              ),
            Expanded(
              child: bottomBar == null
                  ? content
                  : Stack(
                      children: [
                        Positioned.fill(child: content),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SafeArea(top: false, child: bottomBar!),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
