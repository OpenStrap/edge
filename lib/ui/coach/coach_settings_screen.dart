// AI Coach settings — BYOK. Enter an OpenAI-compatible base URL + API key, then
// fetch the provider's model list (GET /models) and pick one. Key is stored in the
// device keychain; nothing here touches OpenStrap servers.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class CoachSettingsScreen extends StatefulWidget {
  const CoachSettingsScreen({super.key});
  @override
  State<CoachSettingsScreen> createState() => _CoachSettingsScreenState();
}

class _CoachSettingsScreenState extends State<CoachSettingsScreen> {
  late final TextEditingController _base;
  late final TextEditingController _key;
  late final TextEditingController _query; // search / free-type box
  String _model = '';                       // committed model id (from list or typed)
  bool _obscure = true;
  bool _loadingModels = false;
  List<String> _models = const [];
  String? _msg;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<CoachConfig>();
    _base = TextEditingController(text: cfg.baseUrl);
    _key = TextEditingController(text: cfg.apiKey ?? '');
    _query = TextEditingController();
    _model = cfg.model;
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    if (_key.text.trim().isEmpty) {
      setState(() => _msg = 'Enter your API key first.');
      return;
    }
    setState(() { _loadingModels = true; _msg = null; });
    try {
      final ids = await CoachEngine.fetchModels(_base.text, _key.text);
      setState(() {
        _models = ids;
        _msg = ids.isEmpty ? 'Provider returned no models — type one manually.' : '${ids.length} models found. Search and tap to pick.';
      });
    } catch (e) {
      setState(() => _msg = e is CoachException ? e.message : 'Could not list models: $e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  // The chosen model = a tapped/ticked list item, else whatever was typed.
  String get _chosen => _model.isNotEmpty ? _model : _query.text.trim();

  Future<void> _save() async {
    final cfg = context.read<CoachConfig>();
    if (_chosen.isEmpty) {
      setState(() => _msg = 'Pick or type a model first.');
      return;
    }
    await cfg.save(baseUrl: _base.text, apiKey: _key.text, model: _chosen);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AI Coach settings saved.')));
      Navigator.of(context).pop();
    }
  }

  // Searchable list of fetched models + a "use what I typed" custom row. The row
  // matching the committed model shows a tick.
  Widget _modelList() {
    final q = _query.text.trim();
    final ql = q.toLowerCase();
    final filtered = ql.isEmpty ? _models : _models.where((m) => m.toLowerCase().contains(ql)).toList();
    final exact = _models.any((m) => m.toLowerCase() == ql);

    final rows = <Widget>[];
    if (q.isNotEmpty && !exact) rows.add(_modelRow(q, custom: true));
    for (final m in filtered.take(80)) {
      rows.add(_modelRow(m));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_model.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.x2),
          child: Row(children: [
            AppIcon(Ic.check, size: 14, color: AppColors.coral),
            const SizedBox(width: Sp.x2),
            Expanded(child: Text('Using: $_model',
                style: AppText.caption.copyWith(color: AppColors.coralInk))),
          ]),
        ),
      if (rows.isEmpty)
        Text(_models.isEmpty
            ? 'Tap Fetch to load your provider’s models — or just type a model id above and it’ll be used as-is.'
            : 'No match. Type a full model id to use it as a custom model.',
            style: AppText.captionMuted)
      else
        Container(
          constraints: const BoxConstraints(maxHeight: 280),
          decoration: BoxDecoration(
              color: AppColors.surfaceSunk, borderRadius: BorderRadius.circular(R.card)),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: Sp.x2), children: rows),
        ),
    ]);
  }

  Widget _modelRow(String id, {bool custom = false}) {
    final selected = _model == id;
    return InkWell(
      onTap: () => setState(() => _model = id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
        child: Row(children: [
          if (custom) ...[
            AppIcon(Ic.edit, size: 13, color: AppColors.inkMuted),
            const SizedBox(width: Sp.x2),
          ],
          Expanded(child: Text(custom ? 'Use “$id”' : id,
              style: AppText.body.copyWith(color: selected ? AppColors.coralInk : AppColors.ink))),
          if (selected) AppIcon(Ic.check, size: 18, color: AppColors.coral),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            Row(children: [
              RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: Sp.x3),
              Text('AI Coach', style: AppText.h1),
            ]),
            const SizedBox(height: Sp.x5),

            ProCard(child: Row(children: [
              AppIcon(Ic.shield, size: 18, color: AppColors.good),
              const SizedBox(width: Sp.x3),
              Expanded(child: Text('Your key is stored only on this device and is sent '
                  'directly to your provider — never to OpenStrap.', style: AppText.captionMuted)),
            ])),
            const SizedBox(height: Sp.x5),

            const SectionHeader('Provider'),
            TextField(
              controller: _base,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.openai.com/v1',
              ),
            ),
            const SizedBox(height: Sp.x3),
            TextField(
              controller: _key,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'API key',
                suffixIcon: IconButton(
                  icon: AppIcon(_obscure ? Ic.info : Ic.check, size: 18, color: AppColors.inkMuted),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: Sp.x3),
            Text('Works with OpenAI, OpenRouter, Groq, Together, local Ollama / LM Studio, '
                'and anything OpenAI-compatible.', style: AppText.captionMuted),

            const SizedBox(height: Sp.x5),
            const SectionHeader('Model'),
            Row(children: [
              Expanded(child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Search or type a model',
                  hintText: 'e.g. minimax, gpt-4o, llama',
                ),
              )),
              const SizedBox(width: Sp.x3),
              OutlinedButton(
                onPressed: _loadingModels ? null : _fetchModels,
                child: _loadingModels
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Fetch'),
              ),
            ]),
            const SizedBox(height: Sp.x3),
            _modelList(),
            if (_msg != null) ...[
              const SizedBox(height: Sp.x3),
              Text(_msg!, style: AppText.captionMuted),
            ],

            const SizedBox(height: Sp.x7),
            FilledButton(onPressed: _save, child: const Text('Save')),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}
