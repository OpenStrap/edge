import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/whoop_provider.dart';
import '../../core/ble/whoop_connection.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';

class DeviceConnectionScreen extends ConsumerStatefulWidget {
  const DeviceConnectionScreen({super.key});

  @override
  ConsumerState<DeviceConnectionScreen> createState() => _DeviceConnectionScreenState();
}

class _DeviceConnectionScreenState extends ConsumerState<DeviceConnectionScreen> {
  List<ScanResult> _scanResults = [];
  StreamSubscription? _scanSub;

  @override
  void initState() {
    super.initState();
    // Check if there's a saved device and try to auto-reconnect
    // Use addPostFrameCallback to ensure widget is fully mounted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndAutoReconnect();
    });
  }

  void _checkAndAutoReconnect() {
    try {
      final manager = ref.read(whoopManagerProvider);
      final lastDevice = manager.getLastConnectedDevice();
      if (lastDevice != null) {
        print('[DEBUG] Found saved device: ${lastDevice.name} (${lastDevice.key}), attempting auto-reconnect...');
        // Try to reconnect to the last device
        _autoReconnect(lastDevice.key);
      } else {
        print('[DEBUG] No saved device found');
      }
    } catch (e) {
      print('[DEBUG] Error checking saved device: $e');
    }
  }

  Future<void> _autoReconnect(String deviceKey) async {
    try {
      print('[DEBUG] Auto-connecting to device: $deviceKey');
      // Try to scan for and find the device
      print('[DEBUG] Starting BLE scan to find saved device...');
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await Future.delayed(const Duration(seconds: 3));
      
      // Look through scan results for the saved device
      final results = await FlutterBluePlus.scanResults.first;
      print('[DEBUG] Scan found ${results.length} devices, looking for $deviceKey');
      for (final r in results) {
        print('[DEBUG]   - ${r.device.remoteId.str}: ${r.device.platformName}');
      }
      
      final targetDevice = results.firstWhere(
        (r) => r.device.remoteId.str == deviceKey,
        orElse: () => throw Exception('Saved device not found in scan'),
      );
      
      print('[DEBUG] Found saved device: ${targetDevice.device.platformName}');
      final manager = ref.read(whoopManagerProvider);
      await manager.connectToDevice(targetDevice.device, targetDevice.rssi);
    } catch (e) {
      print('[DEBUG] Auto-reconnect failed: $e, showing device list');
      // Fall back to scan if auto-connect fails
      if (mounted) {
        _requestBluetoothPermissions(context);
      }
    }
  }

  Future<void> _requestBluetoothPermissions(BuildContext context) async {
    print('[DEBUG] Requesting Bluetooth and Location permissions...');
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetooth,
      Permission.locationWhenInUse,
    ].request();
    statuses.forEach((key, value) {
      print('[DEBUG] Permission ${key.toString()}: ${value.toString()}');
    });
    if (statuses.values.any((status) => status.isDenied)) {
      print('[DEBUG] One or more permissions denied.');
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permissions Required'),
            content: const Text('Bluetooth and Location permissions are required to scan for WHOOP devices.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }
    print('[DEBUG] All permissions granted. Starting scan...');
    _startScan();
  }

  void _startScan() {
    print('[DEBUG] _startScan called');
    // Don't clear scan results - keep showing devices while scanning
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      print('[DEBUG] Scan results: ${results.length} devices');
      for (final r in results) {
        print('[DEBUG] Device: ${r.device.platformName}, RSSI: ${r.rssi}');
      }
      setState(() {
        _scanResults = results;
      });
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
    final manager = ref.read(whoopManagerProvider);
    manager.startScan();
  }

  void _connectToDevice(ScanResult result) async {
    print('[DEBUG] Connecting to device: ${result.device.platformName}');
    final manager = ref.read(whoopManagerProvider);
    await manager.connectToDevice(result.device, result.rssi);
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  Widget _buildInfoCard(String title, List<String> items) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            ...items.map((item) => Text(
              item,
              style: const TextStyle(fontSize: 12),
            )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final stateAsync = ref.watch(whoopStateProvider);
    print('[DEBUG] build() called. stateAsync: $stateAsync');
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to WHOOP Device')),
      body: stateAsync.when(
        data: (state) {
          print('[DEBUG] state.phase: ${state.phase}, state: $state');
          if (state.phase == WhoopConnectionPhase.idle) {
            return Center(
              child: ElevatedButton(
                onPressed: () => _requestBluetoothPermissions(context),
                child: const Text('Scan for Devices'),
              ),
            );
          } else if (state.phase == WhoopConnectionPhase.scanning) {
            if (_scanResults.isEmpty) {
              return const Center(child: Text('Scanning for BLE devices...'));
            } else {
              return ListView.builder(
                itemCount: _scanResults.length,
                itemBuilder: (context, index) {
                  final result = _scanResults[index];
                  final displayName = result.device.platformName.isNotEmpty
                    ? result.device.platformName
                    : result.device.remoteId.str;
                  return ListTile(
                    title: Text(displayName),
                    subtitle: Text('RSSI: ${result.rssi}'),
                    onTap: () => _connectToDevice(result),
                  );
                },
              );
            }
          } else if (state.phase == WhoopConnectionPhase.connecting) {
            return Center(child: Text('Connecting to ${state.deviceName ?? 'device'}...'));
          } else if (state.phase == WhoopConnectionPhase.discoveringServices) {
            return const Center(child: Text('Discovering services...'));
          } else if (state.phase == WhoopConnectionPhase.subscribing) {
            return const Center(child: Text('Subscribing to notifications...'));
          } else if (state.phase == WhoopConnectionPhase.initializing) {
            return const Center(child: Text('Initializing device...'));
          } else if (state.phase == WhoopConnectionPhase.syncing) {
            return const Center(child: Text('Syncing history...'));
          } else if (state.phase == WhoopConnectionPhase.realtime) {
            return SingleChildScrollView(
              child: Column(
                children: [
                  Container(
                    color: Colors.green.shade100,
                    padding: const EdgeInsets.all(12),
                    width: double.infinity,
                    child: Text(
                      '🟢 Connected: ${state.deviceName ?? 'WHOOP'}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildInfoCard('Device Info', [
                          'Model: ${state.deviceName ?? 'WHOOP'}',
                          'Serial: ${state.serial ?? '—'}',
                          'Advertising Name: ${state.advertisingName ?? '—'}',
                        ]),
                        const SizedBox(height: 12),
                        _buildInfoCard('Battery & Charging', [
                          'Battery: ${(state.batteryPct != null ? (state.batteryPct! * 100).clamp(0, 100) : 0).toStringAsFixed(1)}%',
                          'Charging: ${state.charging == true ? '⚡ Yes' : state.charging == false ? 'No' : '—'}',
                        ]),
                        const SizedBox(height: 12),
                        _buildInfoCard('Wrist Status', [
                          'On Wrist: ${state.wristOn == true ? '✓ Yes' : state.wristOn == false ? '✗ No' : '—'}',
                          'Skin Temp: ${state.tempC != null ? '${state.tempC!.toStringAsFixed(1)}°C' : '— (awaiting event)'}',
                        ]),
                        const SizedBox(height: 12),
                        _buildInfoCard('Heart Rate & IMU (R10)', [
                          'Heart Rate: ${state.heartRate ?? '—'} bpm',
                          'HR History: ${state.hrHistory.isEmpty ? '—' : '${state.hrHistory.length} samples'}',
                          if (state.lastR10 != null && state.lastR10!.hasImu) ...[
                            'Accel X: ${state.lastR10?.accelX?.isNotEmpty == true ? state.lastR10!.accelX!.first : '—'}',
                            'Accel Y: ${state.lastR10?.accelY?.isNotEmpty == true ? state.lastR10!.accelY!.first : '—'}',
                            'Accel Z: ${state.lastR10?.accelZ?.isNotEmpty == true ? state.lastR10!.accelZ!.first : '—'}',
                          ],
                        ]),
                        const SizedBox(height: 12),
                        _buildInfoCard('PPG / Optical (R21)', [
                          if (state.lastR21 != null) ...[
                            '✓ Optical locked',
                            'LED Drive: ${state.lastR21!.ledDrive}',
                            'Green 1 Samples: ${state.lastR21?.channelA?.length ?? 0}',
                            'Green 2 Samples: ${state.lastR21?.channelB?.length ?? 0}',
                            'Infrared Samples: ${state.lastR21?.channelC?.length ?? 0}',
                            'Red/SpO2 Samples: ${state.lastR21?.channelF?.length ?? 0}',
                          ] else
                            '⏳ Optical sensor locking... (takes 10-30 seconds)',
                        ]),
                        const SizedBox(height: 12),
                        _buildInfoCard('Sync Progress', [
                          'Batches Synced: ${state.batchCount}',
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          final manager = ref.read(whoopManagerProvider);
                          manager.sendHaptic();
                        },
                        icon: const Icon(Icons.vibration),
                        label: const Text('Send Haptic'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: () {
                          final manager = ref.read(whoopManagerProvider);
                          manager.disconnect();
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        child: const Text('Disconnect', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          } else if (state.phase == WhoopConnectionPhase.disconnected) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Disconnected.'),
                  ElevatedButton(
                    onPressed: () => _requestBluetoothPermissions(context),
                    child: const Text('Reconnect'),
                  ),
                ],
              ),
            );
          } else if (state.phase == WhoopConnectionPhase.error) {
            // Show device list with error banner
            return Column(
              children: [
                Container(
                  color: Colors.red.shade100,
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  child: Text(
                    'Error: ${state.errorMessage ?? 'Unknown error'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
                Expanded(
                  child: _scanResults.isEmpty
                    ? const Center(child: Text('No devices found. Tap Retry to scan again.'))
                    : ListView.builder(
                        itemCount: _scanResults.length,
                        itemBuilder: (context, index) {
                          final result = _scanResults[index];
                          final displayName = result.device.platformName.isNotEmpty
                            ? result.device.platformName
                            : result.device.remoteId.str;
                          return ListTile(
                            title: Text(displayName),
                            subtitle: Text('RSSI: ${result.rssi}'),
                            onTap: () => _connectToDevice(result),
                          );
                        },
                      ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: () => _requestBluetoothPermissions(context),
                    child: const Text('Retry Scan'),
                  ),
                ),
              ],
            );
          } else {
            return const SizedBox.shrink();
          }
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
