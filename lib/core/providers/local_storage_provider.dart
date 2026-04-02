import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/local_storage.dart';

final localStorageProvider = FutureProvider<LocalStorageService>((ref) async {
  final service = LocalStorageService();
  await service.init();
  return service;
});
