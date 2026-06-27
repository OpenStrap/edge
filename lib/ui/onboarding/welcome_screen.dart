// welcome_screen.dart — the first onboarding step: continue as a NEW user, or
// sign in as an EXISTING v2 user and pull your cloud history into local storage.
//
// New  → records the choice; the gate advances to pairing → profile.
// Existing → email → OTP → import (derived snapshots + baselines, last 90 days) →
//            the gate advances to pairing → shell (profile pre-filled from cloud).
//
// The app is otherwise fully local; this screen is the only place that talks to
// the v2 backend, once, at onboarding.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../cloud/backend_client.dart';
import '../../cloud/cloud_import.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../import/import_screen.dart';
import '../kit/kit.dart';

enum _Step { choice, email, otp, importing }

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _client = BackendClient();

  _Step _step = _Step.choice;
  bool _busy = false;
  String? _error;
  String? _progress;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _client.close();
    super.dispose();
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  // ── actions ─────────────────────────────────────────────────────────────────

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      _set(() => _error = 'Enter a valid email.');
      return;
    }
    if (!_client.configured) {
      _set(() => _error =
          'No backend configured. Set one in Profile → Backend URL, then retry.');
      return;
    }
    _set(() {
      _busy = true;
      _error = null;
    });
    try {
      final exists = await _client.requestOtp(email);
      if (!exists) {
        _set(() {
          _busy = false;
          _error = "No v2 account for that email. Continue as a new user instead.";
        });
        return;
      }
      _set(() {
        _busy = false;
        _step = _Step.otp;
      });
    } catch (e) {
      _set(() {
        _busy = false;
        _error = _msg(e);
      });
    }
  }

  Future<void> _verifyAndImport() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      _set(() => _error = 'Enter the code from your email.');
      return;
    }
    final app = context.read<AppState>(); // capture before async gaps
    _set(() {
      _busy = true;
      _error = null;
    });
    try {
      await _client.verifyOtp(_email.text.trim(), code);
      _set(() {
        _step = _Step.importing;
        _progress = 'Downloading your last 90 days…';
      });
      final res = await CloudImporter.run(_client, days: CloudImporter.defaultDays);
      _set(() => _progress = 'Saving locally…');
      // Persist the cloud profile + mark onboarding done → the gate advances.
      await app.completeCloudOnboard(res.profile);
      // No pop needed: AppState.route changes and _Gate rebuilds to pairing/shell.
    } catch (e) {
      _set(() {
        _busy = false;
        _step = _Step.otp;
        _error = _msg(e);
      });
    }
  }

  String _msg(Object e) =>
      e is BackendException ? e.message : 'Something went wrong. Try again.';

  // ── build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          child: switch (_step) {
            _Step.choice => _choice(),
            _Step.email => _emailStep(),
            _Step.otp => _otpStep(),
            _Step.importing => _importingStep(),
          },
        ),
      ),
    );
  }

  Widget _choice() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Sp.x8),
        Text('Welcome to OpenStrap', style: AppText.h1),
        const SizedBox(height: Sp.x2),
        Text('Bring your history over, or start fresh.', style: AppText.bodySoft),
        const SizedBox(height: Sp.x8),
        _bigCard(
          icon: Ic.cloud,
          title: 'I used OpenStrap before',
          body: 'Sign in with your email and we’ll pull your past data '
              '(recovery, sleep, strain, workouts) into this phone.',
          onTap: () => _set(() {
            _step = _Step.email;
            _error = null;
          }),
        ),
        const SizedBox(height: Sp.x4),
        _bigCard(
          icon: Ic.cloud,
          title: 'Import from a file',
          body: 'Bring history from a NOOP CSV, an Edge backup, or a WHOOP '
              'export. You can still pair a band afterwards.',
          onTap: () =>
              Navigator.of(context).push(themedRoute((_) => const ImportScreen())),
        ),
        const SizedBox(height: Sp.x4),
        _bigCard(
          icon: Ic.profile,
          title: 'I’m new',
          body: 'Skip the import. We’ll ask a few basics and get you set up.',
          onTap: () => context.read<AppState>().chooseNewUser(),
        ),
      ],
    );
  }

  Widget _emailStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Sp.x6),
        _back(() => _set(() {
              _step = _Step.choice;
              _error = null;
            })),
        const SizedBox(height: Sp.x4),
        Text('Your account email', style: AppText.h1),
        const SizedBox(height: Sp.x2),
        Text('We’ll send a 6-digit code to confirm it’s you.',
            style: AppText.bodySoft),
        const SizedBox(height: Sp.x6),
        _input(_email, 'you@example.com', TextInputType.emailAddress,
            autofocus: true),
        _errorText(),
        const SizedBox(height: Sp.x6),
        _primary('Send code', _busy ? null : _sendCode),
        if (_error != null &&
            _error!.startsWith('No v2 account')) ...[
          const SizedBox(height: Sp.x3),
          _secondary('Continue as a new user',
              () => context.read<AppState>().chooseNewUser()),
        ],
      ],
    );
  }

  Widget _otpStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Sp.x6),
        _back(() => _set(() {
              _step = _Step.email;
              _error = null;
            })),
        const SizedBox(height: Sp.x4),
        Text('Enter your code', style: AppText.h1),
        const SizedBox(height: Sp.x2),
        Text('Sent to ${_email.text.trim()}. It expires in 10 minutes.',
            style: AppText.bodySoft),
        const SizedBox(height: Sp.x6),
        _input(_code, '123456', TextInputType.number,
            autofocus: true, maxLen: 6),
        _errorText(),
        const SizedBox(height: Sp.x6),
        _primary('Verify & import', _busy ? null : _verifyAndImport),
      ],
    );
  }

  Widget _importingStep() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.coral),
          const SizedBox(height: Sp.x5),
          Text(_progress ?? 'Importing…', style: AppText.title),
          const SizedBox(height: Sp.x2),
          Text('This runs once — your data stays on this device.',
              textAlign: TextAlign.center, style: AppText.captionMuted),
        ],
      ),
    );
  }

  // ── small building blocks (match profile-setup styling) ─────────────────────

  Widget _bigCard({
    required IconData icon,
    required String title,
    required String body,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: ProCard(
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: AppColors.coralSoft,
                borderRadius: BorderRadius.circular(R.chip)),
            child: AppIcon(icon, size: 20, color: AppColors.coralInk),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.title),
              const SizedBox(height: 3),
              Text(body, style: AppText.captionMuted),
            ]),
          ),
          const SizedBox(width: Sp.x2),
          AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
        ]),
      ),
    );
  }

  Widget _input(TextEditingController c, String hint, TextInputType kb,
      {bool autofocus = false, int? maxLen}) {
    return TextField(
      controller: c,
      keyboardType: kb,
      autofocus: autofocus,
      maxLength: maxLen,
      onChanged: (_) => _set(() => _error = null),
      style: AppText.metricSm.copyWith(fontSize: 20),
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(R.cardSm),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x4),
      ),
    );
  }

  Widget _primary(String label, VoidCallback? onTap) => SizedBox(
        height: 54,
        width: double.infinity,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.coral,
            disabledBackgroundColor: AppColors.coral.withValues(alpha: 0.3),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.pill)),
          ),
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(label, style: AppText.title.copyWith(color: Colors.white)),
        ),
      );

  Widget _secondary(String label, VoidCallback onTap) => SizedBox(
        height: 50,
        width: double.infinity,
        child: TextButton(
          onPressed: onTap,
          child: Text(label,
              style: AppText.title.copyWith(color: AppColors.coralInk)),
        ),
      );

  Widget _back(VoidCallback onTap) =>
      RoundIconButton(Ic.arrowLeft, onTap: onTap);

  Widget _errorText() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: Sp.x3, left: Sp.x1),
          child: Text(_error!,
              style: AppText.captionMuted.copyWith(color: AppColors.bad)),
        );
}
