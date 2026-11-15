// GUIDE TEXT: a string a guide shows or matches, in the user's language.
//
// An interface, not a `String Function(AppLocalizations)`: the heavy-calc guard
// (test/guards, AGENTS.md sections 3 and 8) resolves a method call but not a call
// through a function value, and the guide package must not grow its baseline.
// The shipped implementations are the two enums [GuideCopy] (captions, titles,
// footers) and [ScreenLabel] (words printed on the app's own screens); tests use
// their own implementations (test/support/guide_text.dart).

import '../../l10n/app_localizations.dart';

abstract interface class GuideText {
  /// The text in [l]'s language. Never empty for a shipped value
  /// [guide_conformance_test 'CLAIM(guide-copy)'].
  String of(AppLocalizations l);
}
