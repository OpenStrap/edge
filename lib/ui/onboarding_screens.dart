// Onboarding — backend choice, sign-in (OTP), and profile setup.
// Used by app.dart's gate (do not rename): BackendChoiceScreen, AuthScreen,
// ProfileSetupScreen.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/api_client.dart';
import '../state/app_state.dart';
import '../sync/config.dart';
import '../theme/theme.dart';
import '../theme/theme_switcher.dart';
import '../theme/tokens.dart';
import 'kit/kit.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────────

/// A round coral-tinted icon badge used as a screen "crest".
class _Crest extends StatelessWidget {
  final IconData icon;
  const _Crest(this.icon);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(Sp.x4),
        decoration: BoxDecoration(
          color: AppColors.coralSoft,
          borderRadius: BorderRadius.circular(R.cardSm),
        ),
        child: AppIcon(icon, size: 28, color: AppColors.coralDeep),
      );
}

/// Inline error line in the coral/bad style.
class _ErrorLine extends StatelessWidget {
  final String message;
  const _ErrorLine(this.message);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Sp.x4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(Ic.info, size: 18, color: AppColors.bad),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(message,
                  style: AppText.caption.copyWith(color: AppColors.bad)),
            ),
          ],
        ),
      );
}

Widget _spinner() => const SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
    );

// ─────────────────────────────────────────────────────────────────────────────
// 1) Backend choice — "the catch"
// ─────────────────────────────────────────────────────────────────────────────

class BackendChoiceScreen extends StatefulWidget {
  const BackendChoiceScreen({super.key});
  @override
  State<BackendChoiceScreen> createState() => _BackendChoiceScreenState();
}

class _BackendChoiceScreenState extends State<BackendChoiceScreen> {
  final _url = TextEditingController(text: BackendConfig.defaultUrl);
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    setState(() => _busy = true);
    try {
      await context.read<AppState>().chooseBackend(_url.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Sp.screen, Sp.x8, Sp.screen, Sp.x6),
          children: [
            const _Crest(Ic.server),
            const SizedBox(height: Sp.x6),
            Text('Your data, your\nbackend.', style: AppText.display),
            const SizedBox(height: Sp.x4),
            Text(
              'OpenStrap is self-hosted by design. It talks only to a backend '
              'you control — the default OpenStrap instance, or your own that '
              'you point it at below.',
              style: AppText.bodySoft,
            ),
            const SizedBox(height: Sp.x6),

            // The catch — prominent, unmissable.
            GlowCard(
              glowAlign: const Alignment(1.1, -1.1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    AppIcon(Ic.shield, size: 22, color: AppColors.coralDeep),
                    const SizedBox(width: Sp.x2),
                    Text('Choose carefully', style: AppText.h2),
                  ]),
                  const SizedBox(height: Sp.x3),
                  Text(
                    'Once you pick a backend and start syncing, your data '
                    'CANNOT be migrated to a different backend later. There is '
                    'no transfer path — what lands here, stays here.',
                    style: AppText.body,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),

            Text('BACKEND URL', style: AppText.overline),
            const SizedBox(height: Sp.x3),
            ProCard(
              padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x4, vertical: Sp.x1),
              child: Row(children: [
                AppIcon(Ic.cloud, size: 20, color: AppColors.inkSoft),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    style: AppText.body,
                    decoration: const InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: Sp.x4),
                      hintText: 'https://your-worker.workers.dev',
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              'Leave the default to use the hosted OpenStrap backend. To run '
              'your own, deploy the Cloudflare Worker (see the self-host guide) '
              'and paste its URL.',
              style: AppText.caption,
            ),
            const SizedBox(height: Sp.x7),

            FilledButton(
              onPressed: _busy ? null : _continue,
              child: _busy
                  ? _spinner()
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Text('Continue'),
                        SizedBox(width: Sp.x2),
                        AppIcon(Ic.arrowRight, size: 20, color: Colors.white),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2) Auth — email + name → request OTP → verify
// ─────────────────────────────────────────────────────────────────────────────

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _register = false;
  final _email = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    final email = _email.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Register sends only name+email here; age/height/weight are collected
      // AFTER otp verification (so we have a JWT to PATCH /profile with).
      Map<String, dynamic> resp;
      if (_register) {
        resp = await app.api!.register(
          email: email,
          name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        );
      } else {
        resp = await app.api!.requestOtp(email);
      }
      if (!mounted) return;
      Navigator.of(context).push(themedRoute((_) =>
            OtpScreen(email: email, devCode: resp['dev_code'] as String?),
      ));
    } on ApiException catch (e) {
      setState(() => _error = e.body);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Sp.screen, Sp.x8, Sp.screen, Sp.x6),
          children: [
            const _Crest(Ic.mail),
            const SizedBox(height: Sp.x6),
            Text(_register ? 'Create your\naccount.' : 'Welcome\nback.',
                style: AppText.display),
            const SizedBox(height: Sp.x4),
            Text(
              _register
                  ? 'We\'ll email you a 6-digit code to confirm it\'s you. '
                      'No passwords.'
                  : 'Enter your email and we\'ll send a 6-digit sign-in code.',
              style: AppText.bodySoft,
            ),
            const SizedBox(height: Sp.x7),

            Text('EMAIL', style: AppText.overline),
            const SizedBox(height: Sp.x3),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              style: AppText.body,
              decoration: const InputDecoration(hintText: 'you@example.com'),
            ),

            if (_register) ...[
              const SizedBox(height: Sp.x5),
              Text('NAME', style: AppText.overline),
              const SizedBox(height: Sp.x3),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                style: AppText.body,
                decoration: const InputDecoration(hintText: 'Your name'),
              ),
            ],

            if (_error != null) _ErrorLine(_error!),
            const SizedBox(height: Sp.x7),

            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? _spinner()
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Text('Send code'),
                        SizedBox(width: Sp.x2),
                        AppIcon(Ic.arrowRight, size: 20, color: Colors.white),
                      ],
                    ),
            ),
            const SizedBox(height: Sp.x3),
            Center(
              child: TextButton(
                onPressed:
                    _busy ? null : () => setState(() => _register = !_register),
                child: Text(_register
                    ? 'Have an account? Sign in'
                    : 'New here? Create an account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OtpScreen extends StatefulWidget {
  final String email;
  final String? devCode;
  const OtpScreen({super.key, required this.email, this.devCode});
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.devCode != null) _code.text = widget.devCode!;
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.verifyOtp(widget.email, _code.text.trim());
      // Session is now valid → the root gate rebuilds to profile/pairing/main.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      setState(() => _error = e.body);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      final r = await context.read<AppState>().api!.requestOtp(widget.email);
      if (r['dev_code'] != null) _code.text = r['dev_code'] as String;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Code resent')));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const AppIcon(Ic.arrowLeft, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Sp.screen, Sp.x4, Sp.screen, Sp.x6),
          children: [
            const _Crest(Ic.shield),
            const SizedBox(height: Sp.x6),
            Text('Enter your\ncode.', style: AppText.display),
            const SizedBox(height: Sp.x4),
            Text('We sent a 6-digit code to ${widget.email}.',
                style: AppText.bodySoft),
            if (widget.devCode != null) ...[
              const SizedBox(height: Sp.x3),
              Row(children: [
                Tag('dev', color: AppColors.coral),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: Text('Code prefilled — no email key configured.',
                      style:
                          AppText.caption.copyWith(color: AppColors.coralDeep)),
                ),
              ]),
            ],
            const SizedBox(height: Sp.x7),

            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: AppText.display.copyWith(letterSpacing: 12),
              decoration: const InputDecoration(counterText: ''),
            ),

            if (_error != null) _ErrorLine(_error!),
            const SizedBox(height: Sp.x6),

            FilledButton(
              onPressed: _busy ? null : _verify,
              child: _busy
                  ? _spinner()
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Text('Verify'),
                        SizedBox(width: Sp.x2),
                        AppIcon(Ic.check, size: 20, color: Colors.white),
                      ],
                    ),
            ),
            const SizedBox(height: Sp.x2),
            Center(
              child: TextButton(
                onPressed: _busy ? null : _resend,
                child: const Text('Resend code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3) Profile setup — name (if missing) + sex + age/height/weight
// ─────────────────────────────────────────────────────────────────────────────

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});
  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _name = TextEditingController();
  int? _sexIndex; // 0 = male, 1 = female
  int _age = 30;
  int _heightCm = 175;
  int _weightKg = 70;
  bool _busy = false;
  String? _error;
  bool _loaded = false;

  void _hydrate(AppState app) {
    if (_loaded) return;
    final u = app.user ?? {};
    _name.text = (u['name'] ?? '').toString();
    final sex = (u['sex'] ?? '').toString().toLowerCase();
    if (sex == 'm') _sexIndex = 0;
    if (sex == 'f') _sexIndex = 1;
    if (u['age'] != null) _age = (u['age'] as num).round();
    if (u['height_cm'] != null) _heightCm = (u['height_cm'] as num).round();
    if (u['weight_kg'] != null) _weightKg = (u['weight_kg'] as num).round();
    _loaded = true;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Please tell us your name.');
      return;
    }
    if (_sexIndex == null) {
      setState(() => _error = 'Please select your sex — it tunes your metrics.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.updateProfile({
        'name': _name.text.trim(),
        'sex': _sexIndex == 0 ? 'm' : 'f',
        'age': _age,
        'height_cm': _heightCm.toDouble(),
        'weight_kg': _weightKg.toDouble(),
      });
      // Profile now complete → the gate advances to pairing automatically.
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _hydrate(context.read<AppState>());
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Sp.screen, Sp.x8, Sp.screen, Sp.x6),
          children: [
            const _Crest(Ic.profile),
            const SizedBox(height: Sp.x6),
            Text('About you.', style: AppText.display),
            const SizedBox(height: Sp.x4),
            Text(
              'These details refine your strain, active calories and recovery. '
              'They stay on your chosen backend.',
              style: AppText.bodySoft,
            ),
            const SizedBox(height: Sp.x7),

            Text('NAME', style: AppText.overline),
            const SizedBox(height: Sp.x3),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: AppText.body,
              decoration: const InputDecoration(hintText: 'Your name'),
            ),
            const SizedBox(height: Sp.x6),

            Text('SEX', style: AppText.overline),
            const SizedBox(height: Sp.x3),
            Row(children: [
              Expanded(
                child: _SexPill(
                  label: 'Male',
                  icon: Ic.activity,
                  selected: _sexIndex == 0,
                  onTap: () => setState(() => _sexIndex = 0),
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: _SexPill(
                  label: 'Female',
                  icon: Ic.activity,
                  selected: _sexIndex == 1,
                  onTap: () => setState(() => _sexIndex = 1),
                ),
              ),
            ]),
            const SizedBox(height: Sp.x6),

            _Stepper(
              label: 'AGE',
              value: _age,
              unit: 'yrs',
              min: 13,
              max: 100,
              onChanged: (v) => setState(() => _age = v),
            ),
            const SizedBox(height: Sp.x4),
            _SliderField(
              label: 'HEIGHT',
              value: _heightCm.toDouble(),
              unit: 'cm',
              min: 120,
              max: 220,
              onChanged: (v) => setState(() => _heightCm = v.round()),
            ),
            const SizedBox(height: Sp.x4),
            _SliderField(
              label: 'WEIGHT',
              value: _weightKg.toDouble(),
              unit: 'kg',
              min: 35,
              max: 200,
              onChanged: (v) => setState(() => _weightKg = v.round()),
            ),
            const SizedBox(height: Sp.x6),

            // Appearance — defaults to your phone's mode; change it live here.
            const _AppearanceSelector(),

            if (_error != null) _ErrorLine(_error!),
            const SizedBox(height: Sp.x7),

            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? _spinner()
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Text('Continue'),
                        SizedBox(width: Sp.x2),
                        AppIcon(Ic.arrowRight, size: 20, color: Colors.white),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline appearance section for onboarding (matches the SEX/AGE section style).
class _AppearanceSelector extends StatelessWidget {
  const _AppearanceSelector();
  @override
  Widget build(BuildContext context) => const AppearanceSelector(labeled: true);
}

/// A selectable pill for the sex segmented control.
class _SexPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _SexPill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(vertical: Sp.x4),
        decoration: BoxDecoration(
          color: selected ? AppColors.coral : AppColors.surface,
          borderRadius: BorderRadius.circular(R.cardSm),
          boxShadow: selected ? Shadows.coral : Shadows.card,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(icon,
                size: 20,
                color: selected ? Colors.white : AppColors.inkSoft),
            const SizedBox(width: Sp.x2),
            Text(
              label,
              style: AppText.title.copyWith(
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A stepper card with − / + round buttons and a big number.
class _Stepper extends StatelessWidget {
  final String label;
  final int value;
  final String unit;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  const _Stepper({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return ProCard(
      padding: const EdgeInsets.symmetric(
          horizontal: Sp.x5, vertical: Sp.x4),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppText.overline),
              const SizedBox(height: Sp.x2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$value', style: AppText.metric),
                  const SizedBox(width: 4),
                  Text(unit,
                      style: AppText.caption
                          .copyWith(color: AppColors.inkMuted)),
                ],
              ),
            ],
          ),
        ),
        RoundIconButton(
          Ic.down,
          bg: AppColors.surfaceAlt,
          onTap: value > min ? () => onChanged(value - 1) : null,
        ),
        const SizedBox(width: Sp.x2),
        RoundIconButton(
          Ic.up,
          bg: AppColors.coralSoft,
          fg: AppColors.coralDeep,
          onTap: value < max ? () => onChanged(value + 1) : null,
        ),
      ]),
    );
  }
}

/// A labelled slider card showing the current value + unit.
class _SliderField extends StatelessWidget {
  final String label;
  final double value;
  final String unit;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  const _SliderField({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return ProCard(
      padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(label, style: AppText.overline),
              const Spacer(),
              Text('${value.round()}', style: AppText.metricSm),
              const SizedBox(width: 4),
              Text(unit,
                  style: AppText.caption.copyWith(color: AppColors.inkMuted)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.coral,
              inactiveTrackColor: AppColors.surfaceAlt,
              thumbColor: AppColors.coral,
              overlayColor: AppColors.coral.withValues(alpha: 0.12),
              trackHeight: 5,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
