// Structural guards for the app observer and the private radio ACK boundary.
// Database lifecycle and durability behavior run against real files in
// wal_reader_connection_test.dart. These guards cover their production callers
// without booting AppState's platform services or introducing another observer.
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show screenReadsForeground;

import 'support/dart_source.dart';

String _body(String code, String method) {
  final call = RegExp('(?:void|Future<void>)\\s+$method\\s*\\(')
      .firstMatch(code)!;
  var cursor = code.indexOf('(', call.start);
  var depth = 0;
  do {
    if (code[cursor] == '(') depth++;
    if (code[cursor] == ')') depth--;
    cursor++;
  } while (depth > 0);
  final start = code.indexOf('{', cursor);
  cursor = start;
  do {
    if (code[cursor] == '{') depth++;
    if (code[cursor] == '}') depth--;
    cursor++;
  } while (depth > 0);
  return code.substring(start + 1, cursor - 1);
}

// Find the if/else-if branch that handles a given lifecycle state. Grouped
// OR conditions are allowed, as in the fork. Comments/strings are already gone.
String? _stateBranch(String code, String state) {
  for (final condition in RegExp(r'\bif\s*\(', multiLine: true).allMatches(code)) {
    var cursor = code.indexOf('(', condition.start);
    final start = cursor;
    var depth = 0;
    do {
      if (code[cursor] == '(') depth++;
      if (code[cursor] == ')') depth--;
      cursor++;
    } while (depth > 0);
    if (!RegExp('state\\s*==\\s*AppLifecycleState\\.$state\\b')
        .hasMatch(code.substring(start, cursor))) {
      continue;
    }
    final block = code.indexOf('{', cursor);
    cursor = block;
    do {
      if (code[cursor] == '{') depth++;
      if (code[cursor] == '}') depth--;
      cursor++;
    } while (depth > 0);
    return code.substring(block + 1, cursor - 1);
  }
  return null;
}

void main() {
  final app = stripCommentsAndStrings(File('lib/app.dart').readAsStringSync());
  final lifecycle = _body(app, 'didChangeAppLifecycleState');

  test('visible cold start enables lazy reads through the existing app observer', () {
    final init = _body(app, 'initState');
    expect(init, contains('WidgetsBinding.instance.addObserver(this)'));
    expect(init, matches(RegExp(r'LocalDb\.setForeground\(\s*screenReadsForeground\(\s*'
        r'WidgetsBinding\.instance\.lifecycleState\s*\)\s*\)')),
        reason: 'cold foreground start need not emit a resumed transition');
  });

  test('cold-start lifecycle state maps to the reader foreground flag', () {
    // Null: no lifecycle report yet; the observer corrects it on the first one.
    expect(screenReadsForeground(null), isTrue);
    expect(screenReadsForeground(AppLifecycleState.resumed), isTrue);
    expect(screenReadsForeground(AppLifecycleState.inactive), isTrue);
    expect(screenReadsForeground(AppLifecycleState.hidden), isFalse);
    expect(screenReadsForeground(AppLifecycleState.paused), isFalse);
    expect(screenReadsForeground(AppLifecycleState.detached), isFalse);
  });

  test('resume enables lazy reads in the app lifecycle observer', () {
    final branch = _stateBranch(lifecycle, 'resumed');
    expect(branch, isNotNull);
    expect(branch, matches(RegExp(r'LocalDb\.setForeground\(\s*true\s*\)')),
        reason: 'resume must allow the next screen read to reopen the reader');
  });

  for (final state in ['hidden', 'paused', 'detached']) {
    test('$state closes reader through the app lifecycle observer', () {
      final branch = _stateBranch(lifecycle, state);
      expect(branch, isNotNull, reason: '$state must reach LocalDb');
      expect(branch, matches(RegExp(r'LocalDb\.setForeground\(\s*false\s*\)')),
          reason: '$state must drain reads and close the second connection');
    });
  }

  test('HISTORY_END awaits durable commit and gates the verbatim ACK token', () {
    final ble = stripCommentsAndStrings(File('lib/ble/ble_engine.dart').readAsStringSync());
    final marker = _body(ble, '_handleSyncMarker');
    final commit = RegExp(r'final\s+durable\s*=\s*await\s+d\.commit\(m\.token\)')
        .firstMatch(marker);
    final ack = RegExp(r'buildHistoryResultOk\([^;]*m\.token!', dotAll: true)
        .firstMatch(marker);
    expect(commit, isNotNull);
    expect(ack, isNotNull);
    expect(ack!.start, greaterThan(commit!.end));
    final gate = marker.substring(commit.end, ack.start);
    expect(gate, contains('commitDurable: durable'));
    expect(gate, matches(RegExp(
        r'if\s*\(verdict\s*!=\s*TrimAckVerdict\.send\)\s*\{[^}]*return\s*;',
        dotAll: true)), reason: 'failed/partial commit must return before ACK');
  });
}
