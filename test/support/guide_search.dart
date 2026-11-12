import 'package:flutter_test/flutter_test.dart';

/// Advances normal frames while bounded target discovery is in progress.
Future<T> pumpGuideSearch<T>(WidgetTester tester, Future<T> search) async {
  var complete = false;
  late T value;
  Object? error;
  StackTrace? stack;
  search.then<void>((found) {
    value = found;
    complete = true;
  }, onError: (Object caught, StackTrace trace) {
    error = caught;
    stack = trace;
    complete = true;
  });
  for (var frame = 0; frame < 500 && !complete; frame++) {
    await tester.pump();
  }
  expect(complete, isTrue, reason: 'bounded guide search must finish');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}
