@TestOn('vm')
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:icarus_library/src/cloud/evidence.dart';
import 'package:test/test.dart';

String _name(Symbol symbol) => MirrorSystem.getName(symbol);

void main() {
  final library = reflectClass(Evidence).owner! as LibraryMirror;

  test('the evidence file is a library of its own: nothing is part of it and '
      'it is part of nothing, so its private state is out of reach of every '
      'other file', () {
    final source = File('lib/src/cloud/evidence.dart').readAsStringSync();
    expect(RegExp(r'^\s*part\b', multiLine: true).hasMatch(source), isFalse);
    final others = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.endsWith('evidence.dart'));
    for (final file in others) {
      expect(
        file.readAsStringSync().contains(
          RegExp(r"part\s+(of\s+)?'[^']*evidence\.dart'"),
        ),
        isFalse,
        reason: file.path,
      );
    }
  });

  test('outside code can ask the evidence only to take a read, to prove a '
      'claim, and to give or read back its stored text', () {
    final evidence = reflectClass(Evidence);
    final public = {
      for (final MapEntry(:key, :value) in evidence.declarations.entries)
        if (!value.isPrivate) _name(key),
    };
    expect(public, {
      'none',
      'lastRead',
      'take',
      'proves',
      'groupTexts',
      'fromGroupTexts',
      'readsBack',
      '==',
      'hashCode',
    });
    final members = evidence.instanceMembers.values
        .where((member) => !member.isPrivate)
        .where((member) => member.owner == evidence);
    for (final member in members) {
      final returned = member.returnType;
      if (returned is ClassMirror && _name(member.simpleName) != 'groupTexts') {
        expect(
          returned.isSubtypeOf(reflectType(Map)) ||
              returned.isSubtypeOf(reflectType(Iterable)),
          isFalse,
          reason: '${_name(member.simpleName)} would hand out a collection',
        );
      }
    }
  });

  test('every claim says which read it must come after', () {
    final claim = reflectClass(Claim);
    final claims = library.declarations.values.whereType<ClassMirror>().where(
      (type) => type != claim && type.isSubclassOf(claim),
    );
    expect(claims, isNotEmpty);
    for (final type in claims) {
      final constructors = type.declarations.values
          .whereType<MethodMirror>()
          .where((method) => method.isConstructor);
      for (final constructor in constructors) {
        final after = constructor.parameters.where(
          (parameter) => _name(parameter.simpleName) == 'after',
        );
        expect(after, hasLength(1), reason: _name(type.simpleName));
        expect(after.single.isNamed, isTrue);
        expect(after.single.hasDefaultValue, isFalse);
      }
    }
  });
}
