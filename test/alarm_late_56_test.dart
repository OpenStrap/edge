// Pins the late event-56 bug seen on a real WHOOP 4 (2026-10-22 capture): the
// strap queued its ALARM_SET events while an offload stalled, then delivered
// three at once ~35 s after the writes. The hex below is verbatim from that
// logcat; the confirmation must key on the epoch in the body, not the stamp.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  echoTests();
  const oldArm = '30ca3800f8c0d96a487108000160ecde6a000010'; // 1792994400
  const newArm = '30d938000ac1d96ae031080001d0e9da6a000010'; // 1792731600
  const target = 1792731600;
  const setSec = 1792655626; // when the SET was written

  test('reads the wake time out of a 56 body', () {
    expect(AlarmConfirmation.setEventEpoch(oldArm), 1792994400);
    expect(AlarmConfirmation.setEventEpoch(newArm), target);
  });

  test('rejects bodies that are not a 56 or are too short', () {
    expect(AlarmConfirmation.setEventEpoch('30960100'), isNull);
    expect(
      AlarmConfirmation.setEventEpoch('30d93a00${newArm.substring(8)}'),
      isNull,
    );
  });

  test('a late 56 naming the armed epoch confirms despite an old stamp', () {
    final a = AlarmConfirmation()..set(target, setSec * 1000);
    // Stamp 10 min before the SET write: the replay filter alone drops it.
    final stale = setSec - 600;
    expect(
      a.onEvent(AlarmConfirmation.kEvtSet, (setSec + 30) * 1000, tsSec: stale),
      isNull,
    );
    expect(
      a.onEvent(
        AlarmConfirmation.kEvtSet,
        (setSec + 30) * 1000,
        tsSec: stale,
        payloadEpoch: target,
      ),
      AlarmEffect.confirmed,
    );
    expect(a.confirmed, isTrue);
  });

  test('a 56 naming a different wake time never confirms, even with a fresh stamp',
      () {
    final a = AlarmConfirmation()..set(target, setSec * 1000);
    expect(
      a.onEvent(AlarmConfirmation.kEvtSet, (setSec + 5) * 1000,
          tsSec: setSec + 5, payloadEpoch: 1792994400),
      isNull,
    );
    expect(a.confirmed, isFalse);
  });

  test('a clock-drift refresh between arm and event still names the arm', () {
    final a = AlarmConfirmation()..set(target, setSec * 1000);
    expect(
      a.onEvent(AlarmConfirmation.kEvtSet, (setSec + 30) * 1000,
          tsSec: setSec - 600, payloadEpoch: target + 9),
      AlarmEffect.confirmed,
    );
  });

  test('a 56 for a different (older) arm does not confirm this one', () {
    final a = AlarmConfirmation()..set(target, setSec * 1000);
    expect(
      a.onEvent(
        AlarmConfirmation.kEvtSet,
        (setSec + 30) * 1000,
        tsSec: setSec - 600,
        payloadEpoch: 1792994400,
      ),
      isNull,
    );
    expect(a.confirmed, isFalse);
  });
}

// The instant SET_ALARM_TIME reply echoes the stored wake time; bytes below
// are the replies from the same capture.
void echoTests() {
  List<int> hex(String h) => [
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ];

  test('reads the echoed wake time out of the instant reply', () {
    // The old decoder called the low byte (0xd0 = 208) an "alarm status".
    expect(
      AlarmConfirmation.replyEchoEpoch(hex('249442ae0101d0e9da6a0000')),
      1792731600,
    );
    expect(
      AlarmConfirmation.replyEchoEpoch(hex('249442ae010160ecde6a0000')),
      1792994400,
    );
  });

  test('a short or non-revision-1 reply echoes nothing', () {
    expect(AlarmConfirmation.replyEchoEpoch(hex('249442ae0101')), isNull);
    expect(
      AlarmConfirmation.replyEchoEpoch(hex('249442ae0103d0e9da6a0000')),
      isNull,
    );
  });
}
