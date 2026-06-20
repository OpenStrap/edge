// Shareable week/month summary card, captured to a PNG via share_plus.
// Week/Month toggle refetches /history.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class RecapScreen extends StatefulWidget {
  const RecapScreen({super.key});
  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

enum _Phase { loading, ready, empty, error }

class _RecapScreenState extends State<RecapScreen> {
  final GlobalKey _cardKey = GlobalKey();

  String _range = '7d'; // '7d' | '30d'
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) {
      setState(() {
        _phase = _Phase.error;
        _error = 'Not signed in.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final res = await api.getHistory(range: _range);
      if (!mounted) return;
      final empty = _isEmpty(res);
      setState(() {
        _data = res;
        _phase = empty ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is ApiException ? e.body : e.toString();
      });
    }
  }

  bool _isEmpty(Map<String, dynamic> d) {
    final metrics = _map(d['metrics']);
    final worn = _num(d['worn_days'])?.toInt() ?? 0;
    return metrics.isEmpty || worn <= 0;
  }

  void _onRange(int i) {
    final next = i == 0 ? '7d' : '30d';
    if (next == _range) return;
    _range = next;
    _load();
  }

  // ── defensive parsing helpers ───────────────────────────────────────────────

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  /// A metric sub-object {avg,min,max,latest,total,delta_pct,trend}.
  Map<String, dynamic> _metric(String key) =>
      _map(_map(_data['metrics'])[key]);

  num? _mAvg(String key) => _num(_metric(key)['avg']);
  num? _mTotal(String key) => _num(_metric(key)['total']);
  num? _mDelta(String key) => _num(_metric(key)['delta_pct']);

  /// Daily series values for a key, oldest→newest order preserved as given.
  List<double> _series(String key) {
    final raw = _map(_data['series'])[key];
    if (raw is! List) return const [];
    final out = <double>[];
    for (final p in raw) {
      final v = _num(_map(p)['v']);
      if (v != null) out.add(v.toDouble());
    }
    return out;
  }

  // ── formatting (no intl) ─────────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmtDay(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000).toLocal();
    return '${_months[d.month - 1]} ${d.day}';
  }

  /// "This week" / "This month" with a date range when epochs are present.
  String _periodLabel() {
    final from = _num(_data['from_epoch'])?.toInt();
    final to = _num(_data['to_epoch'])?.toInt();
    if (from != null && to != null && to > 0) {
      return '${_fmtDay(from)} – ${_fmtDay(to)}';
    }
    return _range == '7d' ? 'This week' : 'This month';
  }

  String? _hm(num? minutes) {
    if (minutes == null) return null;
    final m = minutes.round();
    return '${m ~/ 60}h ${m % 60}m';
  }

  String _compact(num? v) {
    if (v == null) return '—';
    final n = v.round();
    if (n >= 1000) {
      final k = n / 1000.0;
      return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
    }
    return '$n';
  }

  // ── build ────────────────────────────────────────────────────────────────────

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
            _topBar(),
            const SizedBox(height: Sp.x6),
            if (_phase == _Phase.loading)
              _loading()
            else if (_phase == _Phase.empty)
              _stateCard(
                Ic.calendar,
                'Not enough data yet',
                'Wear your strap and sync for a few days. Your recap appears once '
                    'there is a week of data to summarize.',
              )
            else if (_phase == _Phase.error)
              _stateCard(
                Ic.cloud,
                "Couldn't load your recap",
                _error ?? 'Please try again.',
              )
            else ...[
              RepaintBoundary(key: _cardKey, child: _shareCard()),
              const SizedBox(height: Sp.x5),
              _shareButton(),
            ],
            const SizedBox(height: 110),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(child: Text('Recap', style: AppText.h1)),
        const SizedBox(width: Sp.x3),
        SegToggle(
          options: const ['Week', 'Month'],
          index: _range == '7d' ? 0 : 1,
          onChanged: _onRange,
        ),
      ],
    );
  }

  // ── the shareable card ─────────────────────────────────────

  Widget _shareCard() {
    final strainAvg = _mAvg('strain');
    final strainDelta = _mDelta('strain');
    final rhrAvg = _mAvg('resting_hr');
    final rhrDelta = _mDelta('resting_hr');
    final sleep = _hm(_mAvg('sleep_duration'));
    final calories = _mTotal('calories');

    // Mini visualization: prefer strain series, fall back to steps.
    var series = _series('strain');
    if (series.isEmpty) series = _series('steps');

    // Light, on-scheme shareable card: warm-white surface, coral accents, a
    // soft coral glow top-right (matches GlowCard), ink typography. Solid bg so
    // the rasterized PNG is never transparent.
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(R.card),
        boxShadow: Shadows.card,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(R.card),
        child: Stack(
          children: [
            Positioned(
              top: -70,
              right: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.coral.withValues(alpha: 0.22),
                      Colors.transparent
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x7, Sp.x6, Sp.x6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header: wordmark + period.
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppColors.coralSoft,
                          borderRadius: BorderRadius.circular(R.chip),
                        ),
                        child: AppIcon(Ic.strain,
                            size: 16, color: AppColors.coralDeep),
                      ),
                      const SizedBox(width: Sp.x2),
                      Text('OpenStrap', style: AppText.title),
                      const Spacer(),
                      Text(_periodLabel(), style: AppText.caption),
                    ],
                  ),
                  const SizedBox(height: Sp.x8),

                  // Hero stat: avg strain.
                  Text('AVG STRAIN', style: AppText.overline),
                  const SizedBox(height: Sp.x3),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        strainAvg == null ? '—' : strainAvg.toStringAsFixed(1),
                        style: AppText.hero.copyWith(color: AppColors.coral),
                      ),
                      const SizedBox(width: Sp.x3),
                      Padding(
                        padding: const EdgeInsets.only(bottom: Sp.x3),
                        child: DeltaChip(strainDelta),
                      ),
                    ],
                  ),
                  const SizedBox(height: Sp.x7),

                  // Three highlight stats.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _highlight(
                          'RESTING HR',
                          rhrAvg == null ? '—' : '${rhrAvg.round()}',
                          unit: 'bpm',
                          delta: rhrDelta,
                          deltaGoodIsUp: false,
                        ),
                      ),
                      _vDivider(),
                      Expanded(child: _highlight('SLEEP', sleep ?? '—')),
                      _vDivider(),
                      Expanded(
                        child: _highlight('ACTIVE CAL', _compact(calories),
                            unit: 'kcal'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Sp.x7),

                  if (series.isNotEmpty) ...[
                    Text('DAILY STRAIN', style: AppText.overline),
                    const SizedBox(height: Sp.x3),
                    DotMatrix(series, color: AppColors.coral, rows: 8, cell: 9),
                    const SizedBox(height: Sp.x7),
                  ],

                  // Footer.
                  Row(
                    children: [
                      AppIcon(Ic.shield,
                          size: 13, color: AppColors.inkMuted),
                      const SizedBox(width: 6),
                      Text('your data · your server · openstrap',
                          style: AppText.captionMuted),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vDivider() => Container(
        width: 1,
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: Sp.x3),
        color: AppColors.divider,
      );

  Widget _highlight(
    String label,
    String value, {
    String? unit,
    num? delta,
    bool deltaGoodIsUp = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: AppText.overline, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: Sp.x2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(value,
                  style: AppText.metricSm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (unit != null) ...[
              const SizedBox(width: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(unit,
                    style: AppText.captionMuted.copyWith(fontSize: 10)),
              ),
            ],
          ],
        ),
        if (delta != null) ...[
          const SizedBox(height: Sp.x2),
          DeltaChip(delta, goodIsUp: deltaGoodIsUp),
        ],
      ],
    );
  }

  // ── share button + capture ───────────────────────────────────────────────────

  Widget _shareButton() {
    return FilledButton.icon(
      onPressed: _sharing ? null : _share,
      icon: _sharing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const AppIcon(Ic.arrowRight, size: 20, color: Colors.white),
      label: Text(_sharing ? 'Preparing…' : 'Share my recap'),
    );
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      // iOS/iPad: the share sheet is a popover and REQUIRES an anchor rect, or
      // it throws PlatformException(sharePositionOrigin: argument must be set).
      // Capture it now, before any async gap, while layout is stable.
      final box = context.findRenderObject() as RenderBox?;
      final origin = (box != null && box.hasSize)
          ? (box.localToGlobal(Offset.zero) & box.size)
          : null;

      final boundary = _cardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Card not ready');

      final ui.Image image = await boundary.toImage(pixelRatio: 3);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Failed to encode image');

      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/openstrap_recap_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'My OpenStrap recap',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't share recap: $e")),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // ── states ─────────────────────────────────────────────────────────────────

  Widget _loading() => ProCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: SizedBox(
          height: 360,
          child: Center(
            child: CircularProgressIndicator(color: AppColors.coral),
          ),
        ),
      );

  Widget _stateCard(IconData icon, String title, String message) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              shape: BoxShape.circle,
            ),
            child: AppIcon(icon, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x5),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ],
      ),
    );
  }
}
