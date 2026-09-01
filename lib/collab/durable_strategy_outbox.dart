import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';

const durableOutboxRecordVersion = 2;
const durableOutboxVersionKey = '__outbox_record_version__';

Future<void> prepareDurableStrategyOutbox() async {
  final box = Hive.box<dynamic>(HiveBoxNames.strategyOutboxBox);
  if (box.get(durableOutboxVersionKey) == durableOutboxRecordVersion) return;
  await box.clear();
  await box.put(durableOutboxVersionKey, durableOutboxRecordVersion);
}

enum DurableOutboxStatus { queued, inFlight, paused, attention }

class DurableOutboxRecord {
  const DurableOutboxRecord({
    required this.accountId,
    required this.strategyPublicId,
    required this.entityKey,
    required this.pending,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.successorPending,
    this.lastError,
    this.latestServerRevision,
  });

  final String accountId;
  final String strategyPublicId;
  final EntitySyncKey entityKey;
  final PendingOp pending;
  final DurableOutboxStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final PendingOp? successorPending;
  final String? lastError;
  final int? latestServerRevision;

  String get storageKey => createStorageKey(
        accountId: accountId,
        strategyPublicId: strategyPublicId,
        entityKey: entityKey,
      );

  static String createStorageKey({
    required String accountId,
    required String strategyPublicId,
    required EntitySyncKey entityKey,
  }) {
    return '${Uri.encodeComponent(accountId)}|'
        '${Uri.encodeComponent(strategyPublicId)}|$entityKey';
  }

  DurableOutboxRecord copyWith({
    PendingOp? pending,
    DurableOutboxStatus? status,
    DateTime? updatedAt,
    PendingOp? successorPending,
    bool clearSuccessorPending = false,
    String? lastError,
    bool clearError = false,
    int? latestServerRevision,
    bool clearLatestServerRevision = false,
  }) {
    return DurableOutboxRecord(
      accountId: accountId,
      strategyPublicId: strategyPublicId,
      entityKey: entityKey,
      pending: pending ?? this.pending,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      successorPending: clearSuccessorPending
          ? null
          : (successorPending ?? this.successorPending),
      lastError: clearError ? null : (lastError ?? this.lastError),
      latestServerRevision: clearLatestServerRevision
          ? null
          : (latestServerRevision ?? this.latestServerRevision),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'outboxVersion': durableOutboxRecordVersion,
        'accountId': accountId,
        'strategyPublicId': strategyPublicId,
        'entityKey': entityKey.toString(),
        'clientId': pending.clientId,
        'opId': pending.op.opId,
        'op': pending.op.toConvexJson(),
        'attempts': pending.attempts,
        if (pending.lastAttemptAt != null)
          'lastAttemptAt': pending.lastAttemptAt!.toUtc().toIso8601String(),
        if (successorPending != null)
          'successorPending': _pendingToJson(successorPending!),
        'status': status.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (lastError != null) 'lastError': lastError,
        if (latestServerRevision != null)
          'latestServerRevision': latestServerRevision,
      };

  factory DurableOutboxRecord.fromJson(Map<String, dynamic> json) {
    final version = (json['outboxVersion'] as num?)?.toInt();
    if (version != durableOutboxRecordVersion) {
      throw FormatException('Unsupported outbox record version: $version');
    }
    final opJson = _object(json['op'], field: 'op');
    final op = StrategyOp.fromJson(opJson);
    if (json['opId'] != op.opId) {
      throw const FormatException('Outbox opId does not match serialized op');
    }
    final entityKey = EntitySyncKey.forStrategyOp(op);
    if (entityKey == null || entityKey.toString() != json['entityKey']) {
      throw const FormatException('Outbox entity key does not match op');
    }
    final successor = json['successorPending'] == null
        ? null
        : _pendingFromJson(
            _object(json['successorPending'], field: 'successorPending'),
          );
    if (successor != null &&
        EntitySyncKey.forStrategyOp(successor.op) != entityKey) {
      throw const FormatException(
        'Outbox successor entity key does not match op',
      );
    }
    return DurableOutboxRecord(
      accountId: _nonEmptyString(json['accountId'], field: 'accountId'),
      strategyPublicId:
          _nonEmptyString(json['strategyPublicId'], field: 'strategyPublicId'),
      entityKey: entityKey,
      pending: PendingOp(
        op: op,
        clientId: _nonEmptyString(json['clientId'], field: 'clientId'),
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        lastAttemptAt: _optionalDate(json['lastAttemptAt']),
      ),
      successorPending: successor,
      status: DurableOutboxStatus.values.byName(
        _nonEmptyString(json['status'], field: 'status'),
      ),
      createdAt: _requiredDate(json['createdAt'], field: 'createdAt'),
      updatedAt: _requiredDate(json['updatedAt'], field: 'updatedAt'),
      lastError: json['lastError'] as String?,
      latestServerRevision: (json['latestServerRevision'] as num?)?.toInt(),
    );
  }

  static Map<String, dynamic> _pendingToJson(PendingOp value) =>
      <String, dynamic>{
        'clientId': value.clientId,
        'opId': value.op.opId,
        'op': value.op.toConvexJson(),
        'attempts': value.attempts,
        if (value.lastAttemptAt != null)
          'lastAttemptAt': value.lastAttemptAt!.toUtc().toIso8601String(),
      };

  static PendingOp _pendingFromJson(Map<String, dynamic> json) {
    final op = StrategyOp.fromJson(_object(json['op'], field: 'successor op'));
    if (json['opId'] != op.opId) {
      throw const FormatException(
        'Outbox successor opId does not match serialized op',
      );
    }
    return PendingOp(
      op: op,
      clientId: _nonEmptyString(json['clientId'], field: 'successor clientId'),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastAttemptAt: _optionalDate(json['lastAttemptAt']),
    );
  }

  static Map<String, dynamic> _object(Object? value, {required String field}) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    throw FormatException('Outbox $field must be an object');
  }

  static String _nonEmptyString(Object? value, {required String field}) {
    if (value is String && value.isNotEmpty) return value;
    throw FormatException('Outbox $field must be a non-empty string');
  }

  static DateTime _requiredDate(Object? value, {required String field}) {
    final parsed = _optionalDate(value);
    if (parsed != null) return parsed;
    throw FormatException('Outbox $field must be an ISO-8601 date');
  }

  static DateTime? _optionalDate(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toLocal();
  }
}

class DurableOutboxLoadIssue {
  const DurableOutboxLoadIssue({required this.storageKey, required this.error});

  final String storageKey;
  final String error;
}

class DurableOutboxLoadResult {
  const DurableOutboxLoadResult({required this.records, required this.issues});

  final List<DurableOutboxRecord> records;
  final List<DurableOutboxLoadIssue> issues;
}

abstract class DurableStrategyOutboxStore {
  DurableOutboxLoadResult load();
  Future<void> put(DurableOutboxRecord record);
  Future<void> remove(String storageKey);
}

class HiveDurableStrategyOutboxStore implements DurableStrategyOutboxStore {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.strategyOutboxBox);

  @override
  DurableOutboxLoadResult load() {
    final records = <DurableOutboxRecord>[];
    final issues = <DurableOutboxLoadIssue>[];
    for (final key in _box.keys) {
      final storageKey = key.toString();
      if (storageKey == durableOutboxVersionKey) continue;
      try {
        final raw = _box.get(key);
        final decoded = raw is String ? jsonDecode(raw) : raw;
        final json = decoded is Map<String, dynamic>
            ? decoded
            : Map<String, dynamic>.from(decoded as Map);
        final record = DurableOutboxRecord.fromJson(json);
        if (record.storageKey != storageKey) {
          throw const FormatException(
              'Outbox storage key does not match record');
        }
        records.add(record);
      } catch (error) {
        issues.add(DurableOutboxLoadIssue(
          storageKey: storageKey,
          error: error.toString(),
        ));
      }
    }
    return DurableOutboxLoadResult(records: records, issues: issues);
  }

  @override
  Future<void> put(DurableOutboxRecord record) {
    final jsonSafe = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(record.toJson())) as Map,
    );
    return _box.put(record.storageKey, jsonSafe);
  }

  @override
  Future<void> remove(String storageKey) => _box.delete(storageKey);
}

class MemoryDurableStrategyOutboxStore implements DurableStrategyOutboxStore {
  MemoryDurableStrategyOutboxStore([
    Map<String, Object?>? initialValues,
  ]) : values = Map<String, Object?>.from(initialValues ?? const {});

  final Map<String, Object?> values;

  @override
  DurableOutboxLoadResult load() {
    final records = <DurableOutboxRecord>[];
    final issues = <DurableOutboxLoadIssue>[];
    for (final entry in values.entries) {
      try {
        final value = entry.value;
        final json = value is Map<String, dynamic>
            ? value
            : Map<String, dynamic>.from(value as Map);
        final record = DurableOutboxRecord.fromJson(json);
        if (record.storageKey != entry.key) {
          throw const FormatException(
              'Outbox storage key does not match record');
        }
        records.add(record);
      } catch (error) {
        issues.add(DurableOutboxLoadIssue(
          storageKey: entry.key,
          error: error.toString(),
        ));
      }
    }
    return DurableOutboxLoadResult(records: records, issues: issues);
  }

  @override
  Future<void> put(DurableOutboxRecord record) async {
    values[record.storageKey] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(record.toJson())) as Map,
    );
  }

  @override
  Future<void> remove(String storageKey) async {
    values.remove(storageKey);
  }
}

final durableStrategyOutboxStoreProvider = Provider<DurableStrategyOutboxStore>(
  (ref) => HiveDurableStrategyOutboxStore(),
);
