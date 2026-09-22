// The one barrel for the one design system.
//
// The system this replaces shipped two — `lib/ui/design/` and `lib/ui/kit/` —
// re-exported from a single file, so a screen could pick either and no import
// told you which. There is exactly one here, and nothing outside lib/ui2
// should import its parts individually.

export 'app_shell.dart';
export 'charts.dart';
export 'community_links.dart';
export 'grammar.dart';
export 'live_hr.dart';
export 'ecg_widgets.dart';
export 'nudges.dart';
export 'paint_activity.dart';
export 'revision.dart';
export 'scroll_hint.dart';
export 'theme.dart';
