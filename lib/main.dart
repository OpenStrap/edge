import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_controller.dart';
import 'auth/auth_screens.dart';
import 'screens/main_shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: WTheme.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: WhoopsieApp()));
}

class WhoopsieApp extends StatelessWidget {
  const WhoopsieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'whoopsie',
      debugShowCheckedModeBanner: false,
      theme: WTheme.buildDark(),
      home: const _RootRouter(),
    );
  }
}

class _RootRouter extends ConsumerWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: switch (auth.stage) {
        AuthStage.unknown => const _Splash(),
        AuthStage.signedOut => const EmailScreen(),
        AuthStage.awaitingCode => const CodeScreen(),
        AuthStage.signedIn => const MainShell(),
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(color: WTheme.accent),
              ),
              SizedBox(height: 24),
              Text('whoopsie',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: WTheme.accent,
                      letterSpacing: 1.5)),
            ],
          ),
        ),
      );
}
