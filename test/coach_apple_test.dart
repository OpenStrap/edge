import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_apple.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/screens/ai_briefing.dart' show SentPayload;
import 'package:openstrap_edge/ui2/screens/ecg.dart' show ecgAnalyzePrompt;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _channel = MethodChannel('openstrap/apple_ai');

/// Answers `respond` with [handler] and records the arguments it was given.
Map<String, dynamic>? _lastArgs;
void _mockRespond(Future<Object?> Function() handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method != 'respond') return 'available';
    _lastArgs = (call.arguments as Map).cast<String, dynamic>();
    return handler();
  });
}

Map<String, dynamic> _coachBody(String question) => {
      'messages': [
        {'role': 'system', 'content': 'long tool-driven rules'},
        {'role': 'user', 'content': question},
      ],
      'tools': [
        {'type': 'function'},
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one question goes through as it is', () {
    expect(
        AppleOnDevice.buildPrompt([
          {'role': 'system', 'content': 'rules'},
          {'role': 'user', 'content': 'How did I sleep?'},
        ]),
        'How did I sleep?');
  });

  test('a chat keeps the latest question whole and drops tool traffic', () {
    final p = AppleOnDevice.buildPrompt([
      {'role': 'user', 'content': 'first ' * 2000},
      {'role': 'assistant', 'content': 'an answer'},
      {'role': 'tool', 'content': 'SECRET ROWS'},
      {'role': 'user', 'content': 'And today?'},
    ]);
    expect(p.endsWith('Now: And today?'), isTrue);
    expect(p.contains('SECRET ROWS'), isFalse);
    expect(p.length, lessThanOrEqualTo(AppleOnDevice.promptBudget + 40));
  });

  test('choosing Apple needs no key and counts as on-device', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.configured, isFalse);
    await cfg.save(useApple: true);
    expect(cfg.usesApple, isTrue);
    expect(cfg.configured, isTrue);
    expect(cfg.remindersConfigured, isTrue);
    expect(cfg.isPrivateEndpoint, isTrue);
    expect(cfg.usesChatGpt, isFalse);
    expect(cfg.model, kAppleOnDeviceModel);
    final again = CoachConfig();
    await again.load();
    expect(again.usesApple, isTrue);
  });

  test('a saved Apple choice is ignored off iPhone', () async {
    SharedPreferences.setMockInitialValues({});
    final cfg = CoachConfig();
    await cfg.load();
    await cfg.save(useApple: true);
    expect(cfg.usesApple, isFalse);
  });

  test('a restored Apple choice off iPhone leaves the saved provider in charge',
      () async {
    SharedPreferences.setMockInitialValues({
      'coach_use_apple': true,
      'coach_base_url': 'https://api.example.com/v1',
      'coach_model': 'gpt-x',
    });
    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.usesApple, isFalse);
    expect(cfg.apiBase, isNot(kAppleOnDeviceBase));
    expect(cfg.model, 'gpt-x');
    expect(cfg.isPrivateEndpoint, isFalse);
    expect(cfg.isLocalEndpoint, isFalse);
    expect(cfg.configured, isFalse, reason: 'no key for the saved endpoint');
    expect(cfg.remindersConfigured, isFalse);
  });

  test('Apple on keeps the saved ChatGPT route and model for switching back',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({
      'coach_use_chatgpt': true,
      'coach_model': 'gpt-5',
    });
    final cfg = CoachConfig();
    await cfg.load();
    await cfg.save(useApple: true);
    expect(cfg.usesChatGpt, isFalse);
    expect(cfg.model, kAppleOnDeviceModel);
    expect(cfg.savedUsesChatGpt, isTrue);
    expect(cfg.savedModel, 'gpt-5');
    await cfg.save(useApple: false);
    expect(cfg.usesChatGpt, isTrue);
    expect(cfg.model, 'gpt-5');
  });

  test('the briefing disclosure counts Apple on-device as local', () {
    expect(SentPayload.isLocal(kAppleOnDeviceBase), isTrue);
    expect(SentPayload.isLocal('https://api.openai.com/v1'), isFalse);
  });

  test('non-Latin text is budgeted more tightly than Latin', () {
    expect(AppleOnDevice.cost('abc'), 3);
    expect(AppleOnDevice.cost('สวัสดี'), 6 * 4);
    final p = AppleOnDevice.buildPrompt([
      {'role': 'user', 'content': 'นอนหลับ' * 2000},
      {'role': 'assistant', 'content': '你好' * 500},
      {'role': 'user', 'content': 'วันนี้ล่ะ?'},
    ]);
    expect(p.endsWith('Now: วันนี้ล่ะ?'), isTrue);
    expect(AppleOnDevice.cost(p),
        lessThanOrEqualTo(AppleOnDevice.promptBudget + 40));
    expect(p.runes.length, lessThan(AppleOnDevice.promptBudget ~/ 3));
  });

  test('native error codes become translatable messages', () {
    expect(AppleOnDevice.errorMessage('tooLong'), kAppleTooLongMessage);
    expect(AppleOnDevice.errorMessage('declined'), kAppleDeclinedMessage);
    expect(AppleOnDevice.errorMessage('timeout'), kAppleTimeoutMessage);
    expect(AppleOnDevice.errorMessage('notEnabled'),
        AppleAiStatus.notEnabled.message);
    expect(AppleOnDevice.errorMessage('anything else'), kAppleFailedMessage);
  });

  group('reply over the channel', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      AppleOnDevice.respondTimeout = const Duration(seconds: 75);
      _lastArgs = null;
    });

    test('an ECG analysis is refused, not answered without the waveform',
        () async {
      _mockRespond(() async => 'an answer');
      await expectLater(
        AppleOnDevice.reply(_coachBody(ecgAnalyzePrompt('r1'))),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', kAppleNoEcgMessage)),
      );
      expect(_lastArgs, isNull, reason: 'the model was never asked');
    });

    test('a bridge that never answers times out with a clear message',
        () async {
      AppleOnDevice.respondTimeout = const Duration(milliseconds: 50);
      _mockRespond(() => Completer<Object?>().future);
      await expectLater(
        AppleOnDevice.reply({
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', kAppleTimeoutMessage)),
      );
    });

    test('a native error code reaches the user as its message', () async {
      _mockRespond(() async =>
          throw PlatformException(code: 'tooLong', message: 'detail'));
      await expectLater(
        AppleOnDevice.reply({
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', kAppleTooLongMessage)),
      );
    });

    test('an empty answer is an error, not a blank reply', () async {
      _mockRespond(() async => '   ');
      await expectLater(
        AppleOnDevice.reply({
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('snapshot', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_coach_apple_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });
    tearDownAll(() async {
      await CoachDb.close();
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });
    setUp(() async {
      final db = await LocalDb.instance;
      await db.delete('metric_series');
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      _lastArgs = null;
    });

    Future<void> seed(Map<String, num> readinessByDay) async {
      final db = await LocalDb.instance;
      for (final e in readinessByDay.entries) {
        await db.insert('metric_series',
            {'date': e.key, 'key': 'readiness', 'value': e.value});
      }
    }

    Future<String> instructionsFor(({String day, num? readiness}) today) async {
      _mockRespond(() async => 'ok');
      await AppleOnDevice.reply(_coachBody('How am I today?'),
          today: () async => today);
      return _lastArgs!['instructions'] as String;
    }

    test('TODAY is today, with the headline readiness, never a stale row',
        () async {
      // Today's stored readiness is a mid-sync partial (80); Home shows 77.
      await seed({'2026-03-10': 80, '2026-03-09': 60});
      final ins =
          await instructionsFor((day: '2026-03-10', readiness: 77));
      final todayLine =
          ins.split('\n').firstWhere((l) => l.startsWith('TODAY'));
      expect(todayLine, contains('2026-03-10'));
      expect(todayLine, contains('77'));
      expect(todayLine, isNot(contains('80')));
    });

    test('no row for today says so instead of using yesterday', () async {
      await seed({'2026-03-09': 60});
      final ins =
          await instructionsFor((day: '2026-03-10', readiness: null));
      final todayLine =
          ins.split('\n').firstWhere((l) => l.startsWith('TODAY'));
      expect(todayLine, contains('no data for today yet'));
      expect(todayLine, isNot(contains('2026-03-09')));
    });

    test('the week averages follow calendar days across gaps and DST',
        () async {
      // Gaps in both weeks, a DST change (US, 2026-03-08) inside the window,
      // and an old row that 14-newest-rows would have pulled in.
      await seed({
        '2026-03-10': 50, '2026-03-08': 50, '2026-03-04': 50, // last 7 days
        '2026-03-03': 70, '2026-02-28': 70, '2026-02-25': 70, // the 7 before
        '2026-02-01': 10, // outside the 14 days
      });
      final ins =
          await instructionsFor((day: '2026-03-10', readiness: 50));
      final weekLine =
          ins.split('\n').firstWhere((l) => l.startsWith('THE WEEK'));
      expect(weekLine, contains('last 7 days'));
      expect(weekLine, contains('the 7 days before'));
      expect(weekLine, contains('50'));
      expect(weekLine, contains('70'));
      expect(weekLine, isNot(contains('10')));
      expect(ins, isNot(contains('2026-02-01')));
    });
  });
}
