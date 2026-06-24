// Broadcast HR — re-broadcast the band's live heart rate as a standard Bluetooth
// HR monitor so a bike computer (Wahoo/Garmin) or gym machine can read it.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class BroadcastHrScreen extends StatelessWidget {
  const BroadcastHrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final on = app.isBroadcastingHr;
    final hr = app.liveHrBpm;
    final subs = app.hrBroadcastSubscribers;
    final connected = app.isConnected;

    return Scaffold(
      appBar: AppBar(title: const Text('Broadcast HR')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x6, Sp.screen, Sp.x6),
        children: [
          Text('Use your band as a\nheart-rate sensor.', style: AppText.display),
          const SizedBox(height: Sp.x4),
          Text(
            "Your phone re-broadcasts the band's live heart rate as a standard "
            'Bluetooth HR monitor. Pair "OpenStrap HR" on your bike computer, '
            'treadmill, or gym machine — just like a chest strap.',
            style: AppText.bodySoft,
          ),
          const SizedBox(height: Sp.x6),

          ProCard(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('Live heart rate', style: AppText.title),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        AppIcon(Ic.heart,
                            size: 22,
                            color: on ? AppColors.coralDeep : AppColors.inkSoft),
                        const SizedBox(width: Sp.x2),
                        Text(hr > 0 ? '$hr' : '—',
                            style: AppText.display.copyWith(
                                color:
                                    on ? AppColors.coralDeep : AppColors.inkSoft)),
                        const SizedBox(width: 4),
                        Text('bpm', style: AppText.caption),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x4),
                Container(height: 1, color: AppColors.divider),
                const SizedBox(height: Sp.x4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(on ? 'Broadcasting' : 'Off',
                        style: AppText.bodySoft.copyWith(
                            color: on ? AppColors.good : AppColors.inkSoft)),
                    Text(
                      on
                          ? (subs > 0
                              ? '$subs device${subs == 1 ? '' : 's'} connected'
                              : 'waiting for a device…')
                          : '',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x6),

          if (!connected)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.x4),
              child: Text('Connect to your strap first.',
                  style: AppText.caption.copyWith(color: AppColors.warn)),
            ),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: connected
                  ? () async {
                      try {
                        if (on) {
                          await app.stopHrBroadcast();
                        } else {
                          await app.startHrBroadcast();
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$e')));
                        }
                      }
                    }
                  : null,
              child: Text(on ? 'Stop broadcasting' : 'Start broadcasting'),
            ),
          ),
          const SizedBox(height: Sp.x6),

          ProCard(
            color: AppColors.coralSoft,
            shadow: const [],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('On your bike computer', style: AppText.title),
                const SizedBox(height: Sp.x3),
                Text(
                  '1.  Keep this screen open and the band connected.\n'
                  '2.  On the Wahoo / Garmin: add a new Heart Rate sensor.\n'
                  '3.  Pair with "OpenStrap HR".\n'
                  '4.  Your live HR shows on the head unit.',
                  style: AppText.bodySoft,
                ),
                const SizedBox(height: Sp.x3),
                Text(
                  'iOS pauses Bluetooth broadcasting in the background — keep the '
                  'app open (screen on) during your ride for a stable signal.',
                  style: AppText.caption.copyWith(color: AppColors.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
