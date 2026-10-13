// Local, opt-in research copies. Never part of LocalDb or a network path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show hexToBytes;

import '../data/models.dart';
import 'debug_mode.dart';

const r10ProtocolSha = '89080bcfac7767b3a871fd3a7d9307f5f30dad26';

class Whoop4R10Capture extends ChangeNotifier {
  Whoop4R10Capture()
      : enabled = whoop4R10ResearchEnabled,
        maxBytes = 20 * 1024 * 1024,
        lifetime = const Duration(minutes: 30),
        _now = DateTime.now,
        _root = _privateRoot;

  @visibleForTesting
  Whoop4R10Capture.forTesting({
    required Directory root,
    bool enabled = true,
    this.maxBytes = 20 * 1024 * 1024,
    this.lifetime = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : enabled = kDebugMode && enabled,
       _root = (() async => root),
       _now = now ?? DateTime.now;

  final bool enabled;
  final int maxBytes;
  final Duration lifetime;
  final Future<Directory> Function() _root;
  final DateTime Function() _now;
  Future<void> _tail = Future<void>.value();
  Directory? _directory;
  Timer? _expiry;
  DateTime? _started;
  bool _active = false, _foreground = true, _dead = false;
  int _generation = 0, _chunks = 0;
  int records = 0, bytes = 0, duplicates = 0, unsupported = 0;
  int eligible = 0;
  bool incomplete = false, contextTruncated = false;
  String status = 'Not started';
  String? _alias, _appVersion;
  Map<String, Object?> _context = {};
  final List<Map<String, Object?>> _events = [];
  final Set<String> _seen = {};

  bool get active => _active;
  int get sessionGeneration => _generation;
  bool get foreground => _foreground;
  bool get hasSession => _directory != null;
  Directory? get directory => _directory;
  DateTime? get started => _started;

  static Future<Directory> _privateRoot() async {
    // Android cacheDir / iOS NSCachesDirectory: no database/document backup.
    // Unsupported platforms must not silently choose a persistent folder.
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw StateError('unsupported_platform');
    }
    return Directory(p.join((await getTemporaryDirectory()).path,
        'whoop4_r10_research'));
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  void _changed() {
    if (!_dead) notifyListeners();
  }

  void _event(String type) {
    if (_started == null) return;
    if (_events.length >= 256) {
      contextTruncated = true;
      return;
    }
    _events.add({'type': type, 'observed_at_epoch_ms': _now().millisecondsSinceEpoch,
      ..._context});
  }

  Future<void> start({required bool consent, String? appVersion}) {
    if (!enabled || !consent || _dead) {
      return Future<void>.error(StateError('research_not_enabled_or_consented'));
    }
    // Revocation can invalidate a queued start before it touches storage.
    final generation = ++_generation;
    return _serial(() async {
      if (generation != _generation || _dead) return;
      _expiry?.cancel();
      _active = false;
      final root = await _root();
      if (generation != _generation || _dead) return;
      // One bounded session only. Start explicitly replaces previous captures.
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
      if (generation != _generation || _dead) return;
      _directory = root;
      _started = _now();
      _alias = List.generate(16, (_) => Random.secure().nextInt(256)
          .toRadixString(16).padLeft(2, '0')).join();
      _appVersion = appVersion;
      records = bytes = duplicates = unsupported = eligible = _chunks = 0;
      incomplete = contextTruncated = false;
      _seen.clear();
      _events.clear();
      _context = {};
      _active = true;
      status = 'Capturing';
      _event('start');
      await _manifest();
      if (generation != _generation || _dead) return;
      _expiry = Timer(lifetime, () => stop(reason: 'Time limit reached', partial: true));
      _changed();
    }).catchError((Object _) {
      fail();
      throw StateError('research_start_failed');
    });
  }

  void observeContext({double? batteryPct, bool? charging, int? chargingTs,
      required bool connected, String? generation}) {
    if (!_active) return;
    final next = <String, Object?>{
      'band_battery_pct': batteryPct?.round(),
      'charging': charging, 'charging_ts': chargingTs,
      'connected': connected, 'generation': generation,
      'firmware': null, 'rssi': null,
      'freshness': 'sync_observation_not_historical',
    };
    if (jsonEncode(next) != jsonEncode(_context)) {
      _context = next;
      _event('context');
    }
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (_active) {
      _event(value ? 'foreground' : 'background_capture_suspended');
      if (!value) incomplete = true;
      _changed();
    }
  }

  /// Synchronous revocation; queued/in-flight operations check generation.
  void revoke(String reason) {
    ++_generation;
    _active = false;
    _expiry?.cancel();
    if (_started != null) {
      status = reason;
      _event('stop');
      _changed();
    }
  }

  Future<void> stop({String reason = 'Stopped', bool partial = false}) async {
    if (partial) incomplete = true;
    revoke(reason);
    await _serial(() async {
      if (_directory != null) await _manifest();
    }).catchError((Object _) { fail(); });
  }

  void fail() {
    incomplete = true;
    revoke('Capture incomplete: local storage error');
  }

  static bool matches(String hex, String? family, int packetType) =>
      family == 'gen4' && packetType == 0x2f &&
      hex.length == 1920 * 2 &&
      hex.toLowerCase().startsWith('2f0a') &&
      RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex);

  /// Called only after the normal durable commit, still before ACK eligibility.
  /// Research errors never escape into the normal sync failure contract.
  Future<void> captureBatch(List<RawRecord> raws, {
    List<ArchiveRecord>? archives, String? deviceFamily,
  }) async {
    if (!_active || !_foreground || !enabled) return;
    final generation = _generation;
    try {
      await _serial(() async {
        if (!_active || generation != _generation || !_foreground) return;
        if (_now().difference(_started!) >= lifetime) {
          incomplete = true;
          revoke('Time limit reached');
          await _manifest();
          return;
        }
        var block = <Map<String, Object?>>[];
        var blockBytes = 0;
        Future<void> flush() async {
          if (block.isEmpty || generation != _generation || !_active) return;
          final lines = block.map(jsonEncode).join('\n');
          final digest = sha256.convert(utf8.encode(lines)).toString();
          final content = '$lines\n${jsonEncode({
            'kind': 'chunk_end', 'records': block.length,
            'content_sha256': digest, 'normal_commit_succeeded': true,
            'ack_status': 'not_observed',
          })}\n';
          final size = utf8.encode(content).length;
          if (bytes + size > maxBytes) {
            incomplete = true;
            revoke('Size limit reached');
            return;
          }
          final file = File(p.join(_directory!.path, 'chunk_${_chunks++}.partial'));
          await file.writeAsString(content, flush: true);
          if (generation != _generation || !_active) {
            await file.delete();
            return;
          }
          await file.rename(p.setExtension(file.path, '.ndjson'));
          bytes += size;
          records += block.length;
          block = [];
          blockBytes = 0;
        }
        Future<void> add(String hex, int packetType, int? counter,
            int receivedAt, int? recTs, String disposition, String? reason) async {
          if (!_active || generation != _generation) return;
          if (!matches(hex, deviceFamily, packetType)) {
            if (deviceFamily == 'gen4' && packetType == 0x2f &&
                hex.toLowerCase().startsWith('2f0a')) unsupported++;
            return;
          }
          eligible++;
          final digest = sha256.convert(hexToBytes(hex)).toString();
          if (_seen.contains(digest)) { duplicates++; return; }
          if (bytes + blockBytes + hex.length + 2048 > maxBytes) {
            await flush();
            incomplete = true;
            revoke('Size limit reached');
            return;
          }
          final row = <String, Object?>{
            'kind': 'record', 'device_alias': _alias, 'payload_scope': 'inner',
            'inner_hex': hex, 'payload_bytes': hex.length ~/ 2,
            'payload_sha256': digest, 'packet_type': packetType,
            'record_type': 10, 'sequence_counter': counter,
            'received_at_epoch_ms': receivedAt,
            'record_ts_epoch_s': recTs,
            'timestamp_status': disposition == 'accepted' && recTs != null
                ? 'accepted' : 'untrusted',
            'disposition': disposition, 'archive_reason': reason,
            'context_observed_at_epoch_ms': _now().millisecondsSinceEpoch,
            'context': Map<String, Object?>.from(_context),
          };
          block.add(row);
          blockBytes += utf8.encode(jsonEncode(row)).length + 1;
          _seen.add(digest);
          if (block.length >= 32) await flush();
        }
        for (final raw in raws) {
          await add(raw.hex, raw.packetType, raw.counter, raw.capturedAt,
              raw.recTs, 'accepted', null);
          if (!_active || generation != _generation) break;
        }
        for (final raw in archives ?? <ArchiveRecord>[]) {
          if (!_active || generation != _generation) break;
          await add(raw.hex, raw.packetType, raw.counter, raw.capturedAt,
              raw.recTs, 'archived', raw.reason);
        }
        await flush();
        // Already retained chunks survive a later partial failure honestly.
        await _manifest();
        _changed();
      });
    } catch (_) {
      fail();
    }
  }

  Map<String, Object?> get manifest => {
    'schema_version': 1, 'tool': 'whoop4_r10_research',
    'device_alias': _alias, 'started_at_epoch_ms': _started?.millisecondsSinceEpoch,
    'expires_at_epoch_ms': _started?.add(lifetime).millisecondsSinceEpoch,
    'app_version': _appVersion, 'protocol_sha': r10ProtocolSha,
    'status': status, 'incomplete': incomplete || active || eligible > records + duplicates,
    'records_retained': records, 'eligible_observations': eligible,
    'duplicate_observations': duplicates, 'unsupported_length_or_encoding': unsupported,
    'raw_bytes_retained': bytes, 'max_raw_bytes': maxBytes,
    'context_truncated': contextTruncated, 'events': _events,
    'scope': 'foreground_safe_trim_callback_only',
    'excluded_paths': ['live', 'headless', 'pre_setup_direct_store'],
    'nominal_sample_rate_hz': 100, 'sample_rate_status': 'repository_reported',
    'ack_status': 'not_observed', 'cache_is_evictable': true,
    'firmware': null,
  };

  Future<void> _manifest() async {
    if (_directory == null) return;
    final file = File(p.join(_directory!.path, 'manifest.partial'));
    await file.writeAsString(jsonEncode(manifest), flush: true);
    await file.rename(p.join(_directory!.path, 'manifest.json'));
  }

  /// Serialize export with cleanup and writes; revocation can cancel export.
  Future<T> withStoppedSession<T>(Future<T> Function(Directory, Map<String, Object?>,
      bool Function()) operation) => _serial(() async {
    if (active || _directory == null || _started == null) {
      throw StateError('stop_capture_before_export');
    }
    if (_now().difference(_started!) >= const Duration(hours: 24)) {
      await _directory!.delete(recursive: true);
      _directory = null;
      throw StateError('research_expired');
    }
    final generation = _generation;
    await _manifest();
    return operation(_directory!, Map<String, Object?>.from(manifest),
        () => !_dead && generation == _generation);
  });

  Future<void> delete() async {
    revoke('Deleted');
    await _serial(() async {
      // Also deletes stale/unfinished sessions after a process restart.
      final root = _directory ?? await _root();
      if (await root.exists()) await root.delete(recursive: true);
      _directory = null;
      _started = null;
      records = bytes = eligible = duplicates = unsupported = 0;
      _seen.clear();
      _events.clear();
      _changed();
    });
  }

  /// Cleanup never enables capture or touches another cache namespace.
  Future<void> cleanupExpired() async {
    if (!enabled) return;
    await _serial(() async {
      final root = _directory ?? await _root();
      if (!await root.exists()) return;
      final info = File(p.join(root.path, 'manifest.json'));
      DateTime? date;
      try {
        final m = jsonDecode(await info.readAsString()) as Map;
        final ms = m['started_at_epoch_ms'] as int?;
        if (ms != null) date = DateTime.fromMillisecondsSinceEpoch(ms);
      } catch (_) { /* An interrupted session is aged by its directory. */ }
      date ??= (await root.stat()).modified;
      if (_now().difference(date) >= const Duration(hours: 24)) {
        revoke('Expired');
        await root.delete(recursive: true);
        _directory = null;
        _started = null;
      }
    });
  }

  @override
  void dispose() {
    revoke('Capture interrupted: owner disposed');
    _dead = true;
    super.dispose();
  }
}
