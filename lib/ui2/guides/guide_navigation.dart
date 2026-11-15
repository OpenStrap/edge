// GuideNavigation owns the declared navigation tree, not the app's navigation
// state. Location is read from mounted page identities even while data loads.
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../app_shell.dart' show AppShell;
import '../grammar.dart' show SubTabs;
import '../screens/metric_detail.dart' show MetricDetail;
import 'guide_target.dart';
import 'guide_labels.dart';
import 'tree_geometry.dart';

enum GuideNode {
  today,
  sleep,
  activity,
  activityOverview,
  activityActivities,
  activityHistory,
  health,
  healthOverview,
  healthExplore,
  healthTrends,
  healthVitals,
  healthLabs,
  settings,
  dayStrain,
  zones,
  naps,
  alarm,
  review,
  picker,
  setup,
  live,
  logWorkout,
  workoutSummary,
  daySteps,
  dayTimeline,
  recovery,
  stress,
  journal,
  nutrition,
  nutritionLog,
  coach,
  coachSetup,
  circadian,
  sleepDebt,
  sleepConsistency,
  sleepNeed,
  sleepRegularity,
  beats,
  ecg,
  ecgCapture,
  ecgDetail,
  breathing,
  investigate,
  findings,
  drivers,
  whatChanged,
  month,
  advanced,
  profile,
  devices,
  deviceDetail,
  bandGestures,
  bandNotifications,
  phoneImport,
  reportIssue,
  help,
  metric,
}

enum GuideHopKind { back, tab, subTab, page }

class GuideHop {
  final GuideNode node;
  final GuideHopKind kind;
  const GuideHop(this.node, this.kind);
}

class GuideDestination {
  final GuideNode? parent;
  final List<String> screens;
  const GuideDestination(this.parent, [this.screens = const []]);
}

/// Canonical entry paths. The root Navigator still owns actual pushed history:
/// unknown routes return through its Back control, never a forced pop.
const guideNavigationTree = <GuideNode, GuideDestination>{
  GuideNode.today: GuideDestination(null, ['HomeScreen']),
  GuideNode.sleep: GuideDestination(null, ['SleepTab', 'SleepDetail']),
  GuideNode.activity: GuideDestination(null, ['WorkoutScreen']),
  GuideNode.activityOverview: GuideDestination(GuideNode.activity),
  GuideNode.activityActivities: GuideDestination(GuideNode.activity),
  GuideNode.activityHistory: GuideDestination(GuideNode.activity),
  GuideNode.health: GuideDestination(null, ['HealthScreen']),
  GuideNode.healthOverview: GuideDestination(GuideNode.health),
  GuideNode.healthExplore: GuideDestination(GuideNode.health),
  GuideNode.healthTrends: GuideDestination(GuideNode.health),
  GuideNode.healthVitals: GuideDestination(GuideNode.health),
  GuideNode.healthLabs: GuideDestination(GuideNode.health),
  GuideNode.settings: GuideDestination(null, ['MoreSettings']),
  GuideNode.dayStrain: GuideDestination(GuideNode.today, ['DayStrainDetail']),
  GuideNode.zones: GuideDestination(GuideNode.dayStrain, ['ZonesDetail']),
  GuideNode.daySteps: GuideDestination(GuideNode.today, ['DayStepsDetail']),
  GuideNode.dayTimeline: GuideDestination(GuideNode.today, [
    'DayTimelineScreen',
  ]),
  GuideNode.review: GuideDestination(GuideNode.today, ['DetectedActivitiesScreen']),
  GuideNode.recovery: GuideDestination(GuideNode.today, ['ReadinessDetail']),
  GuideNode.stress: GuideDestination(GuideNode.today, []),
  GuideNode.journal: GuideDestination(GuideNode.today, ['JournalCompose']),
  GuideNode.nutrition: GuideDestination(GuideNode.today, ['NutritionScreen']),
  GuideNode.nutritionLog: GuideDestination(GuideNode.nutrition, [
    'LogFoodSheet',
  ]),
  GuideNode.coach: GuideDestination(GuideNode.today, ['CoachScreen']),
  GuideNode.coachSetup: GuideDestination(GuideNode.coach, ['CoachSetup']),
  GuideNode.month: GuideDestination(GuideNode.today, ['MonthGrid']),
  GuideNode.whatChanged: GuideDestination(GuideNode.today, [
    'WhatChangedScreen',
  ]),
  GuideNode.naps: GuideDestination(GuideNode.sleep, ['NapsScreen']),
  GuideNode.alarm: GuideDestination(GuideNode.sleep, ['AlarmScreen', 'AlarmScreenView']),
  GuideNode.circadian: GuideDestination(GuideNode.sleep, ['CircadianDetail']),
  GuideNode.sleepDebt: GuideDestination(GuideNode.sleep, []),
  GuideNode.sleepConsistency: GuideDestination(GuideNode.sleep, []),
  GuideNode.sleepNeed: GuideDestination(GuideNode.sleep, []),
  GuideNode.sleepRegularity: GuideDestination(GuideNode.sleep, []),
  GuideNode.picker: GuideDestination(GuideNode.activityOverview, [
    'ActivityPicker',
  ]),
  GuideNode.setup: GuideDestination(GuideNode.picker, ['ActivitySetup']),
  GuideNode.live: GuideDestination(GuideNode.setup, ['LiveShell']),
  GuideNode.logWorkout: GuideDestination(GuideNode.activityHistory, [
    'LogWorkout',
  ]),
  GuideNode.workoutSummary: GuideDestination(GuideNode.activityOverview, [
    'ActivitySummary',
  ]),
  GuideNode.beats: GuideDestination(GuideNode.healthOverview, ['Beats']),
  GuideNode.ecg: GuideDestination(GuideNode.healthOverview, ['EcgHomeScreen']),
  GuideNode.ecgCapture: GuideDestination(GuideNode.ecg, ['EcgCaptureScreen']),
  GuideNode.ecgDetail: GuideDestination(GuideNode.ecg, ['EcgDetailScreen']),
  GuideNode.breathing: GuideDestination(GuideNode.healthOverview, [
    'CalmBreathing',
  ]),
  GuideNode.investigate: GuideDestination(GuideNode.healthOverview, [
    'Investigate',
  ]),
  GuideNode.findings: GuideDestination(GuideNode.healthOverview, [
    'FindingsLog',
  ]),
  GuideNode.drivers: GuideDestination(GuideNode.healthOverview, [
    'DriverBreakdown',
  ]),
  GuideNode.advanced: GuideDestination(GuideNode.settings, ['AdvancedScreen']),
  GuideNode.profile: GuideDestination(GuideNode.settings, ['EditProfile']),
  GuideNode.devices: GuideDestination(GuideNode.settings, ['MyDevices']),
  GuideNode.deviceDetail: GuideDestination(GuideNode.devices, ['DeviceDetail']),
  GuideNode.bandGestures: GuideDestination(GuideNode.settings, [
    'BandGestures',
  ]),
  GuideNode.bandNotifications: GuideDestination(GuideNode.settings, [
    'BandNotifications',
  ]),
  GuideNode.phoneImport: GuideDestination(GuideNode.settings, ['PhoneImport']),
  GuideNode.reportIssue: GuideDestination(GuideNode.settings, [
    'ReportIssueScreen',
  ]),
  GuideNode.metric: GuideDestination(GuideNode.healthOverview),
  GuideNode.help: GuideDestination(GuideNode.settings, ['HelpScreen']),
};

class GuideNavigation {
  static final _screens = <String, GuideNode>{
    for (final entry in guideNavigationTree.entries)
      for (final name in entry.value.screens) name: entry.key,
  };
  static GuideNode? parent(GuideNode node) => guideNavigationTree[node]!.parent;
  static GuideNode tabOf(GuideNode node) {
    var tab = node;
    while (parent(tab) != null) {
      tab = parent(tab)!;
    }
    return tab;
  }

  static bool onPath(GuideNode current, GuideNode target) {
    for (GuideNode? n = target; n != null; n = parent(n)) {
      if (n == current) return true;
    }
    return false;
  }

  static List<GuideNode> _ancestors(GuideNode node) => [
    node,
    if (parent(node) case final GuideNode p) ..._ancestors(p),
  ];

  // CLAIM(guide-navigation-hops): each hop is an actual control, not a virtual
  // container node [guide_r3_navigation_test]. Activity's sub-tabs are siblings.
  static List<GuideHop> route(GuideNode from, GuideNode to) {
    if (from == to) return const [];
    final up = _ancestors(from), down = _ancestors(to);
    final common = up.where(down.contains).firstOrNull;
    final hops = <GuideHop>[];
    var current = from;
    while (current != common && parent(current) != null) {
      final p = parent(current)!;
      if (subTabIndex(current) != null) {
        break; // no Back from a sub-tab to its container
      }
      hops.add(GuideHop(p, GuideHopKind.back));
      current = p;
    }
    if (tabOf(current) != tabOf(to)) {
      final tab = tabOf(to);
      current = tab == GuideNode.activity
          ? GuideNode.activityOverview
          : tab == GuideNode.health
          ? GuideNode.healthOverview
          : tab;
      hops.add(
        GuideHop(
          current,
          tab == GuideNode.settings ? GuideHopKind.page : GuideHopKind.tab,
        ),
      );
    }
    if (current == to) return hops;
    final path = down.reversed.toList();
    for (final next in path) {
      if (next == GuideNode.activity ||
          next == GuideNode.health ||
          next == current ||
          onPath(next, current)) {
        continue;
      }
      hops.add(
        GuideHop(
          next,
          (subTabIndex(next) != null) ? GuideHopKind.subTab : GuideHopKind.page,
        ),
      );
      current = next;
    }
    return hops;
  }

  /// Screen identity is present during loading. The marker is available for
  /// pages whose selected branch changes independently of their root widget.
  static GuideNode? location(Element root, {bool includeOffstage = false}) {
    GuideNode? found;
    var inActivity = false, inHealth = false;
    for (final e in includeOffstage ? _mountedElements(root) : onstageElements(root)) {
      final w = e.widget;
      if (w is GuideLocation) return w.node;
      if (w is MetricDetail) {
        return switch (w.metricKey) {
          'recovery' => GuideNode.recovery,
          'stress' => GuideNode.stress,
          'sleep_debt' => GuideNode.sleepDebt,
          'sleep_consistency' => GuideNode.sleepConsistency,
          'sleep_need' => GuideNode.sleepNeed,
          'sleep_regularity' => GuideNode.sleepRegularity,
          'steps' => GuideNode.daySteps,
          _ => GuideNode.metric,
        };
      }
      if (w is SubTabs && inActivity) {
        return [
          GuideNode.activityOverview,
          GuideNode.activityActivities,
          GuideNode.activityHistory,
        ][w.index];
      }
      if (w is SubTabs && inHealth) {
        return [
          GuideNode.healthOverview,
          GuideNode.healthExplore,
          GuideNode.healthTrends,
          GuideNode.healthVitals,
          GuideNode.healthLabs,
        ][w.index];
      }
      final name = w.runtimeType.toString();
      final candidate = _screens[name];
      if (candidate != null) {
        found = candidate;
        if (candidate == GuideNode.activity) {
          inActivity = true;
        } else if (candidate == GuideNode.health) {
          inHealth = true;
        } else {
          return candidate;
        }
      }
      if (w is IndexedStack &&
          found == null &&
          e.findAncestorWidgetOfExactType<AppShell>() != null) {
        found = [
          GuideNode.today,
          GuideNode.sleep,
          GuideNode.activity,
          GuideNode.health,
          GuideNode.settings,
        ][w.index ?? 0];
      }
    }
    return found;
  }

  static Iterable<Element> _mountedElements(Element root) sync* {
    yield root;
    final children = <Element>[];
    root.visitChildren(children.add);
    for (final child in children) {
      yield* _mountedElements(child);
    }
  }

  /// A shell tab restores its retained branch, rather than its default branch.
  /// Read only mounted identities: an unvisited lazy tab keeps the default path.
  static GuideNode? parkedLocation(Element page, GuideNode tab) {
    final branch = parkedPage(page, tab);
    return branch == null ? null : location(branch, includeOffstage: true);
  }

  static Element? parkedPage(Element page, GuideNode tab) {
    final shell = onstageElements(page).where((e) => e.widget is AppShell).firstOrNull;
    final index = tabIndex(tab);
    if (shell == null || index == null) return null;
    final stack = onstageElements(shell).where((e) => e.widget is IndexedStack).firstOrNull;
    if (stack == null) return null;
    Element? raw;
    stack.visitChildren((e) => raw ??= e);
    final branches = <Element>[];
    raw?.visitChildren(branches.add);
    if (index >= branches.length) return null;
    return branches[index];
  }

  static int? tabIndex(GuideNode node) => switch (tabOf(node)) {
    GuideNode.today => 0,
    GuideNode.sleep => 1,
    GuideNode.activity => 2,
    GuideNode.health => 3,
    GuideNode.settings => 4,
    _ => null,
  };
  static int? subTabIndex(GuideNode node) => switch (node) {
    GuideNode.activityOverview => 0,
    GuideNode.activityActivities => 1,
    GuideNode.activityHistory => 2,
    GuideNode.healthOverview => 0,
    GuideNode.healthExplore => 1,
    GuideNode.healthTrends => 2,
    GuideNode.healthVitals => 3,
    GuideNode.healthLabs => 4,
    _ => null,
  };

  static TargetFound? entry(Element page, GuideHop hop, AppLocalizations l) {
    if (hop.node == GuideNode.settings) {
      final avatar = onstageElements(page)
          .where((e) => e.widget.runtimeType.toString() == 'ProfileAvatar')
          .firstOrNull;
      final root = laidOutBox(page),
          box = avatar == null ? null : laidOutBox(avatar);
      if (root != null && box != null) {
        return TargetFound(rectInRoot(box, root), renderObject: box);
      }
    }
    final label = switch (hop.node) {
      GuideNode.dayStrain => ScreenLabel.homeRingStrain,
      GuideNode.zones => ScreenLabel.dayStrainHowSet,
      GuideNode.naps => ScreenLabel.sleepDetailEditNaps,
      GuideNode.alarm => ScreenLabel.settingsAlarmRowTitle,
      GuideNode.review => ScreenLabel.activityReviewTitle,
      GuideNode.picker => ScreenLabel.workoutStartSessionLabel,
      GuideNode.logWorkout => ScreenLabel.workoutLogPastFix,
      _ => null,
    };
    if (label == null) return null;
    final result = GuideTarget.label(label).resolve(page, l);
    return result is TargetFound ? result : null;
  }
}

/// A declaration only: adds no render object, layout or semantics node.
class GuideLocation extends StatelessWidget {
  final GuideNode node;
  final Widget child;
  const GuideLocation({super.key, required this.node, required this.child});
  @override
  Widget build(BuildContext context) => child;
}
