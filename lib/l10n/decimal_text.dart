import 'package:intl/intl.dart';

import '../state/locale_controller.dart';

/// Display precision only. Does not change values, parsing or stored units.
String displayFixed(num value, int places) => NumberFormat(
  places == 0 ? '0' : '0.${'0' * places}',
  LocaleController.displayLanguageCode,
).format(value);

final RegExp _commaDecimal = RegExp(r'^([+-]?)(\d+),(\d+)$');

/// A number a person typed, or null when it cannot be read as one.
///
/// A decimal comma is accepted when it can only be a decimal: the iOS decimal
/// pad on a German, French, Spanish or Russian region phone has a ',' key and
/// no '.', so rejecting every comma left those users unable to type any
/// fraction at all. "4,5" is never a thousands grouping (a group is always
/// three digits), so it is 4.5. "1,200" is a grouping to half the world and a
/// decimal to the other half, so it stays unreadable and the user is asked,
/// never guessed for. Anything else falls through to [double.tryParse], minus
/// the non-finite literals it accepts ("Infinity", "NaN", "1e400").
double? parseTypedNumber(String text) {
  final s = text.trim();
  final direct = double.tryParse(s);
  if (direct != null) return direct.isFinite ? direct : null;
  final m = _commaDecimal.firstMatch(s);
  if (m == null) return null;
  final whole = m.group(2)!;
  final frac = m.group(3)!;
  final couldBeGrouping =
      frac.length == 3 && whole.length <= 3 && !whole.startsWith('0');
  if (couldBeGrouping) return null;
  final v = double.tryParse('${m.group(1)}$whole.$frac');
  return v != null && v.isFinite ? v : null;
}
