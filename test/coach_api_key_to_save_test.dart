// coachApiKeyToSave is the setup screen's Save decision, extracted so the
// endpoint-change interaction can be tested without a widget tree.
//
// The bug this guards: switching the base URL/preset used to leave the OLD
// key sitting in the field (and in the keychain), so Save carried it over to
// a DIFFERENT origin unless the user happened to notice and clear it
// themselves — a stale credential silently reaching a new, possibly
// untrusted endpoint. An API key that exists but could not be read
// (CoachConfig.keyUnreadable) also seeds the setup screen's key field empty,
// the exact same as "no key was ever set", so a naive "empty field means
// nothing to delete" check after an endpoint change would still leave that
// unreadable-but-real key in place. pendingKeyDelete is what lets Save tell
// those two "empty" cases apart.

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

  test(
      'a replacement typed after an endpoint change and then erased is '
      'still force-deleted at Save time', () {
    // Simulates: origin changes (pendingKeyDelete becomes true), the user
    // types a replacement, then erases it — either to blank or to
    // whitespace. Only the FINAL keyText at the moment _save() runs matters;
    // there is no separate "was a replacement typed at some point" state left
    // to go stale.
    for (final erasedTo in ['', '   ', '\t']) {
      expect(
        coachApiKeyToSave(
          keyText: erasedTo,
          storedKeyReadable: false,
          pendingKeyDelete: true,
        ),
        '',
        reason: 'erasedTo: "$erasedTo"',
      );
    }
  });
}
