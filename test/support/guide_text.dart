// Test-side implementations of the guide package's callback interfaces.
//
// lib/ui2/guides takes interfaces (GuideText, RevealGate, GuideShellLink,
// SkeletonChrome) instead of closures, because the heavy-calc guard
// (test/guards) resolves method calls and not calls through function values.
// Tests build one-off guides and probes from closures, which is fine here: the
// guard only analyses lib/.

import 'package:flutter/widgets.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/app_shell.dart' show ShellDomain;
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart' show RevealGate;
import 'package:openstrap_edge/ui2/guides/guide_text.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart' show SkeletonChrome;

/// A [GuideText] computed by a closure.
class FnText implements GuideText {
  final String Function(AppLocalizations l) _read;
  const FnText(this._read);

  @override
  String of(AppLocalizations l) => _read(l);
}

/// Shorthand: `fnText((l) => l.tabSleep)`.
GuideText fnText(String Function(AppLocalizations l) read) => FnText(read);

/// A [RevealGate] read from a closure.
class FnGate implements RevealGate {
  final bool Function() _open;
  const FnGate(this._open);

  @override
  bool get isOpen => _open();
}

/// A [SkeletonChrome] computed by a closure.
class FnChrome implements SkeletonChrome {
  final List<Rect> Function(Element root) _read;
  const FnChrome(this._read);

  @override
  List<Rect> of(Element root) => _read(root);
}

/// A [GuideShellLink] that records and forwards to closures.
class FnShellLink implements GuideShellLink {
  final void Function(ShellDomain tab) _selectTab;
  final Future<void> Function() _openSettings;
  const FnShellLink({required void Function(ShellDomain tab) selectTab, required Future<void> Function() openSettings})
      : _selectTab = selectTab,
        _openSettings = openSettings;

  @override
  void selectTab(ShellDomain tab) => _selectTab(tab);

  @override
  Future<void> openSettings() => _openSettings();
}
