import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/theme.dart';

void main() {
  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    ShellDomain initial = ShellDomain.home,
    ValueChanged<ShellDomain>? onSelect,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.android),
        home: AppShell(
          initial: initial,
          onSelect: onSelect,
          builder: (_, domain) => _TestTab(domain: domain),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, ShellDomain domain) async {
    await tester.tap(find.text(domain.label));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  bool exited() =>
      platformCalls.any((call) => call.method == 'SystemNavigator.pop');

  testWidgets('Android Back returns through visited tabs before exiting', (
    tester,
  ) async {
    final selected = <ShellDomain>[];
    await mount(tester, onSelect: selected.add);
    await select(tester, ShellDomain.health);
    await select(tester, ShellDomain.workout);

    await back(tester);
    expect(find.text('screen Health'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
    expect(exited(), isFalse);
    expect(selected, [
      ShellDomain.health,
      ShellDomain.workout,
      ShellDomain.health,
      ShellDomain.home,
    ], reason: 'Back must also update the tab persisted by the host');

    await back(tester);
    expect(exited(), isTrue);
  });

  testWidgets('re-tapping a tab does not add another Back step', (
    tester,
  ) async {
    final selected = <ShellDomain>[];
    await mount(tester, onSelect: selected.add);
    await select(tester, ShellDomain.health);
    await select(tester, ShellDomain.health);
    expect(selected, [ShellDomain.health, ShellDomain.health]);

    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(exited(), isTrue);
  });

  testWidgets('switching back and forth does not lengthen the way out', (
    tester,
  ) async {
    await mount(tester);
    for (var i = 0; i < 5; i++) {
      await select(tester, ShellDomain.health);
      await select(tester, ShellDomain.workout);
    }
    await back(tester);
    expect(find.text('screen Health'), findsOneWidget);
    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(exited(), isTrue);
  });

  testWidgets('leaving Home again keeps Home as the last stop before exit', (
    tester,
  ) async {
    await mount(tester);
    await select(tester, ShellDomain.health);
    await select(tester, ShellDomain.home);
    await select(tester, ShellDomain.workout);
    await back(tester);
    expect(find.text('screen Health'), findsOneWidget);
    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(exited(), isTrue);
  });

  testWidgets('a deliberate return to Home keeps the previous tab in history', (
    tester,
  ) async {
    await mount(tester);
    await select(tester, ShellDomain.health);
    await select(tester, ShellDomain.home);
    await back(tester);
    expect(find.text('screen Health'), findsOneWidget);
    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(exited(), isTrue);
  });

  for (final domain in ShellDomain.values.where((d) => d != ShellDomain.home)) {
    testWidgets('a launch on ${domain.label} returns to Home before exiting', (
      tester,
    ) async {
      await mount(tester, initial: domain);
      await back(tester);
      expect(find.text('screen Home'), findsOneWidget);
      expect(exited(), isFalse);
      await back(tester);
      expect(exited(), isTrue);
    });
  }

  testWidgets('a pushed detail screen closes before tab history is consumed', (
    tester,
  ) async {
    await mount(tester);
    await select(tester, ShellDomain.health);
    final context = tester.element(find.text('screen Health'));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('detail screen')),
      ),
    );
    await tester.pumpAndSettle();

    await back(tester);
    expect(find.text('detail screen'), findsNothing);
    expect(find.text('screen Health'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
  });

  testWidgets('a dialog closes before tab history is consumed', (tester) async {
    await mount(tester);
    await select(tester, ShellDomain.health);
    showDialog<void>(
      context: tester.element(find.text('screen Health')),
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();

    await back(tester);
    expect(find.text('dialog'), findsNothing);
    expect(find.text('screen Health'), findsOneWidget);
    expect(exited(), isFalse);
    await back(tester);
    expect(find.text('screen Home'), findsOneWidget);
  });

  testWidgets('Back preserves the state of a previously visited tab', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('increment Home'));
    await tester.pump();
    await select(tester, ShellDomain.health);
    await back(tester);
    expect(find.text('Home count 1'), findsOneWidget);
  });
}

class _TestTab extends StatefulWidget {
  final ShellDomain domain;
  const _TestTab({required this.domain});

  @override
  State<_TestTab> createState() => _TestTabState();
}

class _TestTabState extends State<_TestTab> {
  int count = 0;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('screen ${widget.domain.label}'),
      Text('${widget.domain.label} count $count'),
      TextButton(
        onPressed: () => setState(() => count++),
        child: Text('increment ${widget.domain.label}'),
      ),
    ],
  );
}
