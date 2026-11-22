// HelioStrapAdapter: the one behaviour that matters most before any real
// handshake exists — a session with no auth key in storage does NOTHING
// (no-leak rule, ASSUMPTIONS R6). A full scripted end-to-end walk (a fake
// strap performing its own ECDH side of the handshake and answering fetch
// rounds) is a substantial follow-up, not yet written here — see the
// adapter's own header for what IS verified (the protocol layer, by
// known-value tests in the `protocol` package) versus what still needs a
// real session replay.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart';

void main() {
  test('no stored key: the session emits kHelioNoKeyNote and nothing else', () async {
    final adapter = HelioStrapAdapter(authKeyReader: () async => null);
    final link = ReplayBandLink();

    final events = await adapter.run(link).toList();

    expect(events, hasLength(1));
    expect(events.single, isA<BandNote>());
    expect((events.single as BandNote).key, kHelioNoKeyNote);
    expect(link.writes, isEmpty, reason: 'no key means no write is ever attempted');
  });

  test('entry/id/label/signals match the registry row', () {
    final adapter = HelioStrapAdapter();
    expect(adapter.id, 'helio_strap');
    expect(adapter.label, 'Amazfit Helio Strap');
    expect(adapter.signals, kHelioStrapSignals);
  });
}
