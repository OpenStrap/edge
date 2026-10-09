import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _mount(WidgetTester tester, CoachConfig config) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<CoachConfig>.value(
      value: config,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: CoachSetup(key: UniqueKey()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _apiField => find.byType(DropdownButton<CoachApi>);

CoachApi? _selectedApi(WidgetTester tester) =>
    tester.widget<DropdownButton<CoachApi>>(_apiField).value;

Finder _textField(String label) => find.descendant(
  of: find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(OsTextField),
  ),
  matching: find.byType(TextField),
);

Future<void> _chooseApi(WidgetTester tester, CoachApi api) async {
  await tester.ensureVisible(_apiField);
  await tester.pumpAndSettle();
  await tester.tap(_apiField);
  await tester.pumpAndSettle();
  await tester.tap(
    find
        .text(api == CoachApi.responses ? 'Responses' : 'Chat Completions')
        .last,
  );
  await tester.pumpAndSettle();
}

Future<void> _preset(WidgetTester tester, String name) async {
  final scrollable = tester.state<ScrollableState>(
    find.byType(Scrollable).first,
  );
  scrollable.position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(name));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  await tester.ensureVisible(_textField(label));
  await tester.pumpAndSettle();
  await tester.enterText(_textField(label), value);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.ensureVisible(find.text('Save'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('every preset chooses its API without inspecting the model', (
    tester,
  ) async {
    final config = CoachConfig();
    addTearDown(config.dispose);
    await _mount(tester, config);
    expect(_selectedApi(tester), CoachApi.responses);

    for (final entry in {
      'Ollama': CoachApi.chatCompletions,
      'LM Studio': CoachApi.chatCompletions,
      'OpenAI': CoachApi.responses,
      'Anthropic': CoachApi.chatCompletions,
      'OpenRouter': CoachApi.chatCompletions,
    }.entries) {
      await _chooseApi(
        tester,
        entry.value == CoachApi.responses
            ? CoachApi.chatCompletions
            : CoachApi.responses,
      );
      await _preset(tester, entry.key);
      expect(_selectedApi(tester), entry.value, reason: entry.key);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a custom endpoint Responses override survives save and reopen', (
    tester,
  ) async {
    final config = CoachConfig();
    addTearDown(config.dispose);
    await config.save(
      baseUrl: 'https://provider.example/v1',
      model: 'my-provider-model',
    );
    await _mount(tester, config);
    expect(_selectedApi(tester), CoachApi.chatCompletions);

    await _chooseApi(tester, CoachApi.responses);
    await _save(tester);
    expect(config.api, CoachApi.responses);
    expect(config.model, 'my-provider-model');
    expect(config.apiBase, 'https://provider.example/v1');

    final restored = CoachConfig();
    addTearDown(restored.dispose);
    await restored.load();
    await _mount(tester, restored);
    expect(_selectedApi(tester), CoachApi.responses);
    expect(restored.apiBase, 'https://provider.example/v1');
    expect(restored.model, 'my-provider-model');
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing the base saves the default OpenAI Responses endpoint', (
    tester,
  ) async {
    final config = CoachConfig();
    addTearDown(config.dispose);
    await config.save(
      baseUrl: 'https://provider.example/v1',
      model: 'my-model',
    );
    await _mount(tester, config);
    expect(_selectedApi(tester), CoachApi.chatCompletions);

    await _enter(tester, 'Base URL', '');
    expect(_selectedApi(tester), CoachApi.responses);
    await _save(tester);
    expect(config.apiBase, CoachConfig.defaultBaseUrl);
    expect(config.api, CoachApi.responses);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an OpenAI Chat override survives path edits but resets by origin',
    (tester) async {
      final config = CoachConfig();
      addTearDown(config.dispose);
      await config.save(model: 'legacy-model', apiKey: 'placeholder-key');
      await _mount(tester, config);

      await _chooseApi(tester, CoachApi.chatCompletions);
      await _enter(tester, 'Base URL', 'https://api.openai.com/custom/v1/');
      expect(_selectedApi(tester), CoachApi.chatCompletions);
      expect(
        tester.widget<TextField>(_textField('API key')).controller?.text,
        'placeholder-key',
      );
      await _save(tester);
      expect(config.api, CoachApi.chatCompletions);
      expect(config.apiKey, 'placeholder-key');
      await config.load();
      expect(config.apiKey, 'placeholder-key');

      await _mount(tester, config);
      expect(_selectedApi(tester), CoachApi.chatCompletions);
      await _chooseApi(tester, CoachApi.responses);
      await _enter(tester, 'Base URL', 'https://provider.example/v1');
      expect(_selectedApi(tester), CoachApi.chatCompletions);
      expect(
        tester.widget<TextField>(_textField('API key')).controller?.text,
        '',
      );
      await _save(tester);
      expect(config.apiKey, isNull);
      await config.load();
      expect(config.apiKey, isNull);

      await _mount(tester, config);
      await _enter(tester, 'Base URL', 'https://api.openai.com/v1');
      expect(_selectedApi(tester), CoachApi.responses);
      expect(tester.takeException(), isNull);
    },
  );
}
