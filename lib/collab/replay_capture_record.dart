import 'dart:convert';

import 'package:icarus/collab/collab_models.dart';
import 'package:uuid/uuid.dart';

/// Why a replay capture couldn't be saved.
enum CaptureFailureKind {
  /// The server refused it. Retry sends it again under new op ids.
  refused,

  /// Its strategy was deleted. Nothing more can go there.
  deleted,

  /// Its strategy is on another map now, so the replay's positions would be
  /// wrong there.
  mapChanged,

  /// Its page reached the strategy and was deleted there before all of its
  /// items did.
  pageDeleted,
}

/// One replay moment captured into a cloud strategy and not yet saved
/// there: the page, everything on it, and every id the server will see,
/// fixed when it was captured. Until it is delivered this is the only copy
/// of the player's capture, so it is kept like library data.
///
/// It is stored as one JSON string in its own box, keyed by [id]. A record
/// this build can't read stays in the box as it is.
class ReplayCaptureRecord {
  const ReplayCaptureRecord({
    required this.id,
    required this.accountId,
    required this.strategyId,
    required this.clientId,
    required this.strategyName,
    required this.mapData,
    required this.folderId,
    required this.themeProfileId,
    required this.index,
    required this.createsStrategy,
    required this.createdAt,
    required this.pageId,
    required this.pageName,
    required this.isAttack,
    required this.settings,
    required this.pageOpId,
    required this.items,
    this.pageLanded = false,
    this.landedItemOpIds = const {},
    this.uncertain = false,
    this.failure,
    this.failureDetail,
  });

  static const version = 1;

  final String id;

  /// The account whose library it goes to. It is sent only while that
  /// account is signed in.
  final String accountId;

  /// The strategy the replay session fills, and the client id its batches
  /// are sent under (the server's op dedupe is per client id).
  final String strategyId;
  final String clientId;

  /// What the strategy is made with, if this capture makes it.
  final String strategyName;
  final String mapData;
  final String? folderId;
  final String? themeProfileId;

  /// Its place among the session's captures. Captures of one strategy are
  /// delivered in this order.
  final int index;

  /// Whether this capture makes the strategy, with its page as the first.
  final bool createsStrategy;
  final DateTime createdAt;

  final String pageId;
  final String pageName;
  final bool isAttack;
  final Map<String, dynamic> settings;

  /// The op id the page is added under. A new one is made when the server
  /// refused the last (it would replay that refusal otherwise).
  final String pageOpId;

  /// The page's players and utility, as the ops that add them.
  final List<StrategyOp> items;

  final bool pageLanded;
  final Set<String> landedItemOpIds;

  /// The last send's answer was lost (a timeout, the connection): it may
  /// have landed. It is sent again as it was.
  final bool uncertain;

  final CaptureFailureKind? failure;

  /// The server's reason, when it refused.
  final String? failureDetail;

  bool get isFailed => failure != null;

  /// Whether some of it may already be in the cloud library.
  bool get mayHaveLanded =>
      uncertain || pageLanded || landedItemOpIds.isNotEmpty;

  List<StrategyOp> get unlandedItems => [
        for (final op in items)
          if (!landedItemOpIds.contains(op.opId)) op,
      ];

  ReplayCaptureRecord copyWith({
    bool? createsStrategy,
    String? pageOpId,
    List<StrategyOp>? items,
    bool? pageLanded,
    Set<String>? landedItemOpIds,
    bool? uncertain,
    CaptureFailureKind? failure,
    String? failureDetail,
    bool clearFailure = false,
    bool clearFolder = false,
  }) {
    return ReplayCaptureRecord(
      id: id,
      accountId: accountId,
      strategyId: strategyId,
      clientId: clientId,
      strategyName: strategyName,
      mapData: mapData,
      folderId: clearFolder ? null : folderId,
      themeProfileId: themeProfileId,
      index: index,
      createsStrategy: createsStrategy ?? this.createsStrategy,
      createdAt: createdAt,
      pageId: pageId,
      pageName: pageName,
      isAttack: isAttack,
      settings: settings,
      pageOpId: pageOpId ?? this.pageOpId,
      items: items ?? this.items,
      pageLanded: pageLanded ?? this.pageLanded,
      landedItemOpIds: landedItemOpIds ?? this.landedItemOpIds,
      uncertain: uncertain ?? this.uncertain,
      failure: clearFailure ? null : failure ?? this.failure,
      failureDetail: clearFailure ? null : failureDetail ?? this.failureDetail,
    );
  }

  /// Ready to send again after the server refused it: whatever didn't land
  /// goes under new op ids, since the server answers a repeated op id with
  /// its first answer.
  ReplayCaptureRecord forRetry() {
    const uuid = Uuid();
    return copyWith(
      pageOpId: pageLanded ? pageOpId : uuid.v4(),
      items: [
        for (final op in items)
          landedItemOpIds.contains(op.opId)
              ? op
              : StrategyOp.fromJson({...op.toConvexJson(), 'opId': uuid.v4()}),
      ],
      uncertain: false,
      clearFailure: true,
    );
  }

  String encode() => jsonEncode({
        'version': version,
        'id': id,
        'accountId': accountId,
        'strategyId': strategyId,
        'clientId': clientId,
        'strategyName': strategyName,
        'mapData': mapData,
        'folderId': folderId,
        'themeProfileId': themeProfileId,
        'index': index,
        'createsStrategy': createsStrategy,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'pageId': pageId,
        'pageName': pageName,
        'isAttack': isAttack,
        'settings': settings,
        'pageOpId': pageOpId,
        'items': [for (final op in items) op.toConvexJson()],
        'pageLanded': pageLanded,
        'landedItemOpIds': landedItemOpIds.toList(),
        'uncertain': uncertain,
        'failure': failure?.name,
        'failureDetail': failureDetail,
      });

  /// Reads a stored record. Throws on anything this build doesn't know,
  /// including a newer version, so the caller keeps it untouched.
  static ReplayCaptureRecord decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    if (json['version'] != version) {
      throw FormatException('Unknown capture record version', json['version']);
    }
    final failure = json['failure'] as String?;
    return ReplayCaptureRecord(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      strategyId: json['strategyId'] as String,
      clientId: json['clientId'] as String,
      strategyName: json['strategyName'] as String,
      mapData: json['mapData'] as String,
      folderId: json['folderId'] as String?,
      themeProfileId: json['themeProfileId'] as String?,
      index: json['index'] as int,
      createsStrategy: json['createsStrategy'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      pageId: json['pageId'] as String,
      pageName: json['pageName'] as String,
      isAttack: json['isAttack'] as bool,
      settings: Map<String, dynamic>.from(json['settings'] as Map),
      pageOpId: json['pageOpId'] as String,
      items: [
        for (final op in json['items'] as List)
          StrategyOp.fromJson(Map<String, dynamic>.from(op as Map)),
      ],
      pageLanded: json['pageLanded'] as bool,
      landedItemOpIds: {
        for (final opId in json['landedItemOpIds'] as List) opId as String,
      },
      uncertain: json['uncertain'] as bool,
      failure:
          failure == null ? null : CaptureFailureKind.values.byName(failure),
      failureDetail: json['failureDetail'] as String?,
    );
  }
}
