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
//
// The screen used to also track "has a replacement been typed" as separate
// mutable state on a _key listener, clearing pendingKeyDelete the moment any
// non-whitespace text appeared. That state only ever moved one way: typing a
// replacement and then erasing it again left pendingKeyDelete cleared with no
// replacement to show for it, so an unreadable stored key survived Save
// untouched (EDGE-13's own bug, and a second CodeRabbit finding on top of it).
// That tracking was removed entirely — this function's own
// `trimmed.isNotEmpty` check already derives "is there a real replacement
// right now" from keyText's value AT SAVE TIME, which cannot go stale the way
// separately-tracked state can.

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
