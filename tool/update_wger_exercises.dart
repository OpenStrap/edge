// Refresh lib/ui2/activity/wger_exercises.g.dart from wger's public API.
//
// This is a maintainer tool, never app code: Edge remains fully offline while
// browsing or logging exercises. Run from the repository root:
//
//   dart run tool/update_wger_exercises.dart
//
// The generated file intentionally excludes descriptions, notes, videos and
// images. They are not needed by the picker, substantially increase the
// shipped data, and carry attribution/content concerns of their own.

import 'dart:convert';
import 'dart:io';

const _source =
    'https://wger.de/api/v2/exerciseinfo/?limit=200&language__code=en';
const _licenseSource = 'https://wger.de/api/v2/license/?limit=100';
const _output = 'lib/ui2/activity/wger_exercises.g.dart';

// These wger records correspond to the original Edge catalogue. They stay out
// of the generated tail so a user's existing strength_set.exercise_key keeps
// resolving to the same stable key and the picker does not show duplicates.
const _legacySourceIds = <String>{
  '3717d144-7815-4a97-9a56-956fb889c996', // bench_press
  '57e17672-52b9-43cf-8d0d-4b3f06a0c0d0', // incline_db_press
  '5b4fb3ec-53a1-4525-a58a-c070798ea86e', // cable_fly
  'f4467e9a-9bb1-4e93-bec6-10a5d7738ffb', // overhead_press
  '6ebb138e-bb0a-402e-84e5-68fe0896e897', // triceps_pushdown
  'c5797bdf-1aa1-4d51-9775-c929ec5a2aaf', // overhead_extension
  '6ce25688-ae91-4dc7-9b17-0b66a47151fa', // barbell_row
  'fff05d7a-f374-4c8a-9885-39f49076918f', // lat_pulldown
  '8e420408-0682-4ab6-89f5-2681e54c7ce0', // pull_up
  '7b99a081-6b1a-4aa5-b86a-5a935d083a35', // barbell_curl
  '5d0e0a8b-1940-4034-b4ae-b965859f1ff0', // back_squat
  'd677de4c-5bd9-412a-91f1-857116a666a2', // front_squat
  'ee8e8db4-2d82-49e1-ab7f-891e9a354934', // deadlift
  '2e7ffff9-e603-4b28-98c8-31d1a6ce8cd9', // romanian_deadlift
  '19a289c0-33af-4055-bb34-3570c2975d3d', // hip_thrust
  '66a42396-c207-44da-bc75-758a89d32404', // leg_press
  'c9e57bbe-e839-44c6-861d-1c8dd2845e36', // plank
  '9b993e99-8701-43f0-84d6-689123183880', // hanging_leg_raise
};

const _languages = <int, String>{1: 'de', 2: 'en', 4: 'es', 12: 'fr', 24: 'zh'};

const _allowedLicenses = <String, String>{
  'CC-BY-SA 3': 'https://creativecommons.org/licenses/by-sa/3.0/deed.en',
  'CC-BY-SA 4': 'https://creativecommons.org/licenses/by-sa/4.0/deed.en',
  'CC0': 'http://creativecommons.org/publicdomain/zero/1.0/',
};

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

Future<void> main() async {
  final client = HttpClient()
    ..userAgent = 'OpenStrap exercise catalogue updater';
  try {
    final licenseRows = await _fetchAll(
      client,
      Uri.parse(_licenseSource),
      minimumCount: 1,
    );
    final licenses = <int, _License>{};
    for (final value in licenseRows) {
      final license = _License.fromJson((value as Map).cast<String, Object?>());
      if (licenses.putIfAbsent(license.id, () => license) != license) {
        throw StateError('Duplicate wger license id ${license.id}.');
      }
    }

    // Follow wger's pagination instead of assuming the growing catalogue will
    // remain below an arbitrary page size.
    final raw = await _fetchAll(client, Uri.parse(_source), minimumCount: 800);

    final rows = <_Exercise>[];
    for (final value in raw) {
      final map = (value as Map).cast<String, Object?>();
      final row = _Exercise.fromJson(map, licenses);
      if (_legacySourceIds.contains(row.uuid)) continue;
      rows.add(row);
    }
    rows.sort((a, b) {
      final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byName != 0 ? byName : a.uuid.compareTo(b.uuid);
    });

    final duplicateKeys = <String>{};
    final seenKeys = <String>{};
    for (final row in rows) {
      if (!seenKeys.add(row.key)) duplicateKeys.add(row.key);
    }
    if (duplicateKeys.isNotEmpty) {
      throw StateError('Duplicate generated keys: $duplicateKeys');
    }

    // strength_set stores the stable key, not a copied display label. If an
    // upstream record disappears, silently dropping it here would turn old
    // workouts into a raw `wger:<uuid>` identifier. Stop the refresh so the
    // maintainer can preserve that record as a retired/tombstoned definition.
    final previousIds = await _existingSourceIds();
    final currentIds = {for (final row in rows) row.uuid};
    final removedIds = previousIds.difference(currentIds).toList()..sort();
    if (removedIds.isNotEmpty) {
      throw StateError(
        'Refusing to orphan existing strength history. Preserve these removed '
        'wger records as retired definitions before refreshing: $removedIds',
      );
    }

    final sink = StringBuffer()
      ..writeln('// GENERATED FILE — DO NOT EDIT.')
      ..writeln('// Refresh with: dart run tool/update_wger_exercises.dart')
      ..writeln('// Source: $_source')
      ..writeln('//')
      ..writeln('// Base data and translations retain their Creative Commons')
      ..writeln('// credits. See NOTICE.md and docs/notice.html.')
      ..writeln()
      ..writeln("part of 'catalogue.dart';")
      ..writeln()
      ..writeln('const _wgerExerciseLibrary = <ExerciseDef>[');
    for (final row in rows) {
      sink
        ..writeln('  ExerciseDef(')
        ..writeln('    ${_dart(row.key)},')
        ..writeln('    ${_dart(row.label)},')
        ..writeln('    ${_dart(row.primaryMuscles)},')
        ..writeln('    secondaryMuscles: ${_dart(row.secondaryMuscles)},')
        ..writeln('    category: ${_dart(row.category)},')
        ..writeln('    equipment: ${_dart(row.equipment)},')
        ..writeln('    aliases: ${_dart(row.aliases)},')
        ..writeln('    localizedLabels: ${_dart(row.localizedLabels)},')
        ..writeln('    sourceId: ${_dart(row.uuid)},')
        ..writeln('    sourceUpdatedAt: ${_dart(row.updatedAt)},')
        ..writeln('    sourceCredits: [');
      for (final credit in row.credits) {
        sink.writeln(
          '      ExerciseCredit(${_dart(credit.licenseName)}, '
          '${_dart(credit.licenseUrl)}, ${_dart(credit.author)}),',
        );
      }
      sink
        ..writeln('    ],')
        ..writeln('  ),');
    }
    sink.writeln('];');
    await File(_output).writeAsString(sink.toString());
    final formatted = await Process.run(Platform.resolvedExecutable, [
      'format',
      _output,
    ]);
    if (formatted.exitCode != 0) {
      throw StateError('dart format failed: ${formatted.stderr}');
    }
    stdout.writeln('Wrote ${rows.length} wger exercises to $_output.');
  } finally {
    client.close(force: true);
  }
}

Future<Set<String>> _existingSourceIds() async {
  final file = File(_output);
  if (!await file.exists()) return {};
  final source = await file.readAsString();
  final ids = {
    for (final match in RegExp(
      r'^\s+sourceId: "([0-9a-f-]{36})",$',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(source))
      match.group(1)!.toLowerCase(),
  };
  if (source.contains('const _wgerExerciseLibrary') && ids.isEmpty) {
    throw StateError('Could not read source IDs from the existing snapshot.');
  }
  return ids;
}

Future<List<Object?>> _fetchAll(
  HttpClient client,
  Uri firstPage, {
  required int minimumCount,
}) async {
  final rows = <Object?>[];
  int? expectedCount;
  Uri? next = firstPage;
  var pages = 0;
  while (next != null) {
    if (next.scheme != 'https' || next.host != 'wger.de') {
      throw StateError('Refusing an unexpected wger pagination URL: $next');
    }
    if (++pages > 100) throw StateError('wger pagination did not terminate.');

    final request = await client.getUrl(next);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'wger returned HTTP ${response.statusCode}',
        uri: next,
      );
    }
    final body = await utf8.decoder.bind(response).join();
    final decoded = (jsonDecode(body) as Map).cast<String, Object?>();
    final count = (decoded['count'] as num?)?.toInt();
    if (count == null || count < minimumCount) {
      throw StateError(
        'Expected at least $minimumCount wger rows; API reported $count.',
      );
    }
    expectedCount ??= count;
    if (count != expectedCount) {
      throw StateError(
        'wger changed while paging: expected $expectedCount rows, now $count.',
      );
    }
    final page = decoded['results'];
    if (page is! List) throw FormatException('wger page has no results list.');
    rows.addAll(page);

    final nextValue = decoded['next'];
    if (nextValue == null) {
      next = null;
    } else if (nextValue is String) {
      next = Uri.parse(nextValue);
    } else {
      throw FormatException('wger returned a non-string next page URL.');
    }
  }
  if (rows.length != expectedCount) {
    throw StateError(
      'Incomplete wger pagination: expected $expectedCount rows, '
      'received ${rows.length}.',
    );
  }
  return rows;
}

// JSON string syntax is almost Dart string syntax. The important exception is
// `$`, which Dart would interpret as interpolation if a future upstream label
// contains one.
String _dart(Object? value) => jsonEncode(value).replaceAll(r'$', r'\$');

String _clean(Object? value) =>
    (value as String? ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');

List<String> _strings(Iterable<Object?> values) {
  final out = <String>{};
  for (final value in values) {
    final clean = _clean(value);
    if (clean.isNotEmpty) out.add(clean);
  }
  return out.toList()..sort((a, b) => a.compareTo(b));
}

class _Exercise {
  const _Exercise({
    required this.uuid,
    required this.label,
    required this.localizedLabels,
    required this.aliases,
    required this.primaryMuscles,
    required this.secondaryMuscles,
    required this.category,
    required this.equipment,
    required this.updatedAt,
    required this.credits,
  });

  final String uuid;
  final String label;
  final Map<String, String> localizedLabels;
  final List<String> aliases;
  final List<String> primaryMuscles;
  final List<String> secondaryMuscles;
  final String category;
  final List<String> equipment;
  final String updatedAt;
  final List<_Credit> credits;

  String get key => 'wger:$uuid';

  factory _Exercise.fromJson(
    Map<String, Object?> map,
    Map<int, _License> licenses,
  ) {
    final uuid = _clean(map['uuid']).toLowerCase();
    if (!_uuid.hasMatch(uuid)) {
      throw FormatException('Exercise has an invalid UUID: $uuid');
    }
    final baseLicense = _License.fromJson(
      ((map['license'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final credits = <String, _Credit>{};

    void addCredit(_License license, Object? authorValue) {
      final expectedUrl = _allowedLicenses[license.name];
      if (expectedUrl == null || license.url != expectedUrl) {
        throw FormatException(
          'Exercise $uuid has unreviewed license '
          '"${license.name}" (${license.url}).',
        );
      }
      final author = _clean(authorValue);
      final credit = _Credit(license.name, license.url, author);
      credits.putIfAbsent(
        jsonEncode([credit.licenseName, credit.licenseUrl, credit.author]),
        () => credit,
      );
    }

    // Muscles, category and equipment belong to the base exercise.
    addCredit(baseLicense, map['license_author']);
    final translations = ((map['translations'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, Object?>())
        .toList();
    final labels = <String, String>{};
    final aliases = <Object?>[];
    for (final translation in translations) {
      final language = (translation['language'] as num?)?.toInt();
      final code = _languages[language];
      if (code == null) continue;
      final name = _clean(translation['name']);
      if (name.isNotEmpty) {
        final previous = labels[code];
        if (previous != null && previous != name) {
          throw FormatException(
            'Exercise $uuid has two different $code labels.',
          );
        }
        labels[code] = name;
      }
      var usesTranslation = name.isNotEmpty;
      for (final alias in (translation['aliases'] as List?) ?? const []) {
        if (alias is! Map) continue;
        final value = _clean(alias['alias']);
        if (value.isEmpty) continue;
        aliases.add(value);
        usesTranslation = true;
      }
      if (usesTranslation) {
        final licenseId = (translation['license'] as num?)?.toInt();
        final license = licenses[licenseId];
        if (license == null) {
          throw FormatException(
            'Exercise $uuid has an unknown $code translation license '
            'id $licenseId.',
          );
        }
        addCredit(license, translation['license_author']);
      }
    }
    final english = labels['en'];
    if (english == null || english.isEmpty) {
      throw FormatException('Exercise has no English label: $map');
    }

    List<String> names(String field) => _strings(
      ((map[field] as List?) ?? const []).whereType<Map>().map(
        (m) => m['name_en'] ?? m['name'],
      ),
    );

    final sortedLabels = Map<String, String>.fromEntries(
      labels.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final sortedCredits = credits.values.toList()
      ..sort((a, b) {
        final byLicense = a.licenseName.compareTo(b.licenseName);
        if (byLicense != 0) return byLicense;
        final byAuthor = a.author.compareTo(b.author);
        return byAuthor != 0 ? byAuthor : a.licenseUrl.compareTo(b.licenseUrl);
      });
    return _Exercise(
      uuid: uuid,
      label: english,
      localizedLabels: Map.unmodifiable(sortedLabels),
      aliases: _strings(aliases),
      primaryMuscles: names('muscles'),
      secondaryMuscles: names('muscles_secondary'),
      category: _clean((map['category'] as Map?)?['name']),
      equipment: _strings(
        ((map['equipment'] as List?) ?? const []).whereType<Map>().map(
          (e) => e['name'],
        ),
      ),
      updatedAt: _clean(map['last_update_global'] ?? map['last_update']),
      credits: List.unmodifiable(sortedCredits),
    );
  }
}

class _License {
  const _License(this.id, this.name, this.url);

  final int id;
  final String name;
  final String url;

  factory _License.fromJson(Map<String, Object?> map) {
    final id = (map['id'] as num?)?.toInt();
    final name = _clean(map['short_name']);
    final url = _clean(map['url']);
    if (id == null || name.isEmpty || url.isEmpty) {
      throw FormatException('Incomplete wger license: $map');
    }
    return _License(id, name, url);
  }
}

class _Credit {
  const _Credit(this.licenseName, this.licenseUrl, this.author);

  final String licenseName;
  final String licenseUrl;
  final String author;
}
