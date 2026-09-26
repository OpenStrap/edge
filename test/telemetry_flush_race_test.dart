// Regression test for the outbox flush/trim race: record() can append + head
// trim to _maxOutbox from a crash loop while flush()'s POST is still in
// flight for an earlier snapshot. flush() must drop exactly the objects it
// sent, never a new unsent record that happened to shift into their slot.
//
// This exercises the fix's actual mechanism (identity removal via
// List.remove, which for Map falls back to Object.== i.e. reference
// equality) against the outbox list shape used in telemetry_service.dart,
// without needing to stand up Firebase/CompanionClient/SharedPreferences.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('identity-based removal survives a concurrent head-trim', () {
    final outbox = <Map<String, dynamic>>[
      for (var i = 0; i < 20; i++) {'id': i}
    ];

    // flush() snapshots the first batch by reference (List.from is shallow).
    final events = List<Map<String, dynamic>>.from(outbox);

    // Concurrently, record() appends a burst and head-trims to a cap of 25,
    // which evicts some of the very records currently "in flight" (0..4) and
    // leaves brand-new, never-sent records at the front.
    for (var i = 20; i < 40; i++) {
      outbox.add({'id': i});
    }
    const cap = 25;
    while (outbox.length > cap) {
      outbox.removeAt(0);
    }
    // Sanity: ids 0-14 were evicted by the trim, 15-39 remain.
    expect(outbox.first['id'], 15);

    // The POST for `events` (ids 0-19) now succeeds. Apply the fixed removal.
    for (final e in events) {
      outbox.remove(e);
    }

    final remainingIds = outbox.map((e) => e['id']).toSet();
    // Every unsent record (ids 20-39) must survive.
    for (var i = 20; i < 40; i++) {
      expect(remainingIds.contains(i), isTrue,
          reason: 'record $i was never sent and must not be dropped');
    }
    // The only ones left from the sent batch are those the trim had not
    // already evicted (15-19) — remove() cleans those up too.
    expect(remainingIds.any((id) => id < 20), isFalse);
  });

  test('the old index-range removal is the bug: it deletes unsent records',
      () {
    final outbox = <Map<String, dynamic>>[
      for (var i = 0; i < 20; i++) {'id': i}
    ];
    final events = List<Map<String, dynamic>>.from(outbox);

    for (var i = 20; i < 40; i++) {
      outbox.add({'id': i});
    }
    const cap = 25;
    while (outbox.length > cap) {
      outbox.removeAt(0);
    }

    // Reproduce the ORIGINAL buggy behavior for comparison.
    outbox.removeRange(0, events.length.clamp(0, outbox.length));

    final remainingIds = outbox.map((e) => e['id']).toSet();
    // This demonstrates the bug: brand-new, never-sent records (20-34) are
    // gone even though they were never transmitted.
    expect(remainingIds.contains(20), isFalse,
        reason: 'documents the pre-fix data-loss behavior');
  });
}
