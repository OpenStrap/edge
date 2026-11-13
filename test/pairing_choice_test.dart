// WHY: the scan must never substitute a nearby band for the tapped one.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  test('choice binds both id and generation, with independent wildcards', () {
    expect(ScanAcceptPolicy.fitsChoice('picked', const ['fd4b0001'], wantRemoteId: 'picked', wantGeneration: 'gen5'), isTrue);
    expect(ScanAcceptPolicy.fitsChoice('other', const ['fd4b0001'], wantRemoteId: 'picked', wantGeneration: 'gen5'), isFalse);
    expect(ScanAcceptPolicy.fitsChoice('picked', const ['61080001'], wantRemoteId: 'picked', wantGeneration: 'gen5'), isFalse);
    expect(ScanAcceptPolicy.fitsChoice('picked', const ['61080001'], wantRemoteId: 'picked'), isTrue);
    expect(ScanAcceptPolicy.fitsChoice('other', const ['fd4b0001'], wantGeneration: 'gen5'), isTrue);
    expect(ScanAcceptPolicy.fitsChoice('other', const ['61080001']), isTrue);
    // A name-only match has no model evidence; discovery still has to identify it.
    expect(ScanAcceptPolicy.fitsChoice('picked', const [], wantRemoteId: 'picked', wantGeneration: 'gen5'), isTrue);
  });
}
