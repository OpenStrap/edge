import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_service.dart';
import '../cloud/sync_worker.dart';
import '../pairing/pair_screen.dart';
import '../theme.dart';
import 'live_screen.dart';
import 'recovery_screen.dart';
import 'sleep_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});
  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _tab = 0;
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    final ble = ref.read(bleServiceProvider);
    final saved = await ble.getSavedBleId();
    if (saved == null) {
      if (!mounted) return;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const PairScreen()),
      );
      if (ok != true) return;
    } else {
      try {
        final dev = BluetoothDevice.fromId(saved);
        unawaited(ble.connect(dev));
      } catch (_) {}
    }
    ref.read(syncWorkerProvider).start();
  }

  @override
  Widget build(BuildContext context) {
    final pages = const [
      LiveScreen(),
      RecoveryScreen(),
      SleepScreen(),
      HistoryScreen(),
      SettingsScreen(),
    ];
    final titles = const ['Live', 'Recovery', 'Sleep', 'History', 'Settings'];
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        toolbarHeight: 48,
        title: Text(titles[_tab].toLowerCase(),
            style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: 1.2)),
        backgroundColor: WTheme.bg,
        scrolledUnderElevation: 0,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: KeyedSubtree(key: ValueKey(_tab), child: pages[_tab]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.favorite_outline),
              selectedIcon: Icon(Icons.favorite),
              label: 'Live'),
          NavigationDestination(
              icon: Icon(Icons.bolt_outlined),
              selectedIcon: Icon(Icons.bolt),
              label: 'Recovery'),
          NavigationDestination(
              icon: Icon(Icons.bedtime_outlined),
              selectedIcon: Icon(Icons.bedtime),
              label: 'Sleep'),
          NavigationDestination(
              icon: Icon(Icons.show_chart_outlined),
              selectedIcon: Icon(Icons.show_chart),
              label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}

void unawaited(Future<void> f) {}
