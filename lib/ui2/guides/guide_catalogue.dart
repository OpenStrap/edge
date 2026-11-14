// GUIDE CATALOGUE (phase 3): which guides the Help list offers, grouped by
// topic and filtered by the user's band.
//
// The contract is in the doc comments and pinned by
// test/ui2/guide_catalogue_test.dart.

import '../../sync/paired_device.dart' show PairedDevice;
import 'guide.dart';
import 'guide_add_nap.dart';
import 'guide_alarm_schedule.dart';
import 'guide_delete_workout.dart';
import 'guide_fix_sleep_times.dart';
import 'guide_heart_rate_zones.dart';
import 'guide_log_past_workout.dart';
import 'guide_remove_detected.dart';
import 'guide_start_stop_workout.dart';

/// Where a guide starts: the tab its first step is on. Declaration order is
/// the order the Help list shows the groups in (the tab bar's order).
enum GuideTopic { today, sleep, activity, health }

/// One guide in the Help list and the topic it is filed under.
class GuideEntry {
  final GuideTopic topic;
  final Guide guide;
  const GuideEntry(this.topic, this.guide);
}

/// The guides of one topic, in catalogue order. Never empty.
class GuideTopicGroup {
  final GuideTopic topic;
  final List<GuideEntry> entries;
  const GuideTopicGroup(this.topic, this.entries);
}

/// Every shipped guide, in the order the list shows them within a topic.
/// Guide #1 (heart-rate zones) and #2-#8.
List<GuideEntry> get kGuideCatalogue => [
      GuideEntry(GuideTopic.today, heartRateZonesGuide),
      GuideEntry(GuideTopic.sleep, alarmScheduleGuide),
      GuideEntry(GuideTopic.sleep, addNapGuide),
      GuideEntry(GuideTopic.today, removeDetectedGuide),
      GuideEntry(GuideTopic.sleep, fixSleepTimesGuide),
      GuideEntry(GuideTopic.activity, deleteWorkoutGuide),
      GuideEntry(GuideTopic.activity, startStopWorkoutGuide),
      GuideEntry(GuideTopic.activity, logPastWorkoutGuide),
    ];

/// The groups to show for [band]: topics in [GuideTopic] order, empty topics
/// left out, entries in [entries] order.
///
/// A known band keeps a guide when [Guide.variantFor] finds a variant for it
/// (an exact-band variant or an "any" one); a guide with nothing for that band
/// is left out. An unknown band (`null`: nothing paired yet) keeps EVERY guide
/// (default D3: someone who has not paired yet is exactly who asks how to pair;
/// a band-specific guide opened then says which bands it covers).
///
/// CLAIM(help-filter): a guide is listed iff it can be shown for the band
/// [guide_catalogue_test 'variant filtering'].
List<GuideTopicGroup> helpGroups(List<GuideEntry> entries, BandGeneration? band) {
  bool listed(GuideEntry e) => band == null || e.guide.variantFor(band) is GuideVariantFound;
  return [
    for (final topic in GuideTopic.values)
      if ([for (final e in entries) if (e.topic == topic && listed(e)) e] case final inTopic when inTopic.isNotEmpty)
        GuideTopicGroup(topic, inTopic),
  ];
}

/// The WHOOP generation of the paired band: `gen4` -> [BandGeneration.whoop4],
/// `gen5` -> [BandGeneration.whoop5]; no band, a band whose generation has
/// not been identified yet, or anything else -> null (never a guess).
BandGeneration? bandGenerationOf(PairedDevice? paired) => switch (paired?.generation) {
      'gen4' => BandGeneration.whoop4,
      'gen5' => BandGeneration.whoop5,
      _ => null,
    };
