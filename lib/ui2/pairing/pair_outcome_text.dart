import '../../ble/band_identity.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/display_text.dart' show localizedText;

/// The sentence for a failed or refused pairing, in the user's language; null
/// when the device was saved. [l] is null only where no localizations are
/// mounted (a bare test widget), which falls back to English.
String? pairOutcomeText(AppLocalizations? l, PairOutcome o) {
  final b = o.isBand;
  if (b != null) {
    final label = o.modelCertain ? localizedText(l, b.label) : 'WHOOP';
    return l?.pairBandNotSensor(label) ??
        'That device is a $label, a band, not a plain sensor. '
            'Nothing was saved.';
  }
  return o.error;
}
