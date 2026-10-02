import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart'
    show observationTitle;

void main() {
  test('adapter stage ids render localized, vendor names verbatim', () {
    final de = lookupAppLocalizations(const Locale('de'));
    expect(observationTitle('oura_sleep_deep', null, de), 'Tiefschlaf');
    expect(observationTitle('oura_sleep_awake', null, de), 'Wach');
    expect(observationTitle('oura_sleep_deep', null, null), 'Deep sleep');
    expect(observationTitle('BioCharge', null, de), 'BioCharge');
    expect(observationTitle(null, 'hrv_rmssd', de), 'hrv_rmssd');
  });
}
