import 'app_localizations.dart';
import 'display_text.dart';
import 'presentation_text.dart';

/// Translate only the on-device sweep's existing sentence contracts.
/// The evidence, original findings and model request remain unchanged.
String sweepText(AppLocalizations? l, String text) {
  if (l == null || l.localeName == 'en') return text;
  String value(String input) {
    const names = [
      'resting heart rate',
      'sleep efficiency',
      'time asleep',
      'readiness',
      'strain',
      'steps',
      'HRV',
    ];
    for (final name in names) {
      if (input.toLowerCase().startsWith('${name.toLowerCase()} ')) {
        return '${localizedText(l, name)} ${presentationText(l, input.substring(name.length + 1))}';
      }
    }
    return input;
  }

  final finding = RegExp(
    r'^(.*?) — (above your usual range|below your usual range|the highest in (\d+) days|the lowest in (\d+) days) \(usually (.*?)\)$',
  ).firstMatch(text);
  if (finding != null) {
    final direction = finding[3] != null
        ? l.supplementSweepHighest(finding[3]!)
        : finding[4] != null
        ? l.supplementSweepLowest(finding[4]!)
        : finding[2] == 'above your usual range'
        ? l.supplementSweepAbove
        : l.supplementSweepBelow;
    final range = finding[5]!
        .split('–')
        .map((s) => presentationText(l, s))
        .join('–');
    return l.supplementSweepFinding(value(finding[1]!), direction, range);
  }
  final pair = RegExp(
    r'^(.*?) and (.*?) — both outside your usual range on the same day, which is worth noticing but is not a measured relationship between them$',
  ).firstMatch(text);
  if (pair != null) {
    return l.supplementSweepPair(value(pair[1]!), value(pair[2]!));
  }
  return text;
}
