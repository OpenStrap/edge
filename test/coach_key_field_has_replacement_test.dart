// coachKeyFieldHasReplacement decides whether typed key-field text cancels a
// pending API-key deletion from an endpoint change (see
// coach_api_key_to_save_test.dart and _CoachSetupState._onBaseChanged).
//
// The bug this guards (EDGE-13, CodeRabbit on PR #375, CWE-200): the field's
// listener originally checked the RAW text with `.isNotEmpty`. Whitespace-only
// input (a stray pasted space) is non-empty, so it cleared the pending-delete
// flag — but coachApiKeyToSave trims before deciding what to save, sees an
// empty field, and left an unreadable stored key undeleted after the very
// endpoint change this mechanism exists to catch.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

void main() {
  test('real text is a replacement', () {
    expect(coachKeyFieldHasReplacement('sk-real-key'), isTrue);
  });

  test('empty text is not a replacement', () {
    expect(coachKeyFieldHasReplacement(''), isFalse);
  });

  test('whitespace-only text is NOT a replacement', () {
    expect(coachKeyFieldHasReplacement('   '), isFalse);
    expect(coachKeyFieldHasReplacement('\t\n'), isFalse);
  });

  test('a real key with incidental surrounding whitespace still counts', () {
    expect(coachKeyFieldHasReplacement('  sk-real-key  '), isTrue);
  });
}
