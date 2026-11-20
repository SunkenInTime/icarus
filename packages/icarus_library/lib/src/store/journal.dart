import 'dart:convert';

import '../json.dart';
import '../wire.dart';
import 'engine.dart';
import 'layout.dart';

const journalVersion = 1;

sealed class KeyWrite {
  const KeyWrite(this.area, this.key);

  final String area;
  final String key;
}

final class PutKey extends KeyWrite {
  const PutKey(super.area, super.key, this.value);

  final String value;
}

final class DeleteKey extends KeyWrite {
  const DeleteKey(super.area, super.key);
}

final class KeyWrites {
  final _writes = <(String, String), KeyWrite>{};

  void put(String area, String key, String value) =>
      _writes[(area, key)] = PutKey(area, key, value);

  void delete(String area, String key) =>
      _writes[(area, key)] = DeleteKey(area, key);

  void dropArea(String area) => _writes.removeWhere((key, _) => key.$1 == area);

  List<KeyWrite> get writes => List.unmodifiable(_writes.values);
}

final class JournalRecord {
  JournalRecord({
    required this.attempt,
    required this.issuedAt,
    required Map<String, Object?> edit,
    required List<KeyWrite> writes,
  }) : edit = frozenJsonObject(edit),
       writes = List.unmodifiable(writes);

  final String attempt;
  final DateTime issuedAt;
  final Map<String, Object?> edit;
  final List<KeyWrite> writes;

  String encode() => jsonEncode({
    'journalVersion': journalVersion,
    'attempt': attempt,
    'issuedAt': issuedAt.millisecondsSinceEpoch,
    'edit': edit,
    'writes': [
      for (final write in writes)
        switch (write) {
          PutKey(:final area, :final key, :final value) => {
            'area': area,
            'key': key,
            'value': value,
          },
          DeleteKey(:final area, :final key) => {
            'area': area,
            'key': key,
            'delete': true,
          },
        },
    ],
  });

  static Decoded<JournalRecord> decode(Admission stored) => switch (stored) {
    NotAdmitted(:final text, :final problem) => CouldNotRead(text, problem),
    Admitted(:final json) => _decode(json),
  };

  static Decoded<JournalRecord> _decode(Object? json) =>
      JsonFields.read(json, 'saved edit', (fields) {
        if (fields.whole('journalVersion') != journalVersion) {
          fields.reject('a saved edit from a newer build');
        }
        final attempt = fields.string('attempt');
        if (readJournalKey(recoveredKey(attempt)) is! RecoveredAt) {
          fields.reject('an attempt id this build does not issue');
        }
        final issuedAt = fields.time('issuedAt');
        final edit = fields.object('edit');
        final writes = <KeyWrite>[];
        switch (fields.json['writes']) {
          case final List<Object?> entries:
            for (final entry in entries) {
              switch (entry) {
                case {
                  'area': final String area,
                  'key': final String key,
                  'value': final String value,
                }:
                  writes.add(PutKey(area, key, value));
                case {
                  'area': final String area,
                  'key': final String key,
                  'delete': true,
                }:
                  writes.add(DeleteKey(area, key));
                case _:
                  fields.reject('expected a key write');
              }
            }
          case _:
            fields.reject('expected writes');
        }
        return () => JournalRecord(
          attempt: attempt,
          issuedAt: issuedAt,
          edit: edit,
          writes: writes,
        );
      });

  Future<Stored<void>> replay(StorageLease lease) async {
    final puts = <String, Map<String, String>>{};
    final deletes = <String, List<String>>{};
    for (final write in writes) {
      switch (write) {
        case PutKey(:final area, :final key, :final value):
          (puts[area] ??= {})[key] = value;
        case DeleteKey(:final area, :final key):
          (deletes[area] ??= []).add(key);
      }
    }
    for (final MapEntry(key: area, value: values) in puts.entries) {
      if (await lease.write(area, values) case StorageFailed(:final failure)) {
        return StorageFailed(failure);
      }
    }
    for (final MapEntry(key: area, value: keys) in deletes.entries) {
      if (await lease.delete(area, keys) case StorageFailed(:final failure)) {
        return StorageFailed(failure);
      }
    }
    return done;
  }

  Future<Stored<void>> save(StorageLease lease) =>
      lease.write(journalArea, {journalKey: encode()});

  Future<Stored<void>> recover(StorageLease lease) async {
    if (await replay(lease) case StorageFailed(:final failure)) {
      return StorageFailed(failure);
    }
    return lease.write(journalArea, {
      recoveredKey(attempt): '${issuedAt.millisecondsSinceEpoch}',
    });
  }

  static Future<Stored<void>> clear(StorageLease lease) =>
      lease.delete(journalArea, const [journalKey]);
}
