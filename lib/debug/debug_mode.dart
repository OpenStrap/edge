import 'package:flutter/foundation.dart' show kDebugMode;

const bool advancedDebugMode = bool.fromEnvironment(
  'DEBUG_MODE',
  defaultValue: false,
);

/// This tool cannot be enabled in profile/release builds.
const bool whoop4R10ResearchEnabled = kDebugMode &&
    bool.fromEnvironment('WHOOP4_R10_RESEARCH', defaultValue: false);
