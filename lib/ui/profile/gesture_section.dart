// Gesture settings — maps a band double-tap to an action. Only offers actions the
// current platform actually supports (from native capabilities); falls back to a
// "nothing available yet" note otherwise. Same card/sheet idiom as the rest of
// Profile (design-system SurfaceCard + ListRow).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../gestures/device_action.dart';
import '../../gestures/gesture_settings.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class GestureSettingsCard extends StatelessWidget {
  const GestureSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppState>().gestureSettings;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return SurfaceCard(
          padding:
              const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
          onTap: () => _pick(context, settings),
          child: ListRow(
            icon: OsIcon.wear,
            iconColor: AppColors.accent,
            title: 'Double-tap your band',
            subtitle: settings.doubleTap.label,
            trailing:
                AppIcon(OsIcon.arrowRight, size: 16, color: AppColors.onSurfaceFaint),
          ),
        );
      },
    );
  }

  void _pick(BuildContext context, GestureSettings settings) {
    final options =
        DeviceAction.values.where((a) => settings.supported.contains(a)).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, Sp.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Double-tap action', style: AppText.h2),
                const SizedBox(height: 4),
                Text('What happens when you double-tap the band.',
                    style: AppText.captionMuted),
                const SizedBox(height: Sp.x4),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ...options.map((a) {
                          final selected = a == settings.doubleTap;
                          return ListRow(
                            title: a.label,
                            subtitle: a.blurb,
                            trailing: selected
                                ? AppIcon(OsIcon.check, size: 20, color: AppColors.positive)
                                : const SizedBox(width: 20),
                            onTap: () {
                              settings.setDoubleTap(a);
                              Navigator.of(sheetCtx).pop();
                            },
                          );
                        }),
                        if (options.length <= 1) ...[
                          const SizedBox(height: Sp.x3),
                          Text('No band actions are available on this device yet.',
                              style: AppText.caption),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
