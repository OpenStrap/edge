import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'guide_catalogue.dart';
import 'help_screen.dart';

export 'guide_catalogue.dart' show GuideTopic;

/// The last item in a tab's scroll content, so Help never covers a card.
class HelpEntry extends StatelessWidget {
  final GuideTopic topic;
  const HelpEntry({super.key, required this.topic});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: S.x4),
    child: SizedBox(
      width: double.infinity,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: P.of(context).ink3,
          minimumSize: const Size(0, 48),
          textStyle: F.cap,
        ),
        onPressed: () {
          final band = bandGenerationOf(context.read<AppState>().paired);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => HelpScreen(topic: topic, band: band),
            ),
          );
        },
        child: Text(
          (AppLocalizations.of(context) ??
                  lookupAppLocalizations(const Locale('en')))
              .helpLookingForSomething,
        ),
      ),
    ),
  );
}
