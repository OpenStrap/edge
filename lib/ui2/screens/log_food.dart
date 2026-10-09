import '../../l10n/display_text.dart';
// Logging an eating occasion.
//
// The primary unit is the OCCASION, not the food. The big button at the top
// writes a complete, valid entry with no numbers in it at all — a trial
// comparing detailed against simplified logging found 49% of days logged
// versus 97%, with identical six-month weight loss. Macro detail is the tier
// underneath, opened deliberately, and never the path a new user is walked
// down.
//
// There is no photo estimate. The sheet does not say so either — a card
// explaining a feature that does not exist is an advert for it. See
// docs/internal/UI_ROADMAP.md. The store's guard for a future photo path
// (`FoodEntry.sanitised`, which never lets a photo carry a total) stays where
// it is, because it is a data rule rather than a screen.
//
// There IS a barcode scan, and it lives inside "Add the numbers" rather than
// beside the occasion button. A scan is macro detail, and macro detail is the
// tier underneath — a new user is not walked down it.
//
// A SCAN PART-FILLS. That is the normal case, not a failure: only about 12% of
// products carry all seven core fields, and everything Open Food Facts hands
// over goes through `gateNutrients` first, which drops a physically impossible
// value rather than round it into range. Every box the lookup could not stand
// behind is left EMPTY for the user to type. None of it is a measurement —
// see `FoodSource.barcode`.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/db.dart';
import '../../data/day_label.dart';
import '../../data/journal_fields.dart' show formatMinuteOfDay;
import '../../data/nutrition_store.dart';
import '../../data/off_lookup.dart';
import '../../l10n/app_localizations.dart';
import '../profile/profile.dart' show SetRow;
import '../ui2.dart';
import 'journal_compose.dart' show OsTextField;
import 'log_workout.dart' show dayLabel;
import 'scan_barcode.dart';

class LogFoodSheet extends StatefulWidget {
  const LogFoodSheet({super.key, this.date, this.meal = 'snack', this.entry});

  final String? date;
  final String meal;

  /// An existing entry to EDIT instead of logging a new one. Same id on save,
  /// and the sheet can remove it.
  final FoodEntry? entry;

  /// Show as a bottom sheet. Resolves true when something was logged, edited
  /// or removed.
  static Future<bool?> show(
    BuildContext c, {
    String? date,
    String meal = 'snack',
    FoodEntry? entry,
  }) => showModalBottomSheet<bool>(
    context: c,
    isScrollControlled: true,
    sheetAnimationStyle: sheetMotion(c),
    backgroundColor: P.of(c).card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
    ),
    builder: (_) => LogFoodSheet(date: date, meal: meal, entry: entry),
  );

  @override
  State<LogFoodSheet> createState() => _LogFoodSheetState();
}

class _LogFoodSheetState extends State<LogFoodSheet> {
  FoodEntry? get _editing => widget.entry;
  late String _date = _editing?.date ?? widget.date ?? todayLabel();
  late String _meal = _editing?.meal ?? widget.meal;

  /// When it was eaten, on [_date]. Defaults to now so the one-tap path is
  /// unchanged; picking one is how a meal gets logged after the fact. Null
  /// only for an edited entry that never had a time — it stays unrecorded
  /// rather than gaining one nobody chose.
  late TimeOfDay? _time = switch (widget.entry) {
    null => TimeOfDay.now(),
    FoodEntry(atTs: final ts?) =>
      TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ts * 1000)),
    _ => null,
  };

  /// Search over everything ever logged, not just the last five.
  final _query = TextEditingController();
  bool _hasHistory = false;

  final _label = TextEditingController();
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  final _fibre = TextEditingController();

  /// Grams. Only on screen once a scan has landed — the numbers arrive per
  /// 100 g and somebody who ate one 33 g packet should not have to do the
  /// arithmetic themselves.
  final _portion = TextEditingController();

  List<FoodEntry> _recent = const [];
  late bool _detail = _editing != null;

  /// The last scan's product, when it produced one. Holds the per-100 g
  /// figures the portion field rescales from, and its barcode becomes the
  /// entry's `foodKey`.
  OffProduct? _scanned;

  /// What the last lookup did, for the card that says so. Null before the
  /// first scan of this sheet.
  OffOutcome? _outcome;
  bool _looking = false;

  @override
  void initState() {
    super.initState();
    final e = _editing;
    if (e == null) {
      _loadRecent();
      _query.addListener(_loadRecent);
    } else {
      _label.text = e.label;
      _kcal.text = _plain(e.kcal);
      _protein.text = _plain(e.proteinG);
      _carbs.text = _plain(e.carbsG);
      _fat.text = _plain(e.fatG);
      _fibre.text = _plain(e.fibreG);
      _loadScanned(e);
    }
    _portion.addListener(_rescale);
  }

  /// A scanned entry reopens with its product attached, so changing the
  /// portion rescales the numbers the same way it did when it was logged.
  /// The portion is set BEFORE the product, so the listener does not
  /// overwrite numbers the user may have typed over since.
  Future<void> _loadScanned(FoodEntry e) async {
    final key = e.foodKey;
    if (e.source != FoodSource.barcode || key == null) return;
    final row = await NutritionDb.foodDef(await LocalDb.instance, key);
    if (row == null || row['source'] != 'barcode' || !mounted) return;
    setState(() {
      _portion.text = _plain(e.quantity);
      _scanned = OffProduct.fromDefRow(row);
    });
  }

  @override
  void dispose() {
    _portion.removeListener(_rescale);
    for (final t in [
      _query,
      _label,
      _kcal,
      _protein,
      _carbs,
      _fat,
      _fibre,
      _portion,
    ]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final q = _query.text.trim();
    final db = await LocalDb.instance;
    final r = await NutritionDb.recent(db, limit: q.isEmpty ? 5 : 25, query: q);
    // A slower answer to an older query must not replace a newer one.
    if (!mounted || q != _query.text.trim()) return;
    setState(() {
      _recent = r;
      if (r.isNotEmpty) _hasHistory = true;
    });
  }

  /// Set while a write is in flight and kept through the pop that follows:
  /// a second tap before the sheet closes would otherwise insert the same
  /// meal twice under a fresh id.
  bool _writing = false;

  Future<void> _write(FoodEntry e) async {
    if (_writing) return;
    _writing = true;
    try {
      final db = await LocalDb.instance;
      if (_editing != null) {
        await NutritionDb.update(db, e);
      } else {
        await NutritionDb.put(db, e);
      }
    } catch (_) {
      _writing = false;
      rethrow;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Removing is destructive and there is no undo, so the entry is named back
  /// before it goes.
  Future<void> _remove(FoodEntry e) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmRemove(
      context,
      title: l?.nutritionRemoveTitle(e.label) ?? 'Remove ${e.label}?',
      body: l?.nutritionRemoveBody ??
          'It leaves the day and every average that counted it. There is no '
              'undo.',
    );
    if (!ok) return;
    await NutritionDb.delete(await LocalDb.instance, e.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Epoch seconds for [_time] on [_date], or null when no time is set.
  int? get _atTs {
    final t = _time;
    final d = DateTime.tryParse(_date);
    if (t == null || d == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute)
            .millisecondsSinceEpoch ~/
        1000;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_date) ?? now,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked != null && mounted) setState(() => _date = dayLabelOf(picked));
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
    );
    if (picked != null && mounted) setState(() => _time = picked);
  }

  FoodEntry _base({
    required String label,
    FoodSource source = FoodSource.manual,
  }) => FoodEntry(
    id: NutritionDb.newId(),
    date: _date,
    meal: _meal,
    label: label,
    atTs: _atTs,
    source: source,
  );

  /// Blank is unknown, never zero — and a typo is NEITHER. "1,200" or
  /// "850 kcal" used to arrive here as the same null as an empty field and the
  /// meal was written with the energy silently dropped.
  double? _num(TextEditingController t) => Typed.of(t.text).value;

  // ── the barcode path ──────────────────────────────────────────────────────

  /// Scan, then look the code up.
  ///
  /// Lookup is on by default, so this normally goes straight to the camera.
  /// The prompt below is for the person who turned it OFF and then tapped
  /// Scan: refusing silently there reads as a broken scanner. It is asked
  /// BEFORE the camera opens, not after — someone who would decline should not
  /// have pointed their phone at a packet first.
  Future<void> _scan() async {
    if (!offLookupAllowed) {
      final agreed = await _askLookupConsent(context);
      if (agreed != true || !mounted) return;
      // Awaited so the consent is on disk before the camera opens. A write
      // that fails only means being asked again next launch — the direction
      // that cannot hurt anyone.
      await setOffLookupAllowed(true);
      if (!mounted) return;
    }
    final code = await scanBarcode(context);
    if (code == null || !mounted) return;
    setState(() {
      _looking = true;
      _outcome = null;
    });
    final res = await _lookup(code);
    if (!mounted) return;
    setState(() {
      _looking = false;
      _outcome = res.outcome;
      final p = res.product;
      if (p != null) {
        _apply(p);
      } else {
        // A scan that found nothing must not leave the PREVIOUS packet
        // attached. `_scanned` is what writes `foodKey` and stamps
        // `FoodSource.barcode` on the saved row, so keeping it here filed the
        // entry under the wrong barcode AND claimed a barcode provenance for
        // numbers that may have been typed over since. The form drops back to
        // manual, which is what it now is; the boxes keep whatever is in them,
        // because clearing a value the user typed would be its own bug.
        _scanned = null;
      }
    });
  }

  /// Cache first. `food_def` is keyed by barcode, so the second scan of the
  /// same packet is a local read and openfoodfacts.org hears nothing.
  Future<OffResult> _lookup(String code) async {
    final db = await LocalDb.instance;
    final cached = await NutritionDb.foodDef(db, code);
    // Only a row this path wrote. Crediting Open Food Facts for a dictionary
    // entry that came from somewhere else would be an attribution in the
    // wrong direction, which is its own kind of licence problem.
    if (cached != null && cached['source'] == 'barcode') {
      return OffResult(OffOutcome.ok, OffProduct.fromDefRow(cached));
    }
    final res = await fetchOffProduct(code);
    final p = res.product;
    if (p != null) await NutritionDb.putFoodDef(db, p.toDefRow());
    return res;
  }

  /// Fill the form from a product. Every box the gates could not stand behind
  /// is CLEARED rather than left holding the previous scan's number.
  void _apply(OffProduct p) {
    _scanned = p;
    _label.text = _productLabel(p);
    _portion.text = _plain(p.defaultPortionG);
    _fillFrom(p, p.defaultPortionG);
  }

  /// The portion field changed, so the five numbers change with it. Only when
  /// a scan is what put them there — a typed number is the user's and is never
  /// overwritten.
  void _rescale() {
    final p = _scanned;
    final g = Typed.of(_portion.text).value;
    if (p == null || g == null) return;
    _fillFrom(p, g);
  }

  /// What to say about the last lookup, or null when there is nothing to say
  /// — which is the case when it worked.
  ///
  /// Every branch ends in the same place on purpose: type the numbers off the
  /// pack. That is the fallback, it always was, and none of these are errors
  /// the user did anything to cause.
  StatusCard? _lookupProblem(BuildContext c) {
    final o = _outcome;
    if (o == null) return null;
    // A product whose numbers all survived needs no card; the filled boxes
    // are the answer.
    if (o == OffOutcome.ok && _scanned?.isBare != true) return null;
    final l = AppLocalizations.of(c);
    return switch (o) {
      OffOutcome.ok => StatusCard(
          l?.logFoodNoNumbersTitle ?? 'No numbers for this one',
          l?.logFoodNoNumbersBody ??
              'Open Food Facts has the product but nothing usable on its '
                  'nutrition — or what it had did not survive a sanity check.',
          icon: LucideIcons.scanBarcode,
        ),
      OffOutcome.notFound => StatusCard(
          l?.logFoodNotFoundTitle ?? 'Not in Open Food Facts',
          l?.logFoodNotFoundBody ?? 'Nobody has added this barcode yet.',
          icon: LucideIcons.scanBarcode,
        ),
      OffOutcome.flagged => StatusCard(
          l?.logFoodFlaggedTitle ?? 'This record is flagged as wrong',
          l?.logFoodFlaggedBody ??
              'Open Food Facts marks this product as containing errors, so none '
                  'of its numbers were filled in.',
          icon: LucideIcons.triangleAlert,
        ),
      OffOutcome.unreachable => StatusCard(
          l?.logFoodUnreachableTitle ?? 'No answer from Open Food Facts',
          l?.logFoodUnreachableBody ??
              'The lookup could not reach openfoodfacts.org.',
          icon: LucideIcons.cloudOff,
        ),
      OffOutcome.refused => StatusCard(
          l?.logFoodRefusedTitle ?? 'Barcode lookup is off',
          l?.logFoodRefusedBody ??
              'Nothing was sent. You can turn it on in Settings › Privacy.',
          icon: LucideIcons.scanBarcode,
        ),
    };
  }

  /// What basis the boxes are on. The pack's own serving is named when the
  /// record states one, because "33 g" beside a 400 g jar is the difference
  /// between a spoonful and a fortnight.
  String _portionNote(BuildContext c, OffProduct p) {
    final l = AppLocalizations.of(c);
    final base = l?.logFoodPortionNoteBase ??
        'Open Food Facts lists this per 100 g. Change the portion and '
            'the numbers follow.';
    if (p.servingLabel.isEmpty && p.servingG == null) return base;
    final serving =
        p.servingLabel.isNotEmpty ? p.servingLabel : '${_plain(p.servingG)} g';
    return l?.logFoodPortionNoteServing(serving) ?? '$base The pack’s own serving is $serving.';
  }

  void _fillFrom(OffProduct p, double grams) {
    final v = p.forPortion(grams);
    _kcal.text = _plain(v.kcal);
    _protein.text = _plain(v.proteinG);
    _carbs.text = _plain(v.carbsG);
    _fat.text = _plain(v.fatG);
    _fibre.text = _plain(v.fibreG);
  }

  /// The number fields that were typed into and cannot be read.
  List<String> _unreadable(BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
      for (final (name, ctl) in [
        (l?.logFoodEnergyLabel ?? 'Energy', _kcal),
        (l?.logFoodProteinLabel ?? 'Protein', _protein),
        (l?.logFoodCarbsLabel ?? 'Carbs', _carbs),
        (l?.logFoodFatLabel ?? 'Fat', _fat),
        (l?.logFoodFibreLabel ?? 'Fibre', _fibre),
        if (_scanned != null) (l?.logFoodPortionLabel ?? 'Portion', _portion),
      ])
        if (Typed.of(ctl.text).bad) name,
    ];
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(S.x5, S.x4, S.x5, S.x6),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                      _editing != null
                          ? (l?.logFoodEditTitle ?? 'Edit this entry')
                          : (l?.logFoodTitle ?? 'Log an eating occasion'),
                      style: F.t2.copyWith(color: p.ink)),
                ),
                Pressable(
                  semanticLabel: l?.logFoodClose ?? 'Close',
                  onTap: () => Navigator.of(c).pop(),
                  child: Icon(LucideIcons.x, size: 20, color: p.ink3),
                ),
              ],
            ),
            const SizedBox(height: S.x4),
            Row(
              children: [
                for (final m in kMeals) ...[
                  Expanded(
                    child: Pressable(
                      onTap: () => setState(() => _meal = m),
                      semanticLabel: _mealLabel(c, m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: S.x3),
                        decoration: BoxDecoration(
                          color: m == _meal ? p.fill(C.domFood) : p.card2,
                          borderRadius: R.rSm,
                        ),
                        child: Center(
                          child: Text(
                            _mealLabel(c, m),
                            style: F.cap.copyWith(
                              color: m == _meal ? p.inkOnFill : p.ink2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (m != kMeals.last) const SizedBox(width: S.x2),
                ],
              ],
            ),
            const SizedBox(height: S.x3),
            Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Column(
                children: [
                  SetRow(LucideIcons.calendar, C.domFood,
                      l?.logFoodDateLabel ?? 'Date',
                      value: dayLabel(DateTime.tryParse(_date) ?? DateTime.now(),
                          l: l),
                      onTap: _pickDate),
                  SetRow(LucideIcons.clock, C.domFood,
                      l?.logFoodTimeLabel ?? 'Time',
                      value: _time == null
                          ? (l?.nutritionNotRecorded ?? 'Not recorded')
                          : formatMinuteOfDay(_time!.hour * 60 + _time!.minute),
                      onTap: _pickTime),
                ],
              ),
            ),
            if (_editing == null) ...[
            const SizedBox(height: S.x5),
            BigButton(
              l?.logFoodIAte(_mealLabel(c, _meal)) ??
                  'I ate ${_mealLabel(c, _meal).toLowerCase()}',
              icon: LucideIcons.check,
              color: C.domFood,
              onTap: () => _write(_base(label: _mealLabel(c, _meal))),
            ),
            if (_hasHistory)
              Section(
                l?.logFoodAgain ?? 'Again',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OsTextField(
                      controller: _query,
                      label: l?.logFoodSearchLabel ?? 'Search your foods',
                      hint: l?.logFoodSearchHint ?? 'Anything you have logged',
                    ),
                    const SizedBox(height: S.x3),
                    if (_recent.isEmpty)
                      Text(
                        l?.logFoodSearchNoMatch ??
                            'Nothing you have logged matches that.',
                        style: F.cap.copyWith(color: p.ink3),
                      )
                    else
                Surface(
                  pad: const EdgeInsets.symmetric(horizontal: S.x4),
                  child: Column(
                    children: [
                      for (final r in _recent)
                        FoodRow(
                          entry: r,
                          trailing: LucideIcons.circlePlus,
                          onTap: () => _write(
                            FoodEntry(
                              id: NutritionDb.newId(),
                              date: _date,
                              meal: _meal,
                              label: r.label,
                              atTs: _atTs,
                              foodKey: r.foodKey,
                              quantity: r.quantity,
                              unit: r.unit,
                              kcal: r.kcal,
                              proteinG: r.proteinG,
                              carbsG: r.carbsG,
                              fatG: r.fatG,
                              fibreG: r.fibreG,
                              source: FoodSource.repeat,
                              confirmed: r.confirmed,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                  ],
                ),
              ),
            const SizedBox(height: S.x5),
            Pressable(
              onTap: () => setState(() => _detail = !_detail),
              child: Row(
                children: [
                  Icon(
                    _detail ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 18,
                    color: p.ink3,
                  ),
                  const SizedBox(width: S.x2),
                  Expanded(
                    child: Text(
                      l?.logFoodAddNumbers ?? 'Add the numbers',
                      style: F.body.copyWith(color: p.ink2),
                    ),
                  ),
                ],
              ),
            ),
            ],
            if (_detail) ...[
              if (_editing == null) ...[
              const SizedBox(height: S.x3),
              Surface(
                pad: const EdgeInsets.symmetric(horizontal: S.x4),
                child: SetRow(
                  LucideIcons.scanBarcode,
                  C.domFood,
                  l?.logFoodScanBarcode ?? 'Scan a barcode',
                  sub: offLookupAllowed
                      ? (l?.logFoodScanSubOn ??
                          'Asks openfoodfacts.org about the barcode, and fills '
                              'in what it can stand behind')
                      : (l?.logFoodScanSubOff ?? 'Looks the pack up online. Asks first'),
                  chevron: false,
                  onTap: _looking ? null : _scan,
                ),
              ),
              ],
              if (_looking) ...[
                const SizedBox(height: S.x3),
                StatusCard(
                  l?.logFoodLookingUpTitle ?? 'Looking it up',
                  l?.logFoodLookingUpBody ??
                      'The boxes fill as soon as the answer is here.',
                  icon: LucideIcons.scanBarcode,
                ),
              ] else if (_lookupProblem(c) != null) ...[
                const SizedBox(height: S.x3),
                _lookupProblem(c)!,
              ],
              const SizedBox(height: S.x4),
              OsTextField(
                controller: _label,
                label: l?.logFoodWhatLabel ?? 'What',
                hint: l?.logFoodWhatHint ?? 'Chicken and rice',
              ),
              if (_scanned != null) ...[
                const SizedBox(height: S.x4),
                _NumberRow(
                  fields: [(l?.logFoodPortionLabel ?? 'Portion', 'g', _portion)],
                  hint: '100',
                ),
                const SizedBox(height: S.x2),
                Text(
                  _portionNote(c, _scanned!),
                  style: F.cap.copyWith(color: p.ink3, height: 1.45),
                ),
              ],
              const SizedBox(height: S.x4),
              _NumberRow(
                fields: [
                  (l?.logFoodEnergyLabel ?? 'Energy', 'kcal', _kcal),
                  (l?.logFoodProteinLabel ?? 'Protein', 'g', _protein),
                ],
                hint: l?.logFoodUnknownHint ?? 'unknown',
              ),
              const SizedBox(height: S.x4),
              _NumberRow(
                fields: [
                  (l?.logFoodCarbsLabel ?? 'Carbs', 'g', _carbs),
                  (l?.logFoodFatLabel ?? 'Fat', 'g', _fat),
                ],
                hint: l?.logFoodUnknownHint ?? 'unknown',
              ),
              const SizedBox(height: S.x4),
              // The week card has always averaged fibre; nothing could enter
              // it, so the row read "Not recorded" forever.
              _NumberRow(
                fields: [(l?.logFoodFibreLabel ?? 'Fibre', 'g', _fibre)],
                hint: l?.logFoodUnknownHint ?? 'unknown',
              ),
              const SizedBox(height: S.x3),
              Text(
                l?.logFoodBlankHint ??
                    'A blank number stays blank. Only "What" is needed.',
                style: F.cap.copyWith(color: p.ink3, height: 1.45),
              ),
              // ODbL asks for attribution "reasonably calculated" to make a
              // viewer aware. It goes HERE, on the screen where the numbers
              // are, and not only in the licences page.
              if (_scanned != null) ...[
                const SizedBox(height: S.x3),
                const _OffCredit(),
              ],
              const SizedBox(height: S.x4),
              BigButton(
                l?.actionSave ?? 'Save',
                color: C.domFood,
                soft: true,
                onTap: () {
                  final label = _label.text.trim();
                  // Both used to be a bare return under an enabled-looking
                  // button: nothing happened, nothing was said, and the typed
                  // numbers were thrown away by the only control that reacted.
                  if (label.isEmpty) {
                    ScaffoldMessenger.of(c).showSnackBar(SnackBar(
                      content: Text(
                          l?.logFoodSayWhatFirst ?? 'Say what it was first.'),
                    ));
                    return;
                  }
                  final bad = _unreadable(c);
                  if (bad.isNotEmpty) {
                    sayUnreadable(c, bad);
                    return;
                  }
                  final b = _base(label: label);
                  final scan = _scanned;
                  // An edit keeps its id and everything this form does not
                  // show — the nutrients only the coach writes, the note —
                  // rather than dropping them as a side effect.
                  final o = _editing;
                  _write(
                    FoodEntry(
                      id: o?.id ?? b.id,
                      date: b.date,
                      meal: b.meal,
                      label: label,
                      atTs: b.atTs,
                      // The barcode, so a repeat of this food is a local
                      // read — and so the row can say where its numbers came
                      // from. NOT `verified`: see FoodSource.barcode.
                      foodKey: scan?.barcode ?? o?.foodKey,
                      quantity: scan == null ? o?.quantity : _num(_portion),
                      unit: scan == null ? (o?.unit ?? 'g') : 'g',
                      sugarG: o?.sugarG,
                      satFatG: o?.satFatG,
                      sodiumMg: o?.sodiumMg,
                      ironMg: o?.ironMg,
                      calciumMg: o?.calciumMg,
                      note: o?.note ?? '',
                      source: scan == null
                          ? FoodSource.manual
                          : FoodSource.barcode,
                      kcal: _num(_kcal),
                      proteinG: _num(_protein),
                      carbsG: _num(_carbs),
                      fatG: _num(_fat),
                      fibreG: _num(_fibre),
                      confirmed: true,
                    ),
                  );
                },
              ),
              if (_editing != null) ...[
                const SizedBox(height: S.x3),
                BigButton(
                  l?.logFoodRemoveEntry ?? 'Remove this entry',
                  icon: LucideIcons.trash2,
                  color: C.red,
                  soft: true,
                  onTap: () => _remove(_editing!),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// A number in a text box. Trailing zeros trimmed, because "33" is what the
/// pack says and "33.0" is what a float says.
String _plain(double? v) {
  if (v == null) return '';
  final r = (v * 10).round() / 10;
  return r == r.roundToDouble()
      ? r.round().toString()
      : r.toStringAsFixed(1);
}

/// Brand in front of the product name, unless the name already carries it —
/// "Parle Parle-G" is how that goes wrong.
String _productLabel(OffProduct p) {
  final name = p.label;
  if (p.brand.isEmpty) return name;
  return name.toLowerCase().contains(p.brand.toLowerCase())
      ? name
      : '${p.brand} $name';
}

/// The disclosure, before the first lookup ever happens.
///
/// Asked once, then remembered; revocable from Settings › Privacy. It states
/// what leaves the phone — the barcode, and nothing else — because this app's
/// whole claim is that nothing does unless you said so.
Future<bool?> _askLookupConsent(BuildContext c) => showModalBottomSheet<bool>(
      context: c,
      sheetAnimationStyle: sheetMotion(c),
      backgroundColor: P.of(c).card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
      ),
      builder: (s) {
        final p = P.of(s);
        final l = AppLocalizations.of(s);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(S.x5, S.x5, S.x5, S.x6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l?.logFoodConsentTitle ?? 'Look barcodes up online?',
                    style: F.t2.copyWith(color: p.ink)),
                const SizedBox(height: S.x4),
                Text(
                  l?.logFoodConsentBody1 ??
                      'A scan sends the barcode to openfoodfacts.org, a free, '
                          'open food database. They see the barcode and your IP '
                          'address. Nothing about you, your meals or your health '
                          'leaves this phone, and a barcode you have scanned before '
                          'is answered from your own copy without asking them again.',
                  style: F.body.copyWith(color: p.ink2, height: 1.5),
                ),
                const SizedBox(height: S.x3),
                Text(
                  l?.logFoodConsentBody2 ??
                      'Their numbers are typed in by the public and a fair few of '
                          'them are wrong, so anything that fails a sanity check is '
                          'left blank rather than filled in. Everything it does fill '
                          'in is yours to edit before you save.',
                  style: F.body.copyWith(color: p.ink2, height: 1.5),
                ),
                const SizedBox(height: S.x3),
                Text(
                  l?.logFoodConsentBody3 ??
                      'You can turn this back off in Settings › Privacy. Typing '
                          'the numbers off the pack works either way.',
                  style: F.cap.copyWith(color: p.ink3, height: 1.45),
                ),
                const SizedBox(height: S.x5),
                BigButton(l?.logFoodAllowLookups ?? 'Allow lookups',
                    color: C.domFood, onTap: () => Navigator.of(s).pop(true)),
                const SizedBox(height: S.x3),
                BigButton(l?.logFoodNotNow ?? 'Not now',
                    color: C.domFood,
                    soft: true,
                    onTap: () => Navigator.of(s).pop(false)),
              ],
            ),
          ),
        );
      },
    );

/// The ODbL credit, wherever Open Food Facts numbers are shown. Both links
/// are the licence's, not decoration — the notice names the source and the
/// terms, and a user has to be able to reach both.
class _OffCredit extends StatelessWidget {
  const _OffCredit();

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kOffAttribution,
            style: F.cap.copyWith(color: p.ink3, height: 1.45)),
        const SizedBox(height: S.x1),
        // Wrap, not Row: "Open Database License" beside a URL runs off the
        // right of the sheet at accessibility text sizes, and a link that has
        // overflowed is a link nobody can follow.
        const Wrap(
          spacing: S.x3,
          runSpacing: S.x1,
          children: [
            _Link('openfoodfacts.org', kOffSite),
            _Link('Open Database License', kOffLicence),
          ],
        ),
      ],
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.label, this.url);
  final String label, url;

  @override
  Widget build(BuildContext c) => Pressable(
        semanticLabel: AppLocalizations.of(c)?.logFoodOpensInBrowser(label) ??
            '$label, opens in your browser',
        onTap: () => launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication),
        child: Text(
          label,
          style: F.cap.copyWith(
            color: P.of(c).on(C.domFood),
            decoration: TextDecoration.underline,
          ),
        ),
      );
}

String _mealLabel(BuildContext c, String m) {
  final l = AppLocalizations.of(c);
  return switch (m) {
    'breakfast' => l?.logFoodBreakfast ?? 'Breakfast',
    'lunch' => l?.logFoodLunch ?? 'Lunch',
    'dinner' => l?.logFoodDinner ?? 'Dinner',
    _ => l?.logFoodSnack ?? 'Snack',
  };
}

/// One logged entry. The provenance line is not decoration: a manufacturer
/// panel and a typed guess are different claims, and the row says which it is.
class FoodRow extends StatelessWidget {
  const FoodRow({
    super.key,
    required this.entry,
    this.trailing,
    this.onTap,
  });

  final FoodEntry entry;
  final IconData? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final stacked = bigText(c);
    final badge = Pill(
              entry.source == FoodSource.barcode
                  ? (l?.logFoodPillOpenFoodFacts ?? 'Open Food Facts')
                  : (l?.logFoodPillYours ?? 'Yours'),
      C.n400,
      wrap: stacked,
    );
    return Pressable(
      onTap: onTap,
      semanticLabel: '${entry.label}. ${_detail(c, entry)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: p.card2, borderRadius: R.rSm),
              child: Icon(LucideIcons.utensils, size: 16, color: p.ink3),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.label, style: F.body.copyWith(color: p.ink)),
                  Text(
                    _detail(c, entry),
                    style: F.over.copyWith(color: p.ink3),
                  ),
                  if (stacked) ...[const SizedBox(height: S.x1), badge],
                ],
              ),
            ),
            // "Verified" is still unreachable — there is no manufacturer feed
            // and a crowd-sourced record is not one. A barcode row says so by
            // name, which is also the ODbL credit at the point of display;
            // everything else here is the user's own.
            if (!stacked) ...[const SizedBox(width: S.x2), badge],
            if (trailing != null) ...[
              const SizedBox(width: S.x2),
              Icon(trailing, size: 20, color: p.on(C.domFood)),
            ],
          ],
        ),
      ),
    );
  }

  static String _detail(BuildContext c, FoodEntry e) {
    // No photo pipeline exists, so `FoodSource.photo` is never written and the
    // branch that read it could never run.
    if (e.isBareOccasion) {
      return AppLocalizations.of(c)?.logFoodBareOccasion ??
          'LOGGED · ENERGY NOT RECORDED';
    }
    final parts = <String>['${e.kcal!.round()} ${uiText(c, 'kcal')}'];
    if (e.proteinG != null) {
      parts.add(
        '${e.proteinG!.round()}${AppLocalizations.of(c)?.supplementProteinShort ?? 'P'}',
      );
    }
    if (e.carbsG != null) {
      parts.add(
        '${e.carbsG!.round()}${AppLocalizations.of(c)?.supplementCarbsShort ?? 'C'}',
      );
    }
    if (e.fatG != null) {
      parts.add(
        '${e.fatG!.round()}${AppLocalizations.of(c)?.supplementFatShort ?? 'F'}',
      );
    }
    return parts.join(' · ');
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({required this.fields, this.hint = 'unknown'});
  final List<(String, String, TextEditingController)> fields;
  final String hint;

  @override
  Widget build(BuildContext c) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < fields.length; i++) ...[
        Expanded(
          child: OsTextField(
            controller: fields[i].$3,
            label: '${fields[i].$1} (${uiText(c, fields[i].$2)})',
            hint: uiText(c, hint),
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
        ),
        if (i < fields.length - 1) const SizedBox(width: S.x3),
      ],
    ],
  );
}
