// Geometry of the actual announced focus, whether the step or its route back. Tests of card/input/visibility use this; style tests inspect the paint itself.
import 'package:flutter/widgets.dart'; import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
Finder get liveGuideFocus => find.byWidgetPredicate((w) => w is Semantics && (w.key == LiveGuideOverlay.targetProxyKey || w.key == LiveGuideOverlay.routeProxyKey));
