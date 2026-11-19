// Données > Kcalculator — connect HealthE to the user's own Kcalculator server.
// See lib/cloud/kcalculator_sync.dart for what is exchanged (one row per day
// each way) and why it is opt-in.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../cloud/kcalculator_sync.dart';
import '../ui2.dart';

class KcalculatorSettings extends StatefulWidget {
  const KcalculatorSettings({super.key});

  @override
  State<KcalculatorSettings> createState() => _KcalculatorSettingsState();
}

class _KcalculatorSettingsState extends State<KcalculatorSettings> {
  final _url = TextEditingController();
  final _anon = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = true;
  bool _connected = false;
  bool _busy = false;
  String? _message;
  bool _failed = false;
  DateTime? _lastAt;
  String? _lastStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _anon.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = KcalculatorSync.instance;
    final c = await s.config();
    final connected = await s.isConnected;
    final last = await s.lastRun();
    if (!mounted) return;
    setState(() {
      _url.text = c?.url ?? _url.text;
      _anon.text = c?.anonKey ?? _anon.text;
      _email.text = c?.email ?? _email.text;
      _connected = connected;
      _lastAt = last.at;
      _lastStatus = last.status;
      _loading = false;
    });
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final err = await KcalculatorSync.instance.signIn(
      url: _url.text,
      anonKey: _anon.text,
      email: _email.text,
      password: _password.text,
    );
    _password.clear();
    if (err != null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = err;
          _failed = true;
        });
      }
      return;
    }
    final status = await KcalculatorSync.instance.syncNow();
    await _load();
    if (mounted) {
      setState(() {
        _busy = false;
        _message = status;
        _failed = status.startsWith('Échec') || status.startsWith('Session');
      });
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final status = await KcalculatorSync.instance.syncNow();
    await _load();
    if (mounted) {
      setState(() {
        _busy = false;
        _message = status;
        _failed = status.startsWith('Échec') || status.startsWith('Session');
      });
    }
  }

  Future<void> _disconnect() async {
    await KcalculatorSync.instance.signOut();
    _url.clear();
    _anon.clear();
    _email.clear();
    await _load();
    if (mounted) setState(() => _message = 'Déconnecté. Les jours déjà reçus restent dans ton journal.');
  }

  Widget _field(BuildContext c, TextEditingController ctl, String label, {String hint = '', TextInputType? kind, bool secret = false}) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: F.over.copyWith(color: p.ink3)),
        TextField(
          controller: ctl,
          keyboardType: kind,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: !secret,
          style: F.body.copyWith(color: p.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: F.body.copyWith(color: p.ink3),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: S.x3),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: p.on(C.green))),
          ),
        ),
      ]),
    );
  }

  String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} à ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Kcalculator'),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                    children: [
                      Section(
                        'Ce qui est échangé',
                        Surface(
                          child: Text(
                            'Reçu de Kcalculator : le total de chaque jour (kcal, protéines, glucides, lipides, '
                            'micronutriments), ajouté à ton journal alimentaire.\n'
                            'Envoyé à Kcalculator : pour chaque jour, les calories dépensées, les pas, le sommeil, '
                            'la HRV, la FC au repos et ta dernière pesée.\n'
                            'Rien d’autre ne quitte le téléphone, et seulement vers ton propre serveur.',
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                        ),
                      ),
                      const SizedBox(height: S.x5),
                      if (!_connected)
                        Section(
                          'Connexion',
                          Surface(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              _field(c, _url, 'ADRESSE DU SERVEUR', hint: 'https://xxxx.supabase.co', kind: TextInputType.url),
                              _field(c, _anon, 'CLÉ PUBLIQUE (ANON KEY)', hint: 'eyJhbGciOi…'),
                              _field(c, _email, 'EMAIL KCALCULATOR', kind: TextInputType.emailAddress),
                              _field(c, _password, 'MOT DE PASSE KCALCULATOR', secret: true),
                              const SizedBox(height: S.x2),
                              BigButton('Se connecter et synchroniser',
                                  icon: LucideIcons.link, busy: _busy, onTap: _busy ? null : _connect),
                            ]),
                          ),
                        )
                      else
                        Section(
                          'Connecté',
                          Surface(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Text(_email.text, style: F.head.copyWith(color: p.ink)),
                              const SizedBox(height: S.x1),
                              Text(_url.text, style: F.cap.copyWith(color: p.ink3)),
                              const SizedBox(height: S.x3),
                              Text(
                                _lastAt == null ? 'Jamais synchronisé' : 'Dernière synchro le ${_stamp(_lastAt!)}',
                                style: F.cap.copyWith(color: p.ink2),
                              ),
                              if (_lastStatus != null)
                                Text(_lastStatus!, style: F.cap.copyWith(color: p.ink3, height: 1.4)),
                              const SizedBox(height: S.x4),
                              BigButton('Synchroniser maintenant',
                                  icon: LucideIcons.refreshCw, busy: _busy, onTap: _busy ? null : _syncNow),
                              const SizedBox(height: S.x3),
                              BigButton('Se déconnecter',
                                  icon: LucideIcons.logOut, color: C.red, soft: true, onTap: _busy ? null : _disconnect),
                            ]),
                          ),
                        ),
                      if (_message != null) ...[
                        const SizedBox(height: S.x3),
                        Text(_message!, style: F.cap.copyWith(color: _failed ? p.on(C.red) : p.ink2, height: 1.5)),
                      ],
                      const SizedBox(height: S.x5),
                      Text(
                        'La synchro tourne aussi toute seule à chaque ouverture de l’appli et après chaque synchro du bracelet.',
                        style: F.cap.copyWith(color: p.ink3, height: 1.4),
                      ),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }
}
