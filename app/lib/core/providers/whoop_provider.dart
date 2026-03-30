import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ble/whoop_connection.dart';
import 'local_storage_provider.dart';

final whoopManagerProvider = Provider<WhoopConnectionManager>((ref) {
  final manager = WhoopConnectionManager();

  ref.watch(localStorageProvider).whenData((storage) {
    manager.setStorageService(storage);
  });

  ref.onDispose(manager.dispose);
  return manager;
});

final whoopStateProvider = StreamProvider<WhoopConnectionState>((ref) {
  final manager = ref.watch(whoopManagerProvider);
  return manager.stateStream;
});
