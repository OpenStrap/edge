// DataSource — the seam that makes "mode is plumbing, not data" real. Screens read
// a DataSource and never know whether results came from the on-device derived store
// (LocalDataSource) or the cloud API (CloudDataSource). AppState selects by AppMode.
import 'dart:convert';
import '../data/db.dart';

abstract class DataSource {
  Future<Map<String, dynamic>?> daily(String date);
  Future<Map<String, dynamic>?> sleep(String date);
  Future<List<Map<String, dynamic>>> dailyRange(String fromDate, String toDate);
}

/// Reads the on-device derived store the LocalPipeline writes.
class LocalDataSource implements DataSource {
  @override
  Future<Map<String, dynamic>?> daily(String date) => _one(date, 'daily');

  @override
  Future<Map<String, dynamic>?> sleep(String date) => _one(date, 'sleep');

  @override
  Future<List<Map<String, dynamic>>> dailyRange(String fromDate, String toDate) async {
    final rows = await LocalDb.getDerivedRange('daily', fromDate, toDate);
    return rows
        .map((r) => {'date': r['date'], ...(jsonDecode(r['payload'] as String) as Map<String, dynamic>)})
        .toList();
  }

  Future<Map<String, dynamic>?> _one(String date, String kind) async {
    final payload = await LocalDb.getDerived(date, kind);
    return payload == null ? null : jsonDecode(payload) as Map<String, dynamic>;
  }
}

/// Wraps the existing cloud API. Inject a `fetch(path)` that delegates to ApiClient
/// (kept generic so this file doesn't couple to ApiClient's exact method names —
/// AppState wires it: `CloudDataSource((p) => apiClient.getJson(p))`).
class CloudDataSource implements DataSource {
  final Future<dynamic> Function(String path) fetch;
  CloudDataSource(this.fetch);

  @override
  Future<Map<String, dynamic>?> daily(String date) async =>
      (await fetch('/day/strain?date=$date')) as Map<String, dynamic>?;

  @override
  Future<Map<String, dynamic>?> sleep(String date) async =>
      (await fetch('/day/sleep?date=$date')) as Map<String, dynamic>?;

  @override
  Future<List<Map<String, dynamic>>> dailyRange(String fromDate, String toDate) async {
    final res = await fetch('/history?from=$fromDate&to=$toDate');
    return (res as List).cast<Map<String, dynamic>>();
  }
}
