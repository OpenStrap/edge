import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

class _ExecuteCalls extends RecursiveAstVisitor<void> {
  final arguments = <Expression>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'execute') {
      arguments.add(node.argumentList.arguments.first);
    }
    super.visitMethodInvocation(node);
  }
}

void main() {
  final parts = Directory('lib/data').listSync().whereType<File>()
      .where((f) => f.path.endsWith('.dart') &&
          f.readAsStringSync().contains("part of 'db.dart';")).toList();

  test('DB parts contain only _ldb functions', () {
    expect(parts.map((f) => f.path), contains('lib/data/db_input_revisions.dart'));
    for (final file in parts) {
      final unit = parseString(content: file.readAsStringSync()).unit;
      expect(unit.declarations, isNotEmpty, reason: file.path);
      for (final declaration in unit.declarations) {
        expect(declaration, isA<FunctionDeclaration>(), reason: file.path);
        expect((declaration as FunctionDeclaration).name.lexeme,
            startsWith('_ldb'), reason: file.path);
      }
    }
  });

  test('DB part execute calls carry literal SQL', () {
    var calls = 0;
    for (final file in parts) {
      final visitor = _ExecuteCalls();
      parseString(content: file.readAsStringSync()).unit.accept(visitor);
      calls += visitor.arguments.length;
      for (final argument in visitor.arguments) {
        expect(argument, isA<StringLiteral>(), reason: '${file.path}: $argument');
      }
    }
    expect(calls, greaterThanOrEqualTo(9));
    // Positive control: a variable SQL argument would fail the predicate.
    final probe = _ExecuteCalls();
    parseString(content: 'void probe(dynamic db, String sql) { db.execute(sql); }')
        .unit.accept(probe);
    expect(probe.arguments.single, isNot(isA<StringLiteral>()));
  });

  test('DB parts stay below 6000 source lines', () {
    for (final file in parts) {
      expect(file.readAsLinesSync().length, lessThanOrEqualTo(6000),
          reason: file.path);
    }
  });
}
