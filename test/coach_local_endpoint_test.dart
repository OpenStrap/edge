import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

/// A local model wants no API key, so `configured` requiring one made Ollama
/// and LM Studio impossible to finish setting up — Save closed the form and the
/// coach stayed off with nothing on screen to say why.
///
/// The half that matters more is the negative: this must NOT open the no-key
/// path to a public host, and `192.168.1.40.evil.com` is a real registrable
/// domain that a substring check would have accepted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('a local endpoint needs no key; a public one still does', () async {
    final c = CoachConfig();
    for (final (url, want) in <(String, bool)>[
      ('http://localhost:11434/v1', true),
      ('http://127.0.0.1:1234/v1', true),
      ('http://10.0.2.2:11434/v1', true),
      ('http://192.168.1.40:11434/v1', true),
      ('http://10.1.2.3:11434/v1', true),
      ('http://172.16.5.4:11434/v1', true),
      ('http://172.32.5.4:11434/v1', false),
      // Tailscale node addresses: 100.64.0.0/10, and nothing either side.
      ('http://100.95.55.34:11434/v1', true),
      ('http://100.64.0.1:11434/v1', true),
      ('http://100.127.255.254:11434/v1', true),
      ('http://100.63.0.1:11434/v1', false),
      ('http://100.128.0.1:11434/v1', false),
      // Not IPv4 literals at all: an out-of-range octet is a host name.
      ('http://100.64.0.999:11434/v1', false),
      ('http://192.168.1.999:11434/v1', false),
      ('https://api.openai.com/v1', false),
      ('https://192.168.1.40.evil.com/v1', false),
    ]) {
      await c.save(baseUrl: url, apiKey: null, model: 'm');
      expect(c.isLocalEndpoint, want, reason: url);
      expect(c.configured, want, reason: '$url configured');
    }
  });

  // 100.64.0.0/10 is carrier-grade NAT before it is Tailscale: an address in
  // it may skip the API key, but must not skip the ECG consent prompt.
  test('the shared address space is local but not private', () async {
    final c = CoachConfig();
    for (final (url, local, private) in <(String, bool, bool)>[
      ('http://100.95.55.34:11434/v1', true, false),
      ('http://192.168.1.40:11434/v1', true, true),
      ('http://localhost:11434/v1', true, true),
      ('https://api.openai.com/v1', false, false),
    ]) {
      await c.save(baseUrl: url, apiKey: null, model: 'm');
      expect(c.isLocalEndpoint, local, reason: url);
      expect(c.isPrivateEndpoint, private, reason: url);
    }
  });
}
