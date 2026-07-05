// Onboarding profile step — collects age / weight / height / sex so the
// on-device analytics can personalize (HRmax via Tanaka 208−0.7·age, Keytel
// calories, Banister TRIMP sex constant, fitness-age). Shown once, between
// pairing and the shell, only while the profile is incomplete.
//
// Persisted via AppState.updateProfile (shared_preferences) — the same local
// map the DerivationEngine reads as a Profile. A field left blank simply means
// the dependent metric stays absent (honesty: never a fabricated default).
//
// Presentation: design-system language. The pure [ProfileSetupForm] holds the
// form (fields, sex chips, consents, validation) and reports one onSubmit —
// render-testable without providers; the screen wires it to AppState.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'design/design.dart';

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});
  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  Map<String, dynamic> _initial = const {};
  // Companion consents — PRE-ENABLED at first enrollment (the user can switch
  // either off here). Recorded + sent on Continue. When re-editing an existing
  // profile we reflect the saved choice instead.
  bool _telemetry = true;
  bool _healthShare = true;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _initial = app.user ?? const {};
    // Fresh enrollment → keep the pre-enabled defaults above. Returning user
    // editing their profile → reflect whatever they previously chose.
    if (app.consentChosen) {
      _telemetry = app.telemetryConsent;
      _healthShare = app.healthShareConsent;
    }
  }

  Future<void> _submit(
      Map<String, dynamic> profile, bool telemetry, bool healthShare) async {
    final app = context.read<AppState>();
    // Record the consent choices (persist + server consent ledger) first.
    await app.setTelemetryConsent(telemetry);
    await app.setHealthShareConsent(healthShare);
    await app.updateProfile(profile);
    // AppState.route now returns shell — the _Gate rebuilds automatically.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ProfileSetupForm(
          initial: _initial,
          telemetryInitial: _telemetry,
          healthShareInitial: _healthShare,
          onSubmit: _submit,
        ),
      ),
    );
  }
}

/// Pure profile-setup form on the design language. Owns its controllers and
/// validation; reports the parsed profile + consent choices through [onSubmit].
class ProfileSetupForm extends StatefulWidget {
  final Map<String, dynamic> initial;
  final bool telemetryInitial;
  final bool healthShareInitial;
  final Future<void> Function(
      Map<String, dynamic> profile, bool telemetry, bool healthShare) onSubmit;

  const ProfileSetupForm({
    super.key,
    this.initial = const {},
    this.telemetryInitial = true,
    this.healthShareInitial = true,
    required this.onSubmit,
  });

  @override
  State<ProfileSetupForm> createState() => _ProfileSetupFormState();
}

class _ProfileSetupFormState extends State<ProfileSetupForm> {
  final _age = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  String? _sex; // 'm' | 'f'
  late bool _telemetry = widget.telemetryInitial;
  late bool _healthShare = widget.healthShareInitial;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final u = widget.initial;
    if (u['age'] != null) _age.text = '${u['age']}';
    if (u['weight_kg'] != null) _weight.text = '${u['weight_kg']}';
    if (u['height_cm'] != null) _height.text = '${u['height_cm']}';
    _sex = (u['sex'] as String?)?.toLowerCase();
  }

  @override
  void dispose() {
    _age.dispose();
    _weight.dispose();
    _height.dispose();
    super.dispose();
  }

  bool get _valid {
    final a = int.tryParse(_age.text.trim());
    final w = double.tryParse(_weight.text.trim());
    final h = double.tryParse(_height.text.trim());
    return _sex != null &&
        a != null && a > 0 && a < 120 &&
        w != null && w > 0 && w < 400 &&
        h != null && h > 0 && h < 260;
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSubmit(
        {
          'age': int.parse(_age.text.trim()),
          'weight_kg': double.parse(_weight.text.trim()),
          'height_cm': double.parse(_height.text.trim()),
          'sex': _sex,
        },
        _telemetry,
        _healthShare,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x8, Sp.screen, Sp.x8),
      physics: const BouncingScrollPhysics(),
      children: dsStaggered([
        Text('About you', style: AppText.display),
        const SizedBox(height: Sp.x3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'Four numbers personalize your heart-rate ceiling, calories '
                'and training load.',
                style: AppText.bodySoft,
              ),
            ),
            const InfoDot(
              title: 'Why we ask',
              body:
                  'Everything is computed on your phone. These numbers tune the '
                  'published formulas we use — HRmax (Tanaka), calories (Keytel) '
                  'and training load (Banister).',
              bullets: [
                'Leave a field blank and only that metric stays unknown — '
                    'never guessed.',
                'Change any of these later in Profile.',
              ],
            ),
          ],
        ),
        const SizedBox(height: Sp.x6),
        _label('Sex'),
        const SizedBox(height: Sp.x2),
        Row(children: [
          Expanded(child: _sexChip('Male', 'm')),
          const SizedBox(width: Sp.x3),
          Expanded(child: _sexChip('Female', 'f')),
        ]),
        const SizedBox(height: Sp.x5),
        _field(_age, 'Age', 'years', TextInputType.number),
        const SizedBox(height: Sp.x4),
        _field(_weight, 'Weight', 'kg',
            const TextInputType.numberWithOptions(decimal: true)),
        const SizedBox(height: Sp.x4),
        _field(_height, 'Height', 'cm',
            const TextInputType.numberWithOptions(decimal: true)),
        const SizedBox(height: Sp.x7),

        // ── Privacy / consent (pre-enabled here; user can switch off) ────
        _label('Help improve OpenStrap'),
        const SizedBox(height: Sp.x3),
        ConsentTile(
          title: 'Send anonymous diagnostics',
          subtitle: 'Crash reports and basic device info. No health data.',
          value: _telemetry,
          onChanged: (v) => setState(() => _telemetry = v),
        ),
        const SizedBox(height: Sp.x3),
        ConsentTile(
          title: 'Contribute my health data',
          subtitle:
              'Uploads your on-device database over Wi-Fi while charging, to '
              'improve the algorithms.',
          value: _healthShare,
          onChanged: (v) => setState(() => _healthShare = v),
        ),
        const SizedBox(height: Sp.x2),
        Text(
          'Switch either off here or anytime in Settings.',
          style: AppText.caption.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: Sp.x7),

        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _valid && !_saving ? _save : null,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Continue'),
          ),
        ),
      ]),
    );
  }

  Widget _label(String t) => Text(t.toUpperCase(),
      style: AppText.overline.copyWith(color: AppColors.inkMuted));

  Widget _sexChip(String label, String value) {
    final sel = _sex == value;
    return Pressable(
      pressedScale: 0.97,
      borderRadius: BorderRadius.circular(R.pill),
      onTap: () => setState(() => _sex = value),
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? AppColors.accentSoft : Elevation.surfaceAt(1),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: sel
                ? AppColors.accent.withValues(alpha: 0.55)
                : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: AppText.title.copyWith(
            color: sel ? AppColors.onAccentSoft : AppColors.inkSoft,
          ),
        ),
      ),
    );
  }

  Widget _field(
      TextEditingController c, String label, String unit, TextInputType kb) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        const SizedBox(height: Sp.x2),
        TextField(
          controller: c,
          keyboardType: kb,
          onChanged: (_) => setState(() {}),
          style: AppText.metricSm.copyWith(fontSize: 20),
          decoration: InputDecoration(
            suffixText: unit,
            filled: true,
            fillColor: Elevation.surfaceAt(1),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(R.cardSm),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x4),
          ),
        ),
      ],
    );
  }
}

/// One consent row — SurfaceCard + title/one-liner + Switch. Pure.
class ConsentTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const ConsentTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.title),
                const SizedBox(height: Sp.x1),
                Text(subtitle, style: AppText.captionMuted),
              ],
            ),
          ),
          const SizedBox(width: Sp.x3),
          Switch(
            value: value,
            activeThumbColor: AppColors.accent,
            onChanged: (v) {
              HapticFeedback.selectionClick();
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
