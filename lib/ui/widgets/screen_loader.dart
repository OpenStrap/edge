// ScreenData<T> + LoaderMixin — the shared loading lifecycle every insights
// screen uses: load cached payload instantly, fetch live on first mount, refresh
// in the background every 90s (IndexedStack keeps screens alive), pull-to-refresh,
// graceful empty/offline/error. No manual sync buttons.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../net/api_client.dart';
import '../../net/insights_cache.dart';
import '../../state/app_state.dart';

enum LoadPhase { loading, ready, empty, error }

/// Mix into a screen `State`. Provide [cacheKey], [fetch] (raw payload), and
/// [isEmpty] (does the payload have nothing to show?).
mixin ScreenLoaderMixin<W extends StatefulWidget> on State<W> {
  String get cacheKey;
  Future<Object?> fetch(ApiClient api);
  bool isEmpty(Object? data);

  Object? data;
  LoadPhase phase = LoadPhase.loading;
  String? errorText;
  CachedPayload? cached;
  bool fromCache = false;
  bool _busy = false;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    _timer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (mounted) refresh(background: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String? get _userKey =>
      (context.read<AppState>().user?['email'])?.toString();

  Future<void> _bootstrap() async {
    // 1. Instant render from cache (offline-safe).
    cached = await InsightsCache.load(cacheKey, userKey: _userKey);
    if (cached != null && mounted) {
      setState(() {
        data = cached!.data;
        fromCache = true;
        phase = isEmpty(data) ? LoadPhase.empty : LoadPhase.ready;
      });
    }
    // 2. Live fetch.
    await refresh(background: cached != null);
  }

  /// Pull-to-refresh / background refresh. [background] keeps the current view
  /// while fetching (no loading flash).
  Future<void> refresh({bool background = false}) async {
    if (_busy) return;
    final app = context.read<AppState>();
    if (!app.isAuthenticated || app.api == null) {
      if (mounted) {
        setState(() {
          phase = LoadPhase.empty;
          errorText = 'Sign in to see your insights.';
        });
      }
      return;
    }
    _busy = true;
    if (!background && data == null && mounted) {
      setState(() => phase = LoadPhase.loading);
    }
    try {
      final fresh = await fetch(app.api!);
      await InsightsCache.save(cacheKey, fresh, userKey: _userKey);
      if (!mounted) return;
      setState(() {
        data = fresh;
        fromCache = false;
        errorText = null;
        cached = CachedPayload(fresh, DateTime.now());
        phase = isEmpty(fresh) ? LoadPhase.empty : LoadPhase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Keep showing cached data if we have it; just mark offline.
        if (data != null) {
          fromCache = true;
          phase = isEmpty(data) ? LoadPhase.empty : LoadPhase.ready;
        } else {
          phase = LoadPhase.error;
          errorText = e is ApiException
              ? 'Couldn\'t reach the server.'
              : 'Something went wrong loading insights.';
        }
      });
    } finally {
      _busy = false;
    }
  }

  /// Freshness stamp string (null while live & fresh).
  String? get freshnessLabel => fromCache ? cached?.ageLabel : null;
}
