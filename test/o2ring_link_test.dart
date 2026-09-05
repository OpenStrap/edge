// O2RingLink's archive-row builder: every notification must reach
// `raw_archive`, decoded or not — including the frames `parseO2RingFrame`
// refuses outright (truncated, bad header, bad CRC).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/o2ring_link.dart';

void main() {
  test('a frame that fails to parse is still archived, not dropped', () {
    // Same junk o2ring_adapter_test.dart uses for "an unparsable reply" —
    // a bad trailing CRC byte.
    const junk = <int>[0xAA, 0x14, 0xEB, 0, 0, 1, 0, 0x00, 0xFF];
    final rec = O2RingLink.instance.buildArchiveRowForTest(junk, 1786000000);
    expect(rec.hex, 'aa14eb0000010000ff');
    expect(rec.reason, 'o2ring_unparsed');
  });
}
