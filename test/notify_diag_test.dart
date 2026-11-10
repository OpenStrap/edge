import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  test('rev3 hello firmware reads bytes 96..99', () {
    final body = List<int>.filled(111, 0);
    body.setAll(96, [50, 43, 2, 0]);
    final hex =
        body.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(gen5HelloRev3Firmware(hex), '50.43.2.0');
    expect(gen5HelloRev3Firmware(hex.substring(0, 198)), isNull);
  });

  test('notify diag captures only inside the window, capped', () {
    final d = NotifyDiag();
    d.chunk('data', [1, 2, 3]);
    expect(d.closeWindow(), 'frames[none] chunks[none]');
    d.openWindow();
    d.chunk('cmd_from', [0xaa, 0x01]);
    d.frame('cmd_from', '0x24');
    for (var i = 0; i < NotifyDiag.maxChunks + 2; i++) {
      d.chunk('events', [0x30]);
    }
    final s = d.closeWindow();
    expect(s, startsWith('frames[cmd_from:0x24=1] chunks[cmd_from/2B:aa01 '));
    expect(s, endsWith('(+3 more)'));
    expect(d.totals(), 'data=1/3B cmd_from=1/2B events=42/42B');
  });
}
