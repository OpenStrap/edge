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
  static const double _metersPerKm = 1000.0;
  static const double _metersPerMile = 1609.344;

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

  /// "70 kg" / "154 lb".
  ///
  /// The odd one out: it still answers a bare dash for null, because its one
  /// caller (health_screen's weight row) only ever passes a measured weight, so
  /// the branch is unreachable today. It should become `String?` like the rest
  /// the next time that screen is open for edit.
  String weight(num? kg) {
    if (kg == null) return '—';
    return isImperial ? '${(kg / _kgPerLb).round()} lb' : '${_trim(kg)} kg';
  }

  /// "180 cm" / "5′11″", or null when there is no height to show. NULL, not a
  /// dash: a formatter cannot know why the value is missing, and the caller
  /// that does must say so rather than print a placeholder.
  String? height(num? cm) {
    if (cm == null) return null;
    if (!isImperial) return '${_trim(cm)} cm';
    final totalIn = (cm / _cmPerIn).round();
    return "${totalIn ~/ 12}′${totalIn % 12}″";
  }

  // ── distance + pace (GPS workout routes) ───────────────────────────────────
  /// Length of one distance unit in metres (km or mi) for the current system.
  double get distanceUnitMeters => isImperial ? _metersPerMile : _metersPerKm;

  /// "km" / "mi".
  String get distanceUnit => isImperial ? 'mi' : 'km';

  /// Distance value in the user's unit (km or mi), unformatted.
  double distanceValue(double meters) => meters / distanceUnitMeters;

  /// "5.24 km" / "3.25 mi", or null when there is no distance. See [height]
  /// on why this is not a dash.
  String? distance(double? meters, {int decimals = 2}) {
    if (meters == null) return null;
    return '${distanceValue(meters).toStringAsFixed(decimals)} $distanceUnit';
  }

  /// "/km" / "/mi".
  String get paceUnit => '/$distanceUnit';

  /// Above this, a "pace" is meaningless noise, not a real number — e.g. a
  /// few metres of GPS jitter (stationary) divided into real elapsed time
  /// produces something like 1000 min/km. 60 min/km is already far slower
  /// than any real walk/run/ride; treat anything beyond it as "no
  /// meaningful pace yet" rather than showing the raw absurd number.
  static const double _kMaxSanePaceSecPerUnit = 60 * 60;

  /// Format a pace given as seconds-per-unit → "m:ss" (e.g. "5:30"). NULL for
  /// infinite / non-finite (a zero-distance split) or an absurdly slow value
  /// (see [_kMaxSanePaceSecPerUnit]) — there is no pace, and the caller drops
  /// the stat rather than printing a placeholder where a number belongs.
  static String? formatPace(double secPerUnit) {
    if (!secPerUnit.isFinite ||
        secPerUnit <= 0 ||
        secPerUnit > _kMaxSanePaceSecPerUnit) {
      return null;
    }
    final total = secPerUnit.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// "5:30 /km" from total metres + total seconds, or NULL whenever there is
  /// no meaningful pace — including the absurd-pace case (see
  /// [_kMaxSanePaceSecPerUnit]), not just meters<=0. Null rather than a dash
  /// so a caller cannot accidentally render "— /km".
  String? pace(double? meters, int? seconds) {
    if (meters == null || seconds == null || meters <= 0 || seconds <= 0) {
      return null;
    }
    final formatted = formatPace(seconds / (meters / distanceUnitMeters));
    return formatted == null ? null : '$formatted $paceUnit';
  }

  /// "km/h" / "mph" — the unit for INSTANTANEOUS speed (cycling reads more
  /// naturally as a speed than a pace; the live map shows both).
  String get speedUnit => isImperial ? 'mph' : 'km/h';

  /// Instantaneous speed (m/s) → "18.4 km/h" / "11.4 mph". NULL for
  /// null/non-finite/negative (no fix yet, or GPS hasn't reported speed) —
  /// there is no speed to show, and the caller owns saying why.
  String? speed(double? metersPerSec, {int decimals = 1}) {
    if (metersPerSec == null || !metersPerSec.isFinite || metersPerSec < 0) {
      return null;
    }
    final perHour = metersPerSec * 3600 / distanceUnitMeters;
    return '${perHour.toStringAsFixed(decimals)} $speedUnit';
  }

  /// Instantaneous pace from a live speed (m/s) → "5:30 /km" — the LIVE
  /// counterpart to [pace] (which needs a whole distance+duration). Used for
  /// a live "current pace" readout that updates every fix instead of only
  /// reflecting the run's average so far.
  String? paceFromSpeed(double? metersPerSec) {
    if (metersPerSec == null || !metersPerSec.isFinite || metersPerSec <= 0) {
      return null;
    }
    final formatted = formatPace(distanceUnitMeters / metersPerSec);
    return formatted == null ? null : '$formatted $paceUnit';
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

  // ── strength load (live workout + summary; storage stays kg) ───────────────
  /// "kg" / "lb" — the bare unit token for a strength load or volume figure.
  String get weightUnit => isImperial ? 'lb' : 'kg';

  /// A load or volume already known to exist, in kg → the number in the
  /// display unit, unrounded (the caller's own formatter, e.g. [grouped] or
  /// a fixed-point trim, rounds it).
  double weightValue(num kg) => isImperial ? kg / _kgPerLb : kg.toDouble();

  /// The stepper increment for a lift, in kg, given the exercise's own kg
  /// step (see `ExerciseDef.step`) — metric uses it untouched; imperial
  /// snaps to a clean 5 lb plate step rather than a raw conversion (2.5 kg
  /// is an ugly ~5.5 lb; nobody loads a bar in that unit). 0 stays 0 for
  /// bodyweight-only lifts.
  double loadStepKg(double kgStep) =>
      isImperial ? (kgStep <= 0 ? 0.0 : 5 * _kgPerLb) : kgStep;
}
