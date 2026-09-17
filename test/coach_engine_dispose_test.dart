// The coach chat screen used to own CoachEngine's lifetime directly: navigating
// away (or the app backgrounding) called `engine.dispose()`, which closed the
// shared http.Client out from under any request still in flight. For a local
// model that can legitimately take minutes to respond, that meant leaving the
// screen — even briefly — silently killed the request: no reply, no error, no
// trace, because the ClientException that resulted was thrown into a screen
// state that no longer existed to show it.
//
// Reported live: a user sent several messages to a local Ollama endpoint,
// server-side logs showed each one being processed, but the app showed nothing
// for any of them. `requestDispose` is the fix: it defers the actual
// `http.Client.close()` until any in-flight `send()` has genuinely finished,
// so the request either completes or fails for a real reason — never because
// the user looked away.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';

class _FakeRepo extends LocalRepository {}

/// A minimal http.Client whose `send` can be delayed, and which records
/// whether `close()` was ever called — the one signal a real `postChat` call
/// would notice: a client closed mid-flight throws instead of completing.
class _TrackingClient extends http.BaseClient {
  _TrackingClient(this.delay);
  final Duration delay;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw http.ClientException('Connection closed', request.url);
    await Future<void>.delayed(delay);
    if (closed) throw http.ClientException('Connection closed', request.url);
    final body = utf8.encode(jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': 'a real answer'}
        }
      ]
    }));
    return http.StreamedResponse(
      Stream.value(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('requestDispose defers closing the client until an in-flight send '
      'finishes', () async {
    final client = _TrackingClient(const Duration(milliseconds: 100));
    final engine = CoachEngine(
      config: CoachConfig()..save(model: 'm'),
      api: _FakeRepo(),
      client: client,
    );

    final sending = engine.send(
      'hi',
      onItem: (_) {},
      onStatus: (_) {},
      confirm: (_) async => true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The screen navigated away (or the app backgrounded) while the request
    // was still in flight.
    engine.requestDispose();
    expect(client.closed, isFalse,
        reason: 'closing now would abort the request underneath it');

    // The request must complete normally — not throw ClientException.
    await sending;
    expect(engine.transcript.last.text, contains('a real answer'));

    // Now that nothing is in flight, the deferred dispose has run.
    expect(client.closed, isTrue);
  });

  test('requestDispose closes immediately when nothing is in flight',
      () async {
    final client = _TrackingClient(Duration.zero);
    final engine = CoachEngine(
      config: CoachConfig(),
      api: _FakeRepo(),
      client: client,
    );

    engine.requestDispose();
    expect(client.closed, isTrue);
  });
}
