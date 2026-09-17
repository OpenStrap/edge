// coachApiKeyToSave is the setup screen's Save decision, extracted so the
// endpoint-change interaction can be tested without a widget tree.
//
// The bug this guards: an API key that exists but could not be read
// (CoachConfig.keyUnreadable) seeds the setup screen's key field empty, the
// exact same as "no key was ever set". Naively treating an empty field as
// "nothing to delete" after the endpoint changed left that unreadable-but-real
// key sitting in the keychain, to be picked up and sent to the NEW endpoint on
// a later load — reported as a CWE-522 finding (PR #375) against the first
// version of the origin-change fix (PR #374).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

void main() {
  test('a non-empty field is always the value to save, regardless of state',
      () {
    for (final storedKeyReadable in [true, false]) {
      for (final pendingKeyDelete in [true, false]) {
        expect(
          coachApiKeyToSave(
            keyText: 'sk-new',
            storedKeyReadable: storedKeyReadable,
            pendingKeyDelete: pendingKeyDelete,
          ),
          'sk-new',
        );
      }
    }
  });

  test('empty field, readable stored key, no endpoint change: explicit delete',
      () {
    expect(
      coachApiKeyToSave(
        keyText: '',
        storedKeyReadable: true,
        pendingKeyDelete: false,
      ),
      '',
    );
  });

  test('empty field, nothing readable, no endpoint change: left untouched',
      () {
    // The original blind-clear guard: a key that could not be read (or never
    // existed) seeds the field empty through no fault of the user's, and
    // Save must not delete it unseen.
    expect(
      coachApiKeyToSave(
        keyText: '',
        storedKeyReadable: false,
        pendingKeyDelete: false,
      ),
      isNull,
    );
  });

  test(
      'empty field, UNREADABLE stored key, endpoint changed: force-deleted '
      'anyway', () {
    // This is the fix: pendingKeyDelete overrides the blind-clear guard,
    // because leaving an unreadable key in place after the endpoint changed
    // means it survives to be sent to the new endpoint later.
    expect(
      coachApiKeyToSave(
        keyText: '',
        storedKeyReadable: false,
        pendingKeyDelete: true,
      ),
      '',
    );
  });

  test('empty field, readable stored key, endpoint changed: still deleted',
      () {
    expect(
      coachApiKeyToSave(
        keyText: '',
        storedKeyReadable: true,
        pendingKeyDelete: true,
      ),
      '',
    );
  });
}
