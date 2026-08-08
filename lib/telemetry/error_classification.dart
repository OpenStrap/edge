// Which uncaught errors actually represent a crash.
//
// `PlatformDispatcher.onError` was filing everything it saw as fatal. That is
// wrong for the transient network failures the app is expected to survive: a
// basemap tile fetched with no connectivity, a TLS handshake dropped mid-flight,
// a request abandoned when its widget went away. None of those stop the app, but
// each one counted against the crash-free-user rate and buried real crashes in
// the issue list.
//
// Pure and dependency-free so it can be unit tested without a Flutter binding.

/// True when [error] is a transient I/O failure rather than a defect.
///
/// Deliberately matched on type NAME rather than on an imported type: this file
/// stays dependency-free, and the relevant types come from `dart:io` and
/// `package:http`, which classify identically here.
bool isTransientError(Object error) {
  final type = error.runtimeType.toString();
  const transientTypes = {
    'SocketException',
    'HttpException',
    'HandshakeException',
    'TlsException',
    'ClientException',
    'ConnectionClosedException',
  };
  // TimeoutException is deliberately NOT here. It is not network-specific — a
  // derivation, database or lifecycle timeout raises the same type, and those
  // are exactly the failures worth keeping visible as crashes.
  if (transientTypes.contains(type)) return true;

  // http's ClientException wraps the underlying cause in its message rather
  // than nesting the exception, so the wrapped form has to be matched on text.
  final text = error.toString();
  return text.contains('SocketException') ||
      text.contains('HandshakeException') ||
      text.contains('Connection closed') ||
      text.contains('Connection reset') ||
      text.contains('Failed host lookup') ||
      text.contains('Network is unreachable');
}
