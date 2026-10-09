import 'package:intl/intl.dart';

import '../state/locale_controller.dart';

/// Display precision only. Does not change values, parsing or stored units.
String displayFixed(num value, int places) => NumberFormat(
  places == 0 ? '0' : '0.${'0' * places}',
  LocaleController.displayLanguageCode,
).format(value);
