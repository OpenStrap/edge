// ScreenData<T> + LoaderMixin — the shared loading lifecycle every insights
// screen uses: fetch on first mount, refresh in the background every 90s
// (kept-alive screens), pull-to-refresh, graceful empty/offline/error.
//
// CLOUD EXCISED: fetch now runs against the LocalRepository SEAM (app.repo),
// not the deleted ApiClient. The per-screen JSON payload cache (insights_cache.dart)
// was a cloud-offline aid and was removed — the future re-layer computes payloads
// locally from db.dart, so there is no network round-trip to cache against.
// Until the re-layer lands, `fetch` throws UnimplementedError and screens render
// their error/empty state (expected; see HANDOFF).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';

enum LoadPhase { loading, ready, empty, error }

@visibleForTesting
class ScreenRefreshGate {
  bool _busy = false;
  bool _queued = false;

  bool get busy => _busy;
  bool get queued => _queued;

  bool tryBegin() {
    if (_busy) {
      _queued = true;
      return false;
    }
    _busy = true;
    return true;
  }

  bool finishAndShouldReplay() {
    _busy = false;
    if (_queued) {
      _queued = false;
      return true;
    }
    return false;
  }
}

/// Mix into a screen `State`. Provide [cacheKey] (kept for parity / future local
/// cache), [fetch] (raw payload), and [isEmpty] (does the payload have nothing?).
mixin ScreenLoaderMixin<W extends StatefulWidget> on State<W> {
  String get cacheKey;
  Future<Object?> fetch(LocalRepository repo);
  bool isEmpty(Object? data);

  Object? data;
  LoadPhase phase = LoadPhase.loading;
  String? errorText;
  bool fromCache = false;
  final ScreenRefreshGate _refreshGate = ScreenRefreshGate();

  Timer? _timer;
  AppState? _app;
  VoidCallback? _insightsListener;
  int _lastInsightsRevision = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _app = context.read<AppState>();
      _lastInsightsRevision = _app!.insightsRevision.value;
      _insightsListener = () {
        final app = _app;
        if (!mounted || app == null) return;
        final next = app.insightsRevision.value;
        if (next == _lastInsightsRevision) return;
        _lastInsightsRevision = next;
        refresh(background: true);
      };
      _app!.insightsRevision.addListener(_insightsListener!);
      refresh();
    });
    _timer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (mounted) refresh(background: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    final listener = _insightsListener;
    final app = _app;
    if (listener != null && app != null) {
      app.insightsRevision.removeListener(listener);
    }
    super.dispose();
  }

  /// Pull-to-refresh / background refresh. [background] keeps the current view
  /// while fetching (no loading flash).
  Future<void> refresh({bool background = false}) async {
    if (!_refreshGate.tryBegin()) return;
    final app = context.read<AppState>();
    final repo = app.repo;
    if (repo == null) {
      if (mounted) {
        setState(() {
          phase = LoadPhase.empty;
          errorText = 'Local insights are not available yet.';
        });
      }
      _refreshGate.finishAndShouldReplay();
      return;
    }
    if (!background && data == null && mounted) {
      setState(() => phase = LoadPhase.loading);
    }
    try {
      final fresh = await fetch(repo);
      if (!mounted) return;
      setState(() {
        data = fresh;
        fromCache = false;
        errorText = null;
        phase = isEmpty(fresh) ? LoadPhase.empty : LoadPhase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Keep showing prior data if we have it; just mark offline.
        if (data != null) {
          fromCache = true;
          phase = isEmpty(data) ? LoadPhase.empty : LoadPhase.ready;
        } else {
          phase = LoadPhase.error;
          errorText = e is RepositoryException
              ? 'Couldn\'t load your insights.'
              : 'Something went wrong loading insights.';
        }
      });
    } finally {
      if (_refreshGate.finishAndShouldReplay() && mounted) {
        unawaited(refresh(background: true));
      }
    }
  }

  /// Freshness stamp string (null while live & fresh). No local cache yet.
  String? get freshnessLabel => null;
}
