// Units controller — a LOCAL display preference (metric / imperial). The backend
// always stores and returns metric (kg, cm); this only changes how values are
// shown and how edit fields are parsed. Persisted on-device via SharedPreferences,
// mirroring ThemeController. Nothing here ever touches the server.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UnitSystem { metric, imperial }

extension UnitSystemLabel on UnitSystem {
  String get label => this == UnitSystem.imperial ? 'Imperial' : 'Metric';
}

class UnitsController extends ChangeNotifier {
  static const String _kUnits = 'units_system'; // 'metric' | 'imperial'
  static const double _kgPerLb = 0.45359237;
  static const double _cmPerIn = 2.54;

  UnitSystem _system;
  UnitsController._(this._system);

  factory UnitsController.seed(UnitSystem s) => UnitsController._(s);

  static Future<UnitsController> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    return UnitsController._(_parse(prefs.getString(_kUnits)));
  }

  static UnitSystem _parse(String? s) =>
      s == 'imperial' ? UnitSystem.imperial : UnitSystem.metric;

  UnitSystem get system => _system;
  bool get isImperial => _system == UnitSystem.imperial;

  Future<void> setSystem(UnitSystem s) async {
    if (_system == s) return;
    _system = s;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUnits, s.name);
  }

  // ── display (input is always metric, as stored) ────────────────────────────
  String _trim(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// "70 kg" / "154 lb" / "—".
  String weight(num? kg) {
    if (kg == null) return '—';
    return isImperial ? '${(kg / _kgPerLb).round()} lb' : '${_trim(kg)} kg';
  }

  /// "180 cm" / "5′11″" / "—".
  String height(num? cm) {
    if (cm == null) return '—';
    if (!isImperial) return '${_trim(cm)} cm';
    final totalIn = (cm / _cmPerIn).round();
    return "${totalIn ~/ 12}′${totalIn % 12}″";
  }

  // ── edit-field helpers (display ↔ metric for storage) ──────────────────────
  String get weightLabel => isImperial ? 'Weight (lb)' : 'Weight (kg)';
  String get heightLabel => isImperial ? 'Height (in)' : 'Height (cm)';

  /// Pre-fill value for the weight field in the user's units.
  String weightField(num? kg) =>
      kg == null ? '' : (isImperial ? (kg / _kgPerLb).round().toString() : _trim(kg));

  /// Pre-fill value for the height field in the user's units (total inches).
  String heightField(num? cm) =>
      cm == null ? '' : (isImperial ? (cm / _cmPerIn).round().toString() : _trim(cm));

  /// Parse a weight field (display units) → kg for storage.
  double? weightToKg(String text) {
    final v = double.tryParse(text.trim());
    if (v == null) return null;
    return isImperial ? v * _kgPerLb : v;
  }

  /// Parse a height field (display units = total inches when imperial) → cm.
  double? heightToCm(String text) {
    final v = double.tryParse(text.trim());
    if (v == null) return null;
    return isImperial ? v * _cmPerIn : v;
  }
}
