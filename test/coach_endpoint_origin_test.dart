// The coach setup screen used to carry an API key over to whatever base URL
// was in the field, regardless of whether it actually pointed somewhere else:
// preset selection changed only the base URL text, so switching from a cloud
// preset to a local/private one (or back) reused the key against the new
// origin without the user re-entering or confirming it. coachEndpointOrigin
// is what the screen now compares before vs. after an edit to tell whether
// the endpoint actually changed.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

void main() {
  test('same host and port, different path: same origin', () {
    expect(
      coachEndpointOrigin('https://api.openai.com/v1'),
      coachEndpointOrigin('https://api.openai.com/v1/chat/completions'),
    );
  });

  test('a different host is a different origin', () {
    expect(
      coachEndpointOrigin('http://localhost:11434/v1'),
      isNot(coachEndpointOrigin('http://192.168.1.40:11434/v1')),
    );
  });

  test('a different port on the same host is a different origin', () {
    expect(
      coachEndpointOrigin('http://localhost:11434/v1'),
      isNot(coachEndpointOrigin('http://localhost:1234/v1')),
    );
  });

  test('a different scheme is a different origin', () {
    expect(
      coachEndpointOrigin('http://api.example.com/v1'),
      isNot(coachEndpointOrigin('https://api.example.com/v1')),
    );
  });

  test('an unparseable URL falls back to the trimmed string, not a crash',
      () {
    expect(coachEndpointOrigin('  not a url  '), 'not a url');
  });
}
