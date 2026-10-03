import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'contract.dart';

Future<Map<String, PayloadBinding>> scanPayloadBindings(File sourceFile) async {
  final sourcePath = sourceFile.absolute.path;
  final collection = AnalysisContextCollection(includedPaths: [sourcePath]);
  final session = collection.contextFor(sourcePath).currentSession;
  final result = await session.getResolvedUnit(sourcePath);
  if (result is! ResolvedUnitResult) {
    throw ContractException('Unable to resolve ${sourceFile.path}');
  }
  final analysisErrors = result.errors
      .where((diagnostic) => diagnostic.severity.name == 'ERROR')
      .toList();
  if (analysisErrors.isNotEmpty) {
    throw ContractException(
      'Payload codec library does not analyze: ${analysisErrors.join('; ')}',
    );
  }

  final bindings = <String, PayloadBinding>{};
  for (final declaration
      in result.unit.declarations.whereType<ClassDeclaration>()) {
    Annotation? payloadAnnotation;
    for (final annotation in declaration.metadata) {
      if (annotation.name.name == 'ConvexPayload') {
        payloadAnnotation = annotation;
        break;
      }
    }
    if (payloadAnnotation == null) continue;
    final arguments = payloadAnnotation.arguments?.arguments;
    if (arguments == null ||
        arguments.length != 1 ||
        arguments.single is! SimpleStringLiteral) {
      throw ContractException(
        '${declaration.name.lexeme} must use @ConvexPayload with one string tag',
      );
    }
    final tag = (arguments.single as SimpleStringLiteral).value;
    String? dartType;
    final interfaces = declaration.implementsClause?.interfaces ?? const [];
    for (final interface in interfaces) {
      if (interface.name2.lexeme != 'ConvexPayloadCodec') continue;
      final typeArguments = interface.typeArguments?.arguments;
      if (typeArguments == null || typeArguments.length != 1) {
        throw ContractException(
          '${declaration.name.lexeme} must implement ConvexPayloadCodec<T>',
        );
      }
      dartType = typeArguments.single.toSource();
    }
    if (dartType == null) {
      throw ContractException(
        '${declaration.name.lexeme} must directly implement ConvexPayloadCodec<T>',
      );
    }
    if (bindings.containsKey(tag)) {
      throw ContractException('Duplicate payload binding for tag $tag');
    }
    bindings[tag] = PayloadBinding(
      tag: tag,
      codecClass: declaration.name.lexeme,
      dartType: dartType,
    );
  }
  return Map.unmodifiable(bindings);
}
