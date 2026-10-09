import '../../l10n/display_text.dart';
// Profile setup.
//
// The audit found this screen promising one thing and enforcing another: the
// copy said "leave a field blank and only that metric stays unknown — never
// guessed", and the validator then refused to continue until all four were
// filled. A promise the form contradicts is worse than no promise, because it
// teaches the user that the honesty copy elsewhere is decoration too.
//
// So: every field is optional except sex, which is the one input with no
// honest default — the analytics coefficient tables key on it and the
// midpoint of two sexes is a third person. Everything else that is blank
// simply withholds the metrics that need it.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/date_text.dart';
import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../screens/home_screen.dart' show monthShortName, weekdayShortName;
import '../ui2.dart';

class ProfileSetupScreen extends StatefulWidget {
  /// Called after the profile has been written. The router uses it to let a
  /// deliberately-partial profile through the gate.
  final VoidCallback? onDone;

  const ProfileSetupScreen({super.key, this.onDone});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  @override
  Widget build(BuildContext c) {
    final app = context.read<AppState>();
    return ProfileSetupView(
      initial: app.user ?? const {},
      units: context.watch<UnitsController>(),
      onSave: (fields) async {
        await app.updateProfile(fields);
        widget.onDone?.call();
      },
    );
  }
}

/// The three answers the analytics coefficient tables can take.
///
/// 'other' maps to the non-binary block FOR CALORIES, which is the published
/// mean of the two sex constants. It does NOT for training load: Banister
/// publishes two constants and no third, so `nonbinary` collapses onto the
/// male pair everywhere TRIMP and the 0–21 strain score are computed
/// (`derivation_engine.dart` says so at its collapse). The screen says which,
/// because a woman who picks it is otherwise scored as a man with nothing on
/// screen admitting it.
List<(String, String)> _sexes(BuildContext c) {
  final l = AppLocalizations.of(c);
  return [
    ('m', l?.profileSetupSexMale ?? 'Male'),
    ('f', l?.profileSetupSexFemale ?? 'Female'),
    ('other', l?.profileSetupSexPreferNotToSay ?? 'Prefer not to say'),
  ];
}

class ProfileSetupView extends StatefulWidget {
  final Map<String, dynamic> initial;
  final Future<void> Function(Map<String, dynamic> fields) onSave;

  /// Display units for height and weight. Null is metric, which is also what
  /// the storage is.
  final UnitsController? units;

  const ProfileSetupView(
      {super.key, required this.onSave, this.initial = const {}, this.units});

  @override
  State<ProfileSetupView> createState() => _ProfileSetupViewState();
}

class _ProfileSetupViewState extends State<ProfileSetupView> {
  late final UnitsController _u =
      widget.units ?? UnitsController.seed(UnitSystem.metric);
  late String? _sex = (widget.initial['sex'] as String?)?.toLowerCase();
  late final _age = TextEditingController(text: _str(widget.initial['age']));
  late final _height = TextEditingController(
      text: _u.heightField(widget.initial['height_cm'] as num?));
  late final _weight = TextEditingController(
      text: _u.weightField(widget.initial['weight_kg'] as num?));

  static String _str(Object? v) => v == null ? '' : '$v';

  @override
  void dispose() {
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  /// Only what was actually entered. A blank field writes nothing, so the
  /// dependent metric abstains rather than scoring somebody else's body. The
  /// fields are typed in the units on their labels and stored in metric.
  Map<String, dynamic> _fields() => {
        if (_sex != null) 'sex': _sex,
        if (Typed.of(_age.text).value case final v?) 'age': v.round(),
        'height_cm': ?_u.heightToCm(_height.text),
        'weight_kg': ?_u.weightToKg(_weight.text),
      };

  /// Continue, unless something typed cannot be read — a typo is not a blank,
  /// and dropping it silently is how a body ends up half-described.
  Future<void> _continue() async {
    final bad = [
      if (Typed.of(_age.text).bad) 'Age',
      if (Typed.of(_height.text).bad) uiText(context, _u.heightLabel),
      if (Typed.of(_weight.text).bad) uiText(context, _u.weightLabel),
    ];
    if (bad.isNotEmpty) {
      sayUnreadable(context, bad);
      return;
    }
    await widget.onSave(_fields());
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final sexes = _sexes(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(S.x4, S.x6, S.x4, S.x8),
          children: [
            Text(l?.profileSetupTitle ?? 'About you',
                style: F.t1.copyWith(color: p.ink)),
            const SizedBox(height: S.x3),
            Text(
              l?.profileSetupBody ??
                  'Four numbers change how your data is scored. Leave any of them '
                      'blank and only the metrics that need it stay unavailable.',
              style: F.body.copyWith(color: p.ink2),
            ),
            const SizedBox(height: S.x6),
            Text(l?.profileSetupSexHeader ?? 'SEX',
                style: F.over.copyWith(color: p.ink3)),
            const SizedBox(height: S.x2),
            Row(children: [
              for (final (key, label) in sexes) ...[
                Expanded(
                  child: _Choice(
                    label: label,
                    on: _sex == key,
                    onTap: () => setState(() => _sex = key),
                  ),
                ),
                if (key != sexes.last.$1) const SizedBox(width: S.x2),
              ],
            ]),
            // Which constants that choice actually gets. Calories average the
            // two published sets; training load has no third set to average,
            // so it uses the male one — said here rather than nowhere.
            if (_sex == 'other') ...[
              const SizedBox(height: S.x2),
              Text(
                l?.profileSetupOtherSexNote ??
                    'Calories use the mean of the two published sets. Training '
                        'load and strain have only two published constants and no '
                        'third, so they use the male pair.',
                style: F.cap.copyWith(color: p.ink3, height: 1.45),
              ),
            ],
            const SizedBox(height: S.x5),
            _Field(_age, l?.profileSetupAgeLabel ?? 'AGE',
                l?.profileSetupAgeUnit ?? 'years',
                l?.profileSetupAgeConsequence ??
                    'Without it: heart-rate zones, calories, fitness age.'),
            _Field(
              _height,
              l?.profileSetupHeightLabel ?? 'HEIGHT',
              uiText(c, _u.isImperial ? 'in' : 'cm'),
              l?.profileSetupHeightConsequence ??
                    'Without it: stride length, and distance from steps.',
            ),
            _Field(
              _weight,
              l?.profileSetupWeightLabel ?? 'WEIGHT',
              uiText(c, _u.isImperial ? 'lb' : 'kg'),
              l?.profileSetupWeightConsequence ??
                    'Without it: calories and training load.',
            ),
            const SizedBox(height: S.x5),
            BigButton(l?.actionContinue ?? 'Continue',
                color: C.green, onTap: _sex == null ? null : _continue),
            if (_sex == null) ...[
              const SizedBox(height: S.x2),
              Text(l?.profileSetupPickOneToContinue ??
                      'Pick one option above to continue.',
                  style: F.cap.copyWith(color: p.ink3)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _Choice({required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: S.tap),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x2),
        decoration: BoxDecoration(
          color: on ? p.wash(C.green) : p.card,
          borderRadius: R.rMd,
          border: Border.all(color: on ? p.on(C.green) : p.line),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: F.cap.copyWith(
                color: on ? p.on(C.green) : p.ink2,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label, unit, consequence;
  const _Field(this.controller, this.label, this.unit, this.consequence);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: F.over.copyWith(color: p.ink3))),
          Text(AppLocalizations.of(c)?.profileSetupOptional ?? 'OPTIONAL',
              style: F.over.copyWith(color: p.ink3)),
        ]),
        const SizedBox(height: S.x1),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          style: F.head.copyWith(color: p.ink),
          decoration: InputDecoration(
            hintText: unit,
            hintStyle: F.head.copyWith(color: p.ink3),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: S.x3),
            enabledBorder:
                UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: p.on(C.green))),
          ),
        ),
        const SizedBox(height: S.x1),
        Text(consequence, style: F.cap.copyWith(color: p.ink3)),
      ]),
    );
  }
}

// No day-0 "unlock contract" card. There was one — locked headline, unlock
// date, nights banked, live HR beside it — and nothing ever built it. Day zero
// is carried by `StatusCard.forMetric`, which already says how many more
// nights the metric needs.

/// "Thu 4 Sep" — a date a person can hold, not an ISO string. Local by
/// construction; the app's day labels are local everywhere.
String formatDay(DateTime d, [AppLocalizations? l]) =>
    l?.localeName.startsWith('ru') == true
    ? localizedDate(d, l!.localeName, pattern: 'EEE d MMM')
    : '${weekdayShortName(d.weekday, l)} ${d.day} ${monthShortName(d.month, l)}';
