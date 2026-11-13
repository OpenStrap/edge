// Chinese was missing 350 strings outside the supplement catalogue, so whole
// screens (device picker, detected activities, step calibration, trends) fell
// back to English on an otherwise Chinese app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final zh = lookupAppLocalizations(const Locale('zh'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('chinese has every english string outside the supplement catalogue',
      () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final chinese = arb('zh');
    final missing = [
      for (final k in arb('en').keys)
        if (!k.startsWith('@') && !chinese.containsKey(k)) k,
    ];
    // Still to do: the supplement catalogue.
    missing.removeWhere((k) => k.startsWith('supplement'));
    expect(missing, isEmpty);
  });

  test('the newly covered screens read in chinese', () {
    expect(zh.devicePickerTitle, '连接你的设备');
    expect(zh.activityReviewTitle, '检测到的活动');
    expect(zh.stepCalTitle, '步数校准');
    expect(zh.stepCalTitle, isNot(en.stepCalTitle));
  });

  test('built-in activities are named in chinese, custom ones pass through',
      () {
    expect(zh.activityCatalogueName('krunning', 'Running'), '跑步');
    expect(zh.activityCatalogueName('custom', '我的运动'), '我的运动');
  });

  test('counts carry their number', () {
    expect(zh.homeFirstWeekSoFar(1), '目前已记录 1 天');
    expect(zh.homeFirstWeekSoFar(3), '目前已记录 3 天');
    expect(zh.homeRecoveryStartsIn(2), '恢复将在 2 晚后开始');
    expect(zh.devicesSensorLimit(2), contains('2 个传感器'));
  });
}
