// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated from convex/function_spec.json by tool/icarus_convex_codegen.
// ignore_for_file: prefer_const_constructors, unused_element, unused_import

import 'dart:typed_data';

import '../convex_payload_codecs.dart';
import '../transport/convex_transport.dart';

final class ConvexOptional<T> {
  const ConvexOptional.absent() : isPresent = false, _value = null;
  const ConvexOptional.present(T value) : isPresent = true, _value = value;

  final bool isPresent;
  final T? _value;

  T get value {
    if (!isPresent) throw StateError('Optional value is absent');
    return _value as T;
  }
}

final class ConvexDecodingException extends FormatException {
  ConvexDecodingException(this.path, String message) : super('$path: $message');
  final String path;
}

final class ConvexEncodingException extends FormatException {
  ConvexEncodingException(this.path, String message) : super('$path: $message');
  final String path;
}

Never _missing(String path, String field) =>
    throw ConvexDecodingException('$path.$field', 'missing required field');

String _fieldPath(String path, String field) => '$path.$field';

String _indexPath(String path, int index) => '$path[$index]';

void _checkObjectFields(ConvexObject object, String path, Set<String> allowed) {
  for (final field in object.value.keys) {
    if (!allowed.contains(field)) {
      throw ConvexDecodingException('$path.$field', 'unexpected field');
    }
  }
}

Null _decodeNull(ConvexValue value, String path) {
  if (value is ConvexNull) return null;
  throw ConvexDecodingException(path, 'expected null');
}

bool _decodeBoolean(ConvexValue value, String path) {
  if (value case ConvexBoolean(:final value)) return value;
  throw ConvexDecodingException(path, 'expected boolean');
}

double _decodeNumber(ConvexValue value, String path) {
  if (value case ConvexFloat(:final value)) return value;
  if (value case ConvexInteger(:final value)) return value.toDouble();
  throw ConvexDecodingException(path, 'expected number');
}

ConvexValue _encodeNumber(double value, String path) {
  return ConvexFloat(value);
}

BigInt _decodeBigInt(ConvexValue value, String path) {
  if (value case ConvexBigInt(:final value)) return value;
  throw ConvexDecodingException(path, 'expected bigint');
}

String _decodeString(ConvexValue value, String path) {
  if (value case ConvexString(:final value)) return value;
  throw ConvexDecodingException(path, 'expected string');
}

Uint8List _decodeBytes(ConvexValue value, String path) {
  if (value case ConvexBytes(:final value)) return Uint8List.fromList(value);
  throw ConvexDecodingException(path, 'expected bytes');
}

ConvexArray _decodeArray(ConvexValue value, String path) {
  if (value is ConvexArray) return value;
  throw ConvexDecodingException(path, 'expected array');
}

ConvexObject _decodeObject(ConvexValue value, String path) {
  if (value is ConvexObject) return value;
  throw ConvexDecodingException(path, 'expected object');
}

T _expectLiteral<T>(T value, T expected, String path) {
  if (value == expected) return value;
  throw ConvexDecodingException(path, 'expected literal $expected');
}

T _decodePayload<T>(T Function() decode, String path) {
  try {
    return decode();
  } on FormatException catch (error) {
    throw ConvexDecodingException(path, error.message);
  }
}

ConvexValue _encodePayload(ConvexValue Function() encode, String path) {
  try {
    return encode();
  } on FormatException catch (error) {
    throw ConvexEncodingException(path, error.message);
  }
}

ConvexValue _decodeRaw(
  ConvexValue value,
  String path,
  bool Function(ConvexValue) accepts,
) {
  if (accepts(value)) return value;
  throw ConvexDecodingException(path, 'value does not satisfy closed union');
}

enum ElementsListForPageResultItemElementType {
  ability('ability'),
  agent('agent'),
  drawing('drawing'),
  image('image'),
  text('text'),
  utility('utility');

  const ElementsListForPageResultItemElementType(this.wireName);
  final String wireName;

  static ElementsListForPageResultItemElementType fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown ElementsListForPageResultItemElementType $wireName',
    );
  }
}

enum FoldersListTreeArgsScope {
  all('all'),
  owned('owned'),
  shared('shared');

  const FoldersListTreeArgsScope(this.wireName);
  final String wireName;

  static FoldersListTreeArgsScope fromWireName(String wireName, String path) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown FoldersListTreeArgsScope $wireName',
    );
  }
}

enum FoldersListTreeResultItemRole {
  editor('editor'),
  owner('owner'),
  viewer('viewer');

  const FoldersListTreeResultItemRole(this.wireName);
  final String wireName;

  static FoldersListTreeResultItemRole fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown FoldersListTreeResultItemRole $wireName',
    );
  }
}

enum HealthPingResult {
  ok('ok');

  const HealthPingResult(this.wireName);
  final String wireName;

  static HealthPingResult fromWireName(String wireName, String path) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(path, 'unknown HealthPingResult $wireName');
  }
}

enum ImagesCompleteUploadArgsProvider {
  convex('convex'),
  r2('r2');

  const ImagesCompleteUploadArgsProvider(this.wireName);
  final String wireName;

  static ImagesCompleteUploadArgsProvider fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown ImagesCompleteUploadArgsProvider $wireName',
    );
  }
}

enum ImagesGenerateUploadUrlResultProvider {
  r2('r2');

  const ImagesGenerateUploadUrlResultProvider(this.wireName);
  final String wireName;

  static ImagesGenerateUploadUrlResultProvider fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown ImagesGenerateUploadUrlResultProvider $wireName',
    );
  }
}

enum ImagesListForStrategyResultItemUploadStatus {
  active('active'),
  deleted('deleted'),
  failed('failed'),
  pending('pending');

  const ImagesListForStrategyResultItemUploadStatus(this.wireName);
  final String wireName;

  static ImagesListForStrategyResultItemUploadStatus fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown ImagesListForStrategyResultItemUploadStatus $wireName',
    );
  }
}

enum InvitesCreateArgsRole {
  editor('editor'),
  viewer('viewer');

  const InvitesCreateArgsRole(this.wireName);
  final String wireName;

  static InvitesCreateArgsRole fromWireName(String wireName, String path) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown InvitesCreateArgsRole $wireName',
    );
  }
}

enum OpsApplyBatchResultResultsItemRejectedReason {
  alreadyExists('already_exists'),
  elementStrategyMismatch('element_strategy_mismatch'),
  lineupStrategyMismatch('lineup_strategy_mismatch'),
  missingExpectedRevision('missing_expected_revision'),
  notFound('not_found'),
  pageStrategyMismatch('page_strategy_mismatch'),
  revisionMismatch('revision_mismatch');

  const OpsApplyBatchResultResultsItemRejectedReason(this.wireName);
  final String wireName;

  static OpsApplyBatchResultResultsItemRejectedReason fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown OpsApplyBatchResultResultsItemRejectedReason $wireName',
    );
  }
}

enum SharesCreateArgsTargetType {
  folder('folder'),
  strategy('strategy');

  const SharesCreateArgsTargetType(this.wireName);
  final String wireName;

  static SharesCreateArgsTargetType fromWireName(String wireName, String path) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown SharesCreateArgsTargetType $wireName',
    );
  }
}

enum StrategiesListForFolderResultItemAttackLabel {
  attack('Attack'),
  defend('Defend'),
  mixed('Mixed'),
  unknown('Unknown');

  const StrategiesListForFolderResultItemAttackLabel(this.wireName);
  final String wireName;

  static StrategiesListForFolderResultItemAttackLabel fromWireName(
    String wireName,
    String path,
  ) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    throw ConvexDecodingException(
      path,
      'unknown StrategiesListForFolderResultItemAttackLabel $wireName',
    );
  }
}

sealed class ImagesCompleteUploadResult {
  const ImagesCompleteUploadResult();

  factory ImagesCompleteUploadResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    final discriminator = _decodeString(
      object.value['provider'] ?? _missing(path, 'provider'),
      '$path.provider',
    );
    return switch (discriminator) {
      'convex' => ImagesCompleteUploadResultConvex.decode(value, path),
      'r2' => ImagesCompleteUploadResultR2.decode(value, path),
      _ => throw ConvexDecodingException(
        path,
        'unknown discriminator $discriminator',
      ),
    };
  }

  ConvexObject encode(String path);
}

sealed class OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItem();

  factory OpsApplyBatchArgsOpsItem.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    final discriminator = _decodeString(
      object.value['type'] ?? _missing(path, 'type'),
      '$path.type',
    );
    return switch (discriminator) {
      'strategy.patch' => OpsApplyBatchArgsOpsItemStrategyPatch.decode(
        value,
        path,
      ),
      'page.add' => OpsApplyBatchArgsOpsItemPageAdd.decode(value, path),
      'page.patch' => OpsApplyBatchArgsOpsItemPagePatch.decode(value, path),
      'page.delete' => OpsApplyBatchArgsOpsItemPageDelete.decode(value, path),
      'page.reorder' => OpsApplyBatchArgsOpsItemPageReorder.decode(value, path),
      'pageContent.patch' => OpsApplyBatchArgsOpsItemPageContentPatch.decode(
        value,
        path,
      ),
      'element.add' => OpsApplyBatchArgsOpsItemElementAdd.decode(value, path),
      'element.patch' => OpsApplyBatchArgsOpsItemElementPatch.decode(
        value,
        path,
      ),
      'element.delete' => OpsApplyBatchArgsOpsItemElementDelete.decode(
        value,
        path,
      ),
      'element.reorder' => OpsApplyBatchArgsOpsItemElementReorder.decode(
        value,
        path,
      ),
      'lineup.add' => OpsApplyBatchArgsOpsItemLineupAdd.decode(value, path),
      'lineup.patch' => OpsApplyBatchArgsOpsItemLineupPatch.decode(value, path),
      'lineup.delete' => OpsApplyBatchArgsOpsItemLineupDelete.decode(
        value,
        path,
      ),
      'lineup.reorder' => OpsApplyBatchArgsOpsItemLineupReorder.decode(
        value,
        path,
      ),
      _ => throw ConvexDecodingException(
        path,
        'unknown discriminator $discriminator',
      ),
    };
  }

  ConvexObject encode(String path);
}

sealed class OpsApplyBatchResultResultsItem {
  const OpsApplyBatchResultResultsItem();

  factory OpsApplyBatchResultResultsItem.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    final discriminator = _decodeString(
      object.value['status'] ?? _missing(path, 'status'),
      '$path.status',
    );
    return switch (discriminator) {
      'applied' => OpsApplyBatchResultResultsItemApplied.decode(value, path),
      'noop' => OpsApplyBatchResultResultsItemNoop.decode(value, path),
      'rejected' => OpsApplyBatchResultResultsItemRejected.decode(value, path),
      'failed' => OpsApplyBatchResultResultsItemFailed.decode(value, path),
      _ => throw ConvexDecodingException(
        path,
        'unknown discriminator $discriminator',
      ),
    };
  }

  ConvexObject encode(String path);
}

sealed class OpsApplyBatchResultResultsItemRejectedCurrent {
  const OpsApplyBatchResultResultsItemRejectedCurrent();

  factory OpsApplyBatchResultResultsItemRejectedCurrent.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    final discriminator = _decodeString(
      object.value['type'] ?? _missing(path, 'type'),
      '$path.type',
    );
    return switch (discriminator) {
      'strategy' =>
        OpsApplyBatchResultResultsItemRejectedCurrentStrategy.decode(
          value,
          path,
        ),
      'page' => OpsApplyBatchResultResultsItemRejectedCurrentPage.decode(
        value,
        path,
      ),
      'pageContent' =>
        OpsApplyBatchResultResultsItemRejectedCurrentPageContent.decode(
          value,
          path,
        ),
      'element' => OpsApplyBatchResultResultsItemRejectedCurrentElement.decode(
        value,
        path,
      ),
      'lineup' => OpsApplyBatchResultResultsItemRejectedCurrentLineup.decode(
        value,
        path,
      ),
      _ => throw ConvexDecodingException(
        path,
        'unknown discriminator $discriminator',
      ),
    };
  }

  ConvexObject encode(String path);
}

sealed class SharesRedeemResult {
  const SharesRedeemResult();

  factory SharesRedeemResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    final discriminator = _decodeString(
      object.value['targetType'] ?? _missing(path, 'targetType'),
      '$path.targetType',
    );
    return switch (discriminator) {
      'strategy' => SharesRedeemResultStrategy.decode(value, path),
      'folder' => SharesRedeemResultFolder.decode(value, path),
      _ => throw ConvexDecodingException(
        path,
        'unknown discriminator $discriminator',
      ),
    };
  }

  ConvexObject encode(String path);
}

final class ElementsListForPageResultItem {
  const ElementsListForPageResultItem({
    required this.createdAt,
    required this.deleted,
    required this.elementType,
    required this.pagePublicId,
    required this.payload,
    required this.publicId,
    required this.revision,
    required this.sortIndex,
    required this.strategyPublicId,
    required this.updatedAt,
  });
  final double createdAt;
  final bool deleted;
  final ElementsListForPageResultItemElementType elementType;
  final String pagePublicId;
  final CloudPayload payload;
  final String publicId;
  final double revision;
  final double sortIndex;
  final String strategyPublicId;
  final double updatedAt;

  factory ElementsListForPageResultItem.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'createdAt',
      'deleted',
      'elementType',
      'pagePublicId',
      'payload',
      'publicId',
      'revision',
      'sortIndex',
      'strategyPublicId',
      'updatedAt',
    });
    return ElementsListForPageResultItem(
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      deleted: _decodeBoolean(
        object.value['deleted'] ?? _missing(path, 'deleted'),
        '$path.deleted',
      ),
      elementType: ElementsListForPageResultItemElementType.fromWireName(
        _decodeString(
          object.value['elementType'] ?? _missing(path, 'elementType'),
          '$path.elementType',
        ),
        '$path.elementType',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      payload: _decodeElementsListForPageResultItemPayload(
        object.value['payload'] ?? _missing(path, 'payload'),
        '$path.payload',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'deleted': ConvexBoolean(deleted),
      'elementType': ConvexString(elementType.wireName),
      'pagePublicId': ConvexString(pagePublicId),
      'payload': _encodeElementsListForPageResultItemPayload(
        payload,
        '$path.payload',
      ),
      'publicId': ConvexString(publicId),
      'revision': _encodeNumber(revision, '$path.revision'),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
      'strategyPublicId': ConvexString(strategyPublicId),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class FoldersDeleteResult {
  const FoldersDeleteResult({required this.ok});
  final bool ok;

  factory FoldersDeleteResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'ok'});
    return FoldersDeleteResult(
      ok: _expectLiteral(
        _decodeBoolean(object.value['ok'] ?? _missing(path, 'ok'), '$path.ok'),
        true,
        '$path.ok',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'ok': ConvexBoolean(_expectLiteral(ok, true, '$path.ok')),
    });
  }
}

final class FoldersListTreeResultItem {
  const FoldersListTreeResultItem({
    required this.color,
    required this.createdAt,
    required this.customColorValue,
    required this.iconCodePoint,
    required this.iconFontFamily,
    required this.iconFontPackage,
    required this.iconId,
    required this.name,
    required this.parentFolderPublicId,
    required this.publicId,
    required this.role,
    required this.updatedAt,
  });
  final String? color;
  final double createdAt;
  final double? customColorValue;
  final double? iconCodePoint;
  final String? iconFontFamily;
  final String? iconFontPackage;
  final double? iconId;
  final String name;
  final String? parentFolderPublicId;
  final String publicId;
  final FoldersListTreeResultItemRole role;
  final double updatedAt;

  factory FoldersListTreeResultItem.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'color',
      'createdAt',
      'customColorValue',
      'iconCodePoint',
      'iconFontFamily',
      'iconFontPackage',
      'iconId',
      'name',
      'parentFolderPublicId',
      'publicId',
      'role',
      'updatedAt',
    });
    return FoldersListTreeResultItem(
      color: (object.value['color'] ?? _missing(path, 'color')) is ConvexNull
          ? null
          : _decodeString(
              object.value['color'] ?? _missing(path, 'color'),
              '$path.color',
            ),
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      customColorValue:
          (object.value['customColorValue'] ??
                  _missing(path, 'customColorValue'))
              is ConvexNull
          ? null
          : _decodeNumber(
              object.value['customColorValue'] ??
                  _missing(path, 'customColorValue'),
              '$path.customColorValue',
            ),
      iconCodePoint:
          (object.value['iconCodePoint'] ?? _missing(path, 'iconCodePoint'))
              is ConvexNull
          ? null
          : _decodeNumber(
              object.value['iconCodePoint'] ?? _missing(path, 'iconCodePoint'),
              '$path.iconCodePoint',
            ),
      iconFontFamily:
          (object.value['iconFontFamily'] ?? _missing(path, 'iconFontFamily'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['iconFontFamily'] ??
                  _missing(path, 'iconFontFamily'),
              '$path.iconFontFamily',
            ),
      iconFontPackage:
          (object.value['iconFontPackage'] ?? _missing(path, 'iconFontPackage'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['iconFontPackage'] ??
                  _missing(path, 'iconFontPackage'),
              '$path.iconFontPackage',
            ),
      iconId: (object.value['iconId'] ?? _missing(path, 'iconId')) is ConvexNull
          ? null
          : _decodeNumber(
              object.value['iconId'] ?? _missing(path, 'iconId'),
              '$path.iconId',
            ),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      parentFolderPublicId:
          (object.value['parentFolderPublicId'] ??
                  _missing(path, 'parentFolderPublicId'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['parentFolderPublicId'] ??
                  _missing(path, 'parentFolderPublicId'),
              '$path.parentFolderPublicId',
            ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      role: FoldersListTreeResultItemRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'color': color == null ? const ConvexNull() : ConvexString(color!),
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'customColorValue': customColorValue == null
          ? const ConvexNull()
          : _encodeNumber(customColorValue!, '$path.customColorValue'),
      'iconCodePoint': iconCodePoint == null
          ? const ConvexNull()
          : _encodeNumber(iconCodePoint!, '$path.iconCodePoint'),
      'iconFontFamily': iconFontFamily == null
          ? const ConvexNull()
          : ConvexString(iconFontFamily!),
      'iconFontPackage': iconFontPackage == null
          ? const ConvexNull()
          : ConvexString(iconFontPackage!),
      'iconId': iconId == null
          ? const ConvexNull()
          : _encodeNumber(iconId!, '$path.iconId'),
      'name': ConvexString(name),
      'parentFolderPublicId': parentFolderPublicId == null
          ? const ConvexNull()
          : ConvexString(parentFolderPublicId!),
      'publicId': ConvexString(publicId),
      'role': ConvexString(role.wireName),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class ImagesCompleteUploadResultConvex
    extends ImagesCompleteUploadResult {
  const ImagesCompleteUploadResultConvex({required this.ok});
  final bool ok;

  factory ImagesCompleteUploadResultConvex.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'provider', 'ok'});
    return ImagesCompleteUploadResultConvex(
      ok: _expectLiteral(
        _decodeBoolean(object.value['ok'] ?? _missing(path, 'ok'), '$path.ok'),
        true,
        '$path.ok',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'provider': ConvexString('convex'),
      'ok': ConvexBoolean(_expectLiteral(ok, true, '$path.ok')),
    });
  }
}

final class ImagesCompleteUploadResultR2 extends ImagesCompleteUploadResult {
  const ImagesCompleteUploadResultR2({required this.ok, required this.url});
  final bool ok;
  final String url;

  factory ImagesCompleteUploadResultR2.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'provider', 'ok', 'url'});
    return ImagesCompleteUploadResultR2(
      ok: _expectLiteral(
        _decodeBoolean(object.value['ok'] ?? _missing(path, 'ok'), '$path.ok'),
        true,
        '$path.ok',
      ),
      url: _decodeString(
        object.value['url'] ?? _missing(path, 'url'),
        '$path.url',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'provider': ConvexString('r2'),
      'ok': ConvexBoolean(_expectLiteral(ok, true, '$path.ok')),
      'url': ConvexString(url),
    });
  }
}

final class ImagesGenerateUploadUrlResult {
  const ImagesGenerateUploadUrlResult({
    required this.expiresAt,
    required this.maxBytes,
    required this.objectKey,
    required this.provider,
    required this.requiredHeaders,
    required this.uploadId,
    required this.uploadUrl,
  });
  final double expiresAt;
  final double maxBytes;
  final String objectKey;
  final ImagesGenerateUploadUrlResultProvider provider;
  final Map<String, String> requiredHeaders;
  final String uploadId;
  final String uploadUrl;

  factory ImagesGenerateUploadUrlResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'expiresAt',
      'maxBytes',
      'objectKey',
      'provider',
      'requiredHeaders',
      'uploadId',
      'uploadUrl',
    });
    return ImagesGenerateUploadUrlResult(
      expiresAt: _decodeNumber(
        object.value['expiresAt'] ?? _missing(path, 'expiresAt'),
        '$path.expiresAt',
      ),
      maxBytes: _decodeNumber(
        object.value['maxBytes'] ?? _missing(path, 'maxBytes'),
        '$path.maxBytes',
      ),
      objectKey: _decodeString(
        object.value['objectKey'] ?? _missing(path, 'objectKey'),
        '$path.objectKey',
      ),
      provider: ImagesGenerateUploadUrlResultProvider.fromWireName(
        _decodeString(
          object.value['provider'] ?? _missing(path, 'provider'),
          '$path.provider',
        ),
        '$path.provider',
      ),
      requiredHeaders: Map.unmodifiable(
        _decodeObject(
          object.value['requiredHeaders'] ?? _missing(path, 'requiredHeaders'),
          '$path.requiredHeaders',
        ).value.map(
          (key, item) => MapEntry(
            key,
            _decodeString(item, _fieldPath('$path.requiredHeaders', key)),
          ),
        ),
      ),
      uploadId: _decodeString(
        object.value['uploadId'] ?? _missing(path, 'uploadId'),
        '$path.uploadId',
      ),
      uploadUrl: _decodeString(
        object.value['uploadUrl'] ?? _missing(path, 'uploadUrl'),
        '$path.uploadUrl',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'expiresAt': _encodeNumber(expiresAt, '$path.expiresAt'),
      'maxBytes': _encodeNumber(maxBytes, '$path.maxBytes'),
      'objectKey': ConvexString(objectKey),
      'provider': ConvexString(provider.wireName),
      'requiredHeaders': ConvexObject(
        requiredHeaders.map((key, item) => MapEntry(key, ConvexString(item))),
      ),
      'uploadId': ConvexString(uploadId),
      'uploadUrl': ConvexString(uploadUrl),
    });
  }
}

final class ImagesGetAssetUrlResult {
  const ImagesGetAssetUrlResult({required this.url});
  final String? url;

  factory ImagesGetAssetUrlResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'url'});
    return ImagesGetAssetUrlResult(
      url: (object.value['url'] ?? _missing(path, 'url')) is ConvexNull
          ? null
          : _decodeString(
              object.value['url'] ?? _missing(path, 'url'),
              '$path.url',
            ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'url': url == null ? const ConvexNull() : ConvexString(url!),
    });
  }
}

final class ImagesListForStrategyResultItem {
  const ImagesListForStrategyResultItem({
    required this.byteSize,
    required this.fileExtension,
    required this.height,
    required this.legacyStoragePath,
    required this.mimeType,
    required this.provider,
    required this.publicId,
    required this.uploadedAt,
    required this.uploadStatus,
    required this.url,
    required this.width,
  });
  final double? byteSize;
  final String fileExtension;
  final double? height;
  final String? legacyStoragePath;
  final String? mimeType;
  final ImagesCompleteUploadArgsProvider provider;
  final String publicId;
  final double? uploadedAt;
  final ImagesListForStrategyResultItemUploadStatus uploadStatus;
  final String? url;
  final double? width;

  factory ImagesListForStrategyResultItem.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'byteSize',
      'fileExtension',
      'height',
      'legacyStoragePath',
      'mimeType',
      'provider',
      'publicId',
      'uploadedAt',
      'uploadStatus',
      'url',
      'width',
    });
    return ImagesListForStrategyResultItem(
      byteSize:
          (object.value['byteSize'] ?? _missing(path, 'byteSize')) is ConvexNull
          ? null
          : _decodeNumber(
              object.value['byteSize'] ?? _missing(path, 'byteSize'),
              '$path.byteSize',
            ),
      fileExtension: _decodeString(
        object.value['fileExtension'] ?? _missing(path, 'fileExtension'),
        '$path.fileExtension',
      ),
      height: (object.value['height'] ?? _missing(path, 'height')) is ConvexNull
          ? null
          : _decodeNumber(
              object.value['height'] ?? _missing(path, 'height'),
              '$path.height',
            ),
      legacyStoragePath:
          (object.value['legacyStoragePath'] ??
                  _missing(path, 'legacyStoragePath'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['legacyStoragePath'] ??
                  _missing(path, 'legacyStoragePath'),
              '$path.legacyStoragePath',
            ),
      mimeType:
          (object.value['mimeType'] ?? _missing(path, 'mimeType')) is ConvexNull
          ? null
          : _decodeString(
              object.value['mimeType'] ?? _missing(path, 'mimeType'),
              '$path.mimeType',
            ),
      provider: ImagesCompleteUploadArgsProvider.fromWireName(
        _decodeString(
          object.value['provider'] ?? _missing(path, 'provider'),
          '$path.provider',
        ),
        '$path.provider',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      uploadedAt:
          (object.value['uploadedAt'] ?? _missing(path, 'uploadedAt'))
              is ConvexNull
          ? null
          : _decodeNumber(
              object.value['uploadedAt'] ?? _missing(path, 'uploadedAt'),
              '$path.uploadedAt',
            ),
      uploadStatus: ImagesListForStrategyResultItemUploadStatus.fromWireName(
        _decodeString(
          object.value['uploadStatus'] ?? _missing(path, 'uploadStatus'),
          '$path.uploadStatus',
        ),
        '$path.uploadStatus',
      ),
      url: (object.value['url'] ?? _missing(path, 'url')) is ConvexNull
          ? null
          : _decodeString(
              object.value['url'] ?? _missing(path, 'url'),
              '$path.url',
            ),
      width: (object.value['width'] ?? _missing(path, 'width')) is ConvexNull
          ? null
          : _decodeNumber(
              object.value['width'] ?? _missing(path, 'width'),
              '$path.width',
            ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'byteSize': byteSize == null
          ? const ConvexNull()
          : _encodeNumber(byteSize!, '$path.byteSize'),
      'fileExtension': ConvexString(fileExtension),
      'height': height == null
          ? const ConvexNull()
          : _encodeNumber(height!, '$path.height'),
      'legacyStoragePath': legacyStoragePath == null
          ? const ConvexNull()
          : ConvexString(legacyStoragePath!),
      'mimeType': mimeType == null
          ? const ConvexNull()
          : ConvexString(mimeType!),
      'provider': ConvexString(provider.wireName),
      'publicId': ConvexString(publicId),
      'uploadedAt': uploadedAt == null
          ? const ConvexNull()
          : _encodeNumber(uploadedAt!, '$path.uploadedAt'),
      'uploadStatus': ConvexString(uploadStatus.wireName),
      'url': url == null ? const ConvexNull() : ConvexString(url!),
      'width': width == null
          ? const ConvexNull()
          : _encodeNumber(width!, '$path.width'),
    });
  }
}

final class InvitesRedeemResult {
  const InvitesRedeemResult({
    required this.ok,
    required this.role,
    required this.strategyPublicId,
  });
  final bool ok;
  final FoldersListTreeResultItemRole role;
  final String strategyPublicId;

  factory InvitesRedeemResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'ok', 'role', 'strategyPublicId'});
    return InvitesRedeemResult(
      ok: _expectLiteral(
        _decodeBoolean(object.value['ok'] ?? _missing(path, 'ok'), '$path.ok'),
        true,
        '$path.ok',
      ),
      role: FoldersListTreeResultItemRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'ok': ConvexBoolean(_expectLiteral(ok, true, '$path.ok')),
      'role': ConvexString(role.wireName),
      'strategyPublicId': ConvexString(strategyPublicId),
    });
  }
}

final class LineupsListForPageResultItem {
  const LineupsListForPageResultItem({
    required this.createdAt,
    required this.deleted,
    required this.pagePublicId,
    required this.payload,
    required this.publicId,
    required this.revision,
    required this.sortIndex,
    required this.strategyPublicId,
    required this.updatedAt,
  });
  final double createdAt;
  final bool deleted;
  final String pagePublicId;
  final CloudPayload payload;
  final String publicId;
  final double revision;
  final double sortIndex;
  final String strategyPublicId;
  final double updatedAt;

  factory LineupsListForPageResultItem.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'createdAt',
      'deleted',
      'pagePublicId',
      'payload',
      'publicId',
      'revision',
      'sortIndex',
      'strategyPublicId',
      'updatedAt',
    });
    return LineupsListForPageResultItem(
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      deleted: _decodeBoolean(
        object.value['deleted'] ?? _missing(path, 'deleted'),
        '$path.deleted',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      payload: _decodePayload(
        () => const LineupGroupConvexCodec().decode(
          object.value['payload'] ?? _missing(path, 'payload'),
        ),
        '$path.payload',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'deleted': ConvexBoolean(deleted),
      'pagePublicId': ConvexString(pagePublicId),
      'payload': _encodePayload(
        () => const LineupGroupConvexCodec().encode(payload),
        '$path.payload',
      ),
      'publicId': ConvexString(publicId),
      'revision': _encodeNumber(revision, '$path.revision'),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
      'strategyPublicId': ConvexString(strategyPublicId),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemElementAdd
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemElementAdd({
    required this.elementPublicId,
    required this.opId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    this.expectedElementRevision = const ConvexOptional.absent(),
  });
  final String elementPublicId;
  final ConvexOptional<double> expectedElementRevision;
  final String opId;
  final String pagePublicId;
  final CloudPayload payload;
  final double sortIndex;

  factory OpsApplyBatchArgsOpsItemElementAdd.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'elementPublicId',
      'expectedElementRevision',
      'opId',
      'pagePublicId',
      'payload',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemElementAdd(
      elementPublicId: _decodeString(
        object.value['elementPublicId'] ?? _missing(path, 'elementPublicId'),
        '$path.elementPublicId',
      ),
      expectedElementRevision:
          object.value.containsKey('expectedElementRevision')
          ? ConvexOptional.present(
              _decodeNumber(
                object.value['expectedElementRevision']!,
                '$path.expectedElementRevision',
              ),
            )
          : const ConvexOptional.absent(),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      payload: _decodeOpsApplyBatchArgsOpsItemElementAddPayload(
        object.value['payload'] ?? _missing(path, 'payload'),
        '$path.payload',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('element.add'),
      'elementPublicId': ConvexString(elementPublicId),
      if (expectedElementRevision.isPresent)
        'expectedElementRevision': _encodeNumber(
          expectedElementRevision.value,
          '$path.expectedElementRevision',
        ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'payload': _encodeOpsApplyBatchArgsOpsItemElementAddPayload(
        payload,
        '$path.payload',
      ),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemElementDelete
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemElementDelete({
    required this.elementPublicId,
    required this.expectedElementRevision,
    required this.opId,
    required this.pagePublicId,
  });
  final String elementPublicId;
  final double expectedElementRevision;
  final String opId;
  final String pagePublicId;

  factory OpsApplyBatchArgsOpsItemElementDelete.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'elementPublicId',
      'expectedElementRevision',
      'opId',
      'pagePublicId',
    });
    return OpsApplyBatchArgsOpsItemElementDelete(
      elementPublicId: _decodeString(
        object.value['elementPublicId'] ?? _missing(path, 'elementPublicId'),
        '$path.elementPublicId',
      ),
      expectedElementRevision: _decodeNumber(
        object.value['expectedElementRevision'] ??
            _missing(path, 'expectedElementRevision'),
        '$path.expectedElementRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('element.delete'),
      'elementPublicId': ConvexString(elementPublicId),
      'expectedElementRevision': _encodeNumber(
        expectedElementRevision,
        '$path.expectedElementRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
    });
  }
}

final class OpsApplyBatchArgsOpsItemElementPatch
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemElementPatch({
    required this.elementPublicId,
    required this.expectedElementRevision,
    required this.opId,
    this.pagePublicId = const ConvexOptional.absent(),
    this.payload = const ConvexOptional.absent(),
    this.sortIndex = const ConvexOptional.absent(),
  });
  final String elementPublicId;
  final double expectedElementRevision;
  final String opId;
  final ConvexOptional<String> pagePublicId;
  final ConvexOptional<CloudPayload> payload;
  final ConvexOptional<double> sortIndex;

  factory OpsApplyBatchArgsOpsItemElementPatch.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'elementPublicId',
      'expectedElementRevision',
      'opId',
      'pagePublicId',
      'payload',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemElementPatch(
      elementPublicId: _decodeString(
        object.value['elementPublicId'] ?? _missing(path, 'elementPublicId'),
        '$path.elementPublicId',
      ),
      expectedElementRevision: _decodeNumber(
        object.value['expectedElementRevision'] ??
            _missing(path, 'expectedElementRevision'),
        '$path.expectedElementRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: object.value.containsKey('pagePublicId')
          ? ConvexOptional.present(
              _decodeString(
                object.value['pagePublicId']!,
                '$path.pagePublicId',
              ),
            )
          : const ConvexOptional.absent(),
      payload: object.value.containsKey('payload')
          ? ConvexOptional.present(
              _decodeOpsApplyBatchArgsOpsItemElementPatchPayload(
                object.value['payload']!,
                '$path.payload',
              ),
            )
          : const ConvexOptional.absent(),
      sortIndex: object.value.containsKey('sortIndex')
          ? ConvexOptional.present(
              _decodeNumber(object.value['sortIndex']!, '$path.sortIndex'),
            )
          : const ConvexOptional.absent(),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('element.patch'),
      'elementPublicId': ConvexString(elementPublicId),
      'expectedElementRevision': _encodeNumber(
        expectedElementRevision,
        '$path.expectedElementRevision',
      ),
      'opId': ConvexString(opId),
      if (pagePublicId.isPresent)
        'pagePublicId': ConvexString(pagePublicId.value),
      if (payload.isPresent)
        'payload': _encodeOpsApplyBatchArgsOpsItemElementPatchPayload(
          payload.value,
          '$path.payload',
        ),
      if (sortIndex.isPresent)
        'sortIndex': _encodeNumber(sortIndex.value, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemElementReorder
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemElementReorder({
    required this.elementPublicId,
    required this.expectedElementRevision,
    required this.opId,
    required this.pagePublicId,
    required this.sortIndex,
  });
  final String elementPublicId;
  final double expectedElementRevision;
  final String opId;
  final String pagePublicId;
  final double sortIndex;

  factory OpsApplyBatchArgsOpsItemElementReorder.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'elementPublicId',
      'expectedElementRevision',
      'opId',
      'pagePublicId',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemElementReorder(
      elementPublicId: _decodeString(
        object.value['elementPublicId'] ?? _missing(path, 'elementPublicId'),
        '$path.elementPublicId',
      ),
      expectedElementRevision: _decodeNumber(
        object.value['expectedElementRevision'] ??
            _missing(path, 'expectedElementRevision'),
        '$path.expectedElementRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('element.reorder'),
      'elementPublicId': ConvexString(elementPublicId),
      'expectedElementRevision': _encodeNumber(
        expectedElementRevision,
        '$path.expectedElementRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemLineupAdd extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemLineupAdd({
    required this.lineupPublicId,
    required this.opId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    this.expectedLineupRevision = const ConvexOptional.absent(),
  });
  final ConvexOptional<double> expectedLineupRevision;
  final String lineupPublicId;
  final String opId;
  final String pagePublicId;
  final CloudPayload payload;
  final double sortIndex;

  factory OpsApplyBatchArgsOpsItemLineupAdd.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedLineupRevision',
      'lineupPublicId',
      'opId',
      'pagePublicId',
      'payload',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemLineupAdd(
      expectedLineupRevision: object.value.containsKey('expectedLineupRevision')
          ? ConvexOptional.present(
              _decodeNumber(
                object.value['expectedLineupRevision']!,
                '$path.expectedLineupRevision',
              ),
            )
          : const ConvexOptional.absent(),
      lineupPublicId: _decodeString(
        object.value['lineupPublicId'] ?? _missing(path, 'lineupPublicId'),
        '$path.lineupPublicId',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      payload: _decodePayload(
        () => const LineupGroupConvexCodec().decode(
          object.value['payload'] ?? _missing(path, 'payload'),
        ),
        '$path.payload',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('lineup.add'),
      if (expectedLineupRevision.isPresent)
        'expectedLineupRevision': _encodeNumber(
          expectedLineupRevision.value,
          '$path.expectedLineupRevision',
        ),
      'lineupPublicId': ConvexString(lineupPublicId),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'payload': _encodePayload(
        () => const LineupGroupConvexCodec().encode(payload),
        '$path.payload',
      ),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemLineupDelete
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemLineupDelete({
    required this.expectedLineupRevision,
    required this.lineupPublicId,
    required this.opId,
    required this.pagePublicId,
  });
  final double expectedLineupRevision;
  final String lineupPublicId;
  final String opId;
  final String pagePublicId;

  factory OpsApplyBatchArgsOpsItemLineupDelete.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedLineupRevision',
      'lineupPublicId',
      'opId',
      'pagePublicId',
    });
    return OpsApplyBatchArgsOpsItemLineupDelete(
      expectedLineupRevision: _decodeNumber(
        object.value['expectedLineupRevision'] ??
            _missing(path, 'expectedLineupRevision'),
        '$path.expectedLineupRevision',
      ),
      lineupPublicId: _decodeString(
        object.value['lineupPublicId'] ?? _missing(path, 'lineupPublicId'),
        '$path.lineupPublicId',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('lineup.delete'),
      'expectedLineupRevision': _encodeNumber(
        expectedLineupRevision,
        '$path.expectedLineupRevision',
      ),
      'lineupPublicId': ConvexString(lineupPublicId),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
    });
  }
}

final class OpsApplyBatchArgsOpsItemLineupPatch
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemLineupPatch({
    required this.expectedLineupRevision,
    required this.lineupPublicId,
    required this.opId,
    this.pagePublicId = const ConvexOptional.absent(),
    this.payload = const ConvexOptional.absent(),
    this.sortIndex = const ConvexOptional.absent(),
  });
  final double expectedLineupRevision;
  final String lineupPublicId;
  final String opId;
  final ConvexOptional<String> pagePublicId;
  final ConvexOptional<CloudPayload> payload;
  final ConvexOptional<double> sortIndex;

  factory OpsApplyBatchArgsOpsItemLineupPatch.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedLineupRevision',
      'lineupPublicId',
      'opId',
      'pagePublicId',
      'payload',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemLineupPatch(
      expectedLineupRevision: _decodeNumber(
        object.value['expectedLineupRevision'] ??
            _missing(path, 'expectedLineupRevision'),
        '$path.expectedLineupRevision',
      ),
      lineupPublicId: _decodeString(
        object.value['lineupPublicId'] ?? _missing(path, 'lineupPublicId'),
        '$path.lineupPublicId',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: object.value.containsKey('pagePublicId')
          ? ConvexOptional.present(
              _decodeString(
                object.value['pagePublicId']!,
                '$path.pagePublicId',
              ),
            )
          : const ConvexOptional.absent(),
      payload: object.value.containsKey('payload')
          ? ConvexOptional.present(
              _decodePayload(
                () => const LineupGroupConvexCodec().decode(
                  object.value['payload']!,
                ),
                '$path.payload',
              ),
            )
          : const ConvexOptional.absent(),
      sortIndex: object.value.containsKey('sortIndex')
          ? ConvexOptional.present(
              _decodeNumber(object.value['sortIndex']!, '$path.sortIndex'),
            )
          : const ConvexOptional.absent(),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('lineup.patch'),
      'expectedLineupRevision': _encodeNumber(
        expectedLineupRevision,
        '$path.expectedLineupRevision',
      ),
      'lineupPublicId': ConvexString(lineupPublicId),
      'opId': ConvexString(opId),
      if (pagePublicId.isPresent)
        'pagePublicId': ConvexString(pagePublicId.value),
      if (payload.isPresent)
        'payload': _encodePayload(
          () => const LineupGroupConvexCodec().encode(payload.value),
          '$path.payload',
        ),
      if (sortIndex.isPresent)
        'sortIndex': _encodeNumber(sortIndex.value, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemLineupReorder
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemLineupReorder({
    required this.expectedLineupRevision,
    required this.lineupPublicId,
    required this.opId,
    required this.pagePublicId,
    required this.sortIndex,
  });
  final double expectedLineupRevision;
  final String lineupPublicId;
  final String opId;
  final String pagePublicId;
  final double sortIndex;

  factory OpsApplyBatchArgsOpsItemLineupReorder.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedLineupRevision',
      'lineupPublicId',
      'opId',
      'pagePublicId',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemLineupReorder(
      expectedLineupRevision: _decodeNumber(
        object.value['expectedLineupRevision'] ??
            _missing(path, 'expectedLineupRevision'),
        '$path.expectedLineupRevision',
      ),
      lineupPublicId: _decodeString(
        object.value['lineupPublicId'] ?? _missing(path, 'lineupPublicId'),
        '$path.lineupPublicId',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('lineup.reorder'),
      'expectedLineupRevision': _encodeNumber(
        expectedLineupRevision,
        '$path.expectedLineupRevision',
      ),
      'lineupPublicId': ConvexString(lineupPublicId),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPageAdd extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemPageAdd({
    required this.expectedStrategyRevision,
    required this.opId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
  });
  final double expectedStrategyRevision;
  final String opId;
  final String pagePublicId;
  final OpsApplyBatchArgsOpsItemPageAddPayload payload;
  final double sortIndex;

  factory OpsApplyBatchArgsOpsItemPageAdd.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedStrategyRevision',
      'opId',
      'pagePublicId',
      'payload',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemPageAdd(
      expectedStrategyRevision: _decodeNumber(
        object.value['expectedStrategyRevision'] ??
            _missing(path, 'expectedStrategyRevision'),
        '$path.expectedStrategyRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      payload: OpsApplyBatchArgsOpsItemPageAddPayload.decode(
        object.value['payload'] ?? _missing(path, 'payload'),
        '$path.payload',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('page.add'),
      'expectedStrategyRevision': _encodeNumber(
        expectedStrategyRevision,
        '$path.expectedStrategyRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'payload': payload.encode('$path.payload'),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPageAddPayload {
  const OpsApplyBatchArgsOpsItemPageAddPayload({
    this.isAttack = const ConvexOptional.absent(),
    this.isAutoNamed = const ConvexOptional.absent(),
    this.name = const ConvexOptional.absent(),
    this.settings = const ConvexOptional.absent(),
  });
  final ConvexOptional<bool> isAttack;
  final ConvexOptional<bool> isAutoNamed;
  final ConvexOptional<String> name;
  final ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings> settings;

  factory OpsApplyBatchArgsOpsItemPageAddPayload.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'isAttack',
      'isAutoNamed',
      'name',
      'settings',
    });
    return OpsApplyBatchArgsOpsItemPageAddPayload(
      isAttack: object.value.containsKey('isAttack')
          ? ConvexOptional.present(
              _decodeBoolean(object.value['isAttack']!, '$path.isAttack'),
            )
          : const ConvexOptional.absent(),
      isAutoNamed: object.value.containsKey('isAutoNamed')
          ? ConvexOptional.present(
              _decodeBoolean(object.value['isAutoNamed']!, '$path.isAutoNamed'),
            )
          : const ConvexOptional.absent(),
      name: object.value.containsKey('name')
          ? ConvexOptional.present(
              _decodeString(object.value['name']!, '$path.name'),
            )
          : const ConvexOptional.absent(),
      settings: object.value.containsKey('settings')
          ? ConvexOptional.present(
              OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
                object.value['settings']!,
                '$path.settings',
              ),
            )
          : const ConvexOptional.absent(),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      if (isAttack.isPresent) 'isAttack': ConvexBoolean(isAttack.value),
      if (isAutoNamed.isPresent)
        'isAutoNamed': ConvexBoolean(isAutoNamed.value),
      if (name.isPresent) 'name': ConvexString(name.value),
      if (settings.isPresent)
        'settings': settings.value.encode('$path.settings'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPageAddPayloadSettings {
  const OpsApplyBatchArgsOpsItemPageAddPayloadSettings({
    required this.abilitySize,
    required this.agentSize,
    required this.useNeutralTeamColors,
  });
  final double abilitySize;
  final double agentSize;
  final bool useNeutralTeamColors;

  factory OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'abilitySize',
      'agentSize',
      'useNeutralTeamColors',
    });
    return OpsApplyBatchArgsOpsItemPageAddPayloadSettings(
      abilitySize: _decodeNumber(
        object.value['abilitySize'] ?? _missing(path, 'abilitySize'),
        '$path.abilitySize',
      ),
      agentSize: _decodeNumber(
        object.value['agentSize'] ?? _missing(path, 'agentSize'),
        '$path.agentSize',
      ),
      useNeutralTeamColors: _decodeBoolean(
        object.value['useNeutralTeamColors'] ??
            _missing(path, 'useNeutralTeamColors'),
        '$path.useNeutralTeamColors',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'abilitySize': _encodeNumber(abilitySize, '$path.abilitySize'),
      'agentSize': _encodeNumber(agentSize, '$path.agentSize'),
      'useNeutralTeamColors': ConvexBoolean(useNeutralTeamColors),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPageContentPatch
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemPageContentPatch({
    required this.expectedPageContentRevision,
    required this.opId,
    required this.pagePublicId,
    required this.settings,
  });
  final double expectedPageContentRevision;
  final String opId;
  final String pagePublicId;
  final OpsApplyBatchArgsOpsItemPageAddPayloadSettings settings;

  factory OpsApplyBatchArgsOpsItemPageContentPatch.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedPageContentRevision',
      'opId',
      'pagePublicId',
      'settings',
    });
    return OpsApplyBatchArgsOpsItemPageContentPatch(
      expectedPageContentRevision: _decodeNumber(
        object.value['expectedPageContentRevision'] ??
            _missing(path, 'expectedPageContentRevision'),
        '$path.expectedPageContentRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      settings: OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
        object.value['settings'] ?? _missing(path, 'settings'),
        '$path.settings',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('pageContent.patch'),
      'expectedPageContentRevision': _encodeNumber(
        expectedPageContentRevision,
        '$path.expectedPageContentRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'settings': settings.encode('$path.settings'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPageDelete
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemPageDelete({
    required this.expectedStrategyRevision,
    required this.opId,
    required this.pagePublicId,
  });
  final double expectedStrategyRevision;
  final String opId;
  final String pagePublicId;

  factory OpsApplyBatchArgsOpsItemPageDelete.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedStrategyRevision',
      'opId',
      'pagePublicId',
    });
    return OpsApplyBatchArgsOpsItemPageDelete(
      expectedStrategyRevision: _decodeNumber(
        object.value['expectedStrategyRevision'] ??
            _missing(path, 'expectedStrategyRevision'),
        '$path.expectedStrategyRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('page.delete'),
      'expectedStrategyRevision': _encodeNumber(
        expectedStrategyRevision,
        '$path.expectedStrategyRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPagePatch extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemPagePatch({
    required this.expectedPageRevision,
    required this.opId,
    required this.pagePublicId,
    required this.payload,
  });
  final double expectedPageRevision;
  final String opId;
  final String pagePublicId;
  final OpsApplyBatchArgsOpsItemPageAddPayload payload;

  factory OpsApplyBatchArgsOpsItemPagePatch.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedPageRevision',
      'opId',
      'pagePublicId',
      'payload',
    });
    return OpsApplyBatchArgsOpsItemPagePatch(
      expectedPageRevision: _decodeNumber(
        object.value['expectedPageRevision'] ??
            _missing(path, 'expectedPageRevision'),
        '$path.expectedPageRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      payload: OpsApplyBatchArgsOpsItemPageAddPayload.decode(
        object.value['payload'] ?? _missing(path, 'payload'),
        '$path.payload',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('page.patch'),
      'expectedPageRevision': _encodeNumber(
        expectedPageRevision,
        '$path.expectedPageRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'payload': payload.encode('$path.payload'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemPageReorder
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemPageReorder({
    required this.expectedStrategyRevision,
    required this.opId,
    required this.pagePublicId,
    required this.sortIndex,
  });
  final double expectedStrategyRevision;
  final String opId;
  final String pagePublicId;
  final double sortIndex;

  factory OpsApplyBatchArgsOpsItemPageReorder.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedStrategyRevision',
      'opId',
      'pagePublicId',
      'sortIndex',
    });
    return OpsApplyBatchArgsOpsItemPageReorder(
      expectedStrategyRevision: _decodeNumber(
        object.value['expectedStrategyRevision'] ??
            _missing(path, 'expectedStrategyRevision'),
        '$path.expectedStrategyRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      pagePublicId: _decodeString(
        object.value['pagePublicId'] ?? _missing(path, 'pagePublicId'),
        '$path.pagePublicId',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('page.reorder'),
      'expectedStrategyRevision': _encodeNumber(
        expectedStrategyRevision,
        '$path.expectedStrategyRevision',
      ),
      'opId': ConvexString(opId),
      'pagePublicId': ConvexString(pagePublicId),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemStrategyPatch
    extends OpsApplyBatchArgsOpsItem {
  const OpsApplyBatchArgsOpsItemStrategyPatch({
    required this.expectedStrategyRevision,
    required this.opId,
    required this.payload,
  });
  final double expectedStrategyRevision;
  final String opId;
  final OpsApplyBatchArgsOpsItemStrategyPatchPayload payload;

  factory OpsApplyBatchArgsOpsItemStrategyPatch.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'type',
      'expectedStrategyRevision',
      'opId',
      'payload',
    });
    return OpsApplyBatchArgsOpsItemStrategyPatch(
      expectedStrategyRevision: _decodeNumber(
        object.value['expectedStrategyRevision'] ??
            _missing(path, 'expectedStrategyRevision'),
        '$path.expectedStrategyRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      payload: OpsApplyBatchArgsOpsItemStrategyPatchPayload.decode(
        object.value['payload'] ?? _missing(path, 'payload'),
        '$path.payload',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('strategy.patch'),
      'expectedStrategyRevision': _encodeNumber(
        expectedStrategyRevision,
        '$path.expectedStrategyRevision',
      ),
      'opId': ConvexString(opId),
      'payload': payload.encode('$path.payload'),
    });
  }
}

final class OpsApplyBatchArgsOpsItemStrategyPatchPayload {
  const OpsApplyBatchArgsOpsItemStrategyPatchPayload({
    this.clearThemeOverridePalette = const ConvexOptional.absent(),
    this.clearThemeProfileId = const ConvexOptional.absent(),
    this.mapData = const ConvexOptional.absent(),
    this.name = const ConvexOptional.absent(),
    this.themeOverridePalette = const ConvexOptional.absent(),
    this.themeProfileId = const ConvexOptional.absent(),
  });
  final ConvexOptional<bool> clearThemeOverridePalette;
  final ConvexOptional<bool> clearThemeProfileId;
  final ConvexOptional<String> mapData;
  final ConvexOptional<String> name;
  final ConvexOptional<
    OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
  >
  themeOverridePalette;
  final ConvexOptional<String> themeProfileId;

  factory OpsApplyBatchArgsOpsItemStrategyPatchPayload.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'clearThemeOverridePalette',
      'clearThemeProfileId',
      'mapData',
      'name',
      'themeOverridePalette',
      'themeProfileId',
    });
    return OpsApplyBatchArgsOpsItemStrategyPatchPayload(
      clearThemeOverridePalette:
          object.value.containsKey('clearThemeOverridePalette')
          ? ConvexOptional.present(
              _decodeBoolean(
                object.value['clearThemeOverridePalette']!,
                '$path.clearThemeOverridePalette',
              ),
            )
          : const ConvexOptional.absent(),
      clearThemeProfileId: object.value.containsKey('clearThemeProfileId')
          ? ConvexOptional.present(
              _decodeBoolean(
                object.value['clearThemeProfileId']!,
                '$path.clearThemeProfileId',
              ),
            )
          : const ConvexOptional.absent(),
      mapData: object.value.containsKey('mapData')
          ? ConvexOptional.present(
              _decodeString(object.value['mapData']!, '$path.mapData'),
            )
          : const ConvexOptional.absent(),
      name: object.value.containsKey('name')
          ? ConvexOptional.present(
              _decodeString(object.value['name']!, '$path.name'),
            )
          : const ConvexOptional.absent(),
      themeOverridePalette: object.value.containsKey('themeOverridePalette')
          ? ConvexOptional.present(
              OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette.decode(
                object.value['themeOverridePalette']!,
                '$path.themeOverridePalette',
              ),
            )
          : const ConvexOptional.absent(),
      themeProfileId: object.value.containsKey('themeProfileId')
          ? ConvexOptional.present(
              _decodeString(
                object.value['themeProfileId']!,
                '$path.themeProfileId',
              ),
            )
          : const ConvexOptional.absent(),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      if (clearThemeOverridePalette.isPresent)
        'clearThemeOverridePalette': ConvexBoolean(
          clearThemeOverridePalette.value,
        ),
      if (clearThemeProfileId.isPresent)
        'clearThemeProfileId': ConvexBoolean(clearThemeProfileId.value),
      if (mapData.isPresent) 'mapData': ConvexString(mapData.value),
      if (name.isPresent) 'name': ConvexString(name.value),
      if (themeOverridePalette.isPresent)
        'themeOverridePalette': themeOverridePalette.value.encode(
          '$path.themeOverridePalette',
        ),
      if (themeProfileId.isPresent)
        'themeProfileId': ConvexString(themeProfileId.value),
    });
  }
}

final class OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette {
  const OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette({
    required this.baseValue,
    required this.detail,
    required this.highlight,
  });
  final String baseValue;
  final String detail;
  final String highlight;

  factory OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'base', 'detail', 'highlight'});
    return OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette(
      baseValue: _decodeString(
        object.value['base'] ?? _missing(path, 'base'),
        '$path.base',
      ),
      detail: _decodeString(
        object.value['detail'] ?? _missing(path, 'detail'),
        '$path.detail',
      ),
      highlight: _decodeString(
        object.value['highlight'] ?? _missing(path, 'highlight'),
        '$path.highlight',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'base': ConvexString(baseValue),
      'detail': ConvexString(detail),
      'highlight': ConvexString(highlight),
    });
  }
}

final class OpsApplyBatchResult {
  const OpsApplyBatchResult({
    required this.results,
    required this.strategyPublicId,
  });
  final List<OpsApplyBatchResultResultsItem> results;
  final String strategyPublicId;

  factory OpsApplyBatchResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'results', 'strategyPublicId'});
    return OpsApplyBatchResult(
      results:
          _decodeArray(
                object.value['results'] ?? _missing(path, 'results'),
                '$path.results',
              ).value.indexed
              .map(
                (entry) => OpsApplyBatchResultResultsItem.decode(
                  entry.$2,
                  _indexPath('$path.results', entry.$1),
                ),
              )
              .toList(growable: false),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'results': ConvexArray(
        results.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.results', entry.$1)),
            )
            .toList(growable: false),
      ),
      'strategyPublicId': ConvexString(strategyPublicId),
    });
  }
}

final class OpsApplyBatchResultResultsItemApplied
    extends OpsApplyBatchResultResultsItem {
  const OpsApplyBatchResultResultsItemApplied({
    required this.appliedRevision,
    required this.opId,
  });
  final double appliedRevision;
  final String opId;

  factory OpsApplyBatchResultResultsItemApplied.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'status',
      'appliedRevision',
      'opId',
    });
    return OpsApplyBatchResultResultsItemApplied(
      appliedRevision: _decodeNumber(
        object.value['appliedRevision'] ?? _missing(path, 'appliedRevision'),
        '$path.appliedRevision',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'status': ConvexString('applied'),
      'appliedRevision': _encodeNumber(
        appliedRevision,
        '$path.appliedRevision',
      ),
      'opId': ConvexString(opId),
    });
  }
}

final class OpsApplyBatchResultResultsItemFailed
    extends OpsApplyBatchResultResultsItem {
  const OpsApplyBatchResultResultsItemFailed({
    required this.code,
    required this.message,
    required this.opId,
    required this.rawCode,
  });
  final String code;
  final String message;
  final String opId;
  final String rawCode;

  factory OpsApplyBatchResultResultsItemFailed.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'status',
      'code',
      'message',
      'opId',
      'rawCode',
    });
    return OpsApplyBatchResultResultsItemFailed(
      code: _decodeString(
        object.value['code'] ?? _missing(path, 'code'),
        '$path.code',
      ),
      message: _decodeString(
        object.value['message'] ?? _missing(path, 'message'),
        '$path.message',
      ),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      rawCode: _decodeString(
        object.value['rawCode'] ?? _missing(path, 'rawCode'),
        '$path.rawCode',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'status': ConvexString('failed'),
      'code': ConvexString(code),
      'message': ConvexString(message),
      'opId': ConvexString(opId),
      'rawCode': ConvexString(rawCode),
    });
  }
}

final class OpsApplyBatchResultResultsItemNoop
    extends OpsApplyBatchResultResultsItem {
  const OpsApplyBatchResultResultsItemNoop({
    required this.opId,
    this.currentRevision = const ConvexOptional.absent(),
  });
  final ConvexOptional<double> currentRevision;
  final String opId;

  factory OpsApplyBatchResultResultsItemNoop.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'status',
      'currentRevision',
      'opId',
    });
    return OpsApplyBatchResultResultsItemNoop(
      currentRevision: object.value.containsKey('currentRevision')
          ? ConvexOptional.present(
              _decodeNumber(
                object.value['currentRevision']!,
                '$path.currentRevision',
              ),
            )
          : const ConvexOptional.absent(),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'status': ConvexString('noop'),
      if (currentRevision.isPresent)
        'currentRevision': _encodeNumber(
          currentRevision.value,
          '$path.currentRevision',
        ),
      'opId': ConvexString(opId),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejected
    extends OpsApplyBatchResultResultsItem {
  const OpsApplyBatchResultResultsItemRejected({
    required this.opId,
    required this.reason,
    this.current = const ConvexOptional.absent(),
  });
  final ConvexOptional<OpsApplyBatchResultResultsItemRejectedCurrent> current;
  final String opId;
  final OpsApplyBatchResultResultsItemRejectedReason reason;

  factory OpsApplyBatchResultResultsItemRejected.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'status',
      'current',
      'opId',
      'reason',
    });
    return OpsApplyBatchResultResultsItemRejected(
      current: object.value.containsKey('current')
          ? ConvexOptional.present(
              OpsApplyBatchResultResultsItemRejectedCurrent.decode(
                object.value['current']!,
                '$path.current',
              ),
            )
          : const ConvexOptional.absent(),
      opId: _decodeString(
        object.value['opId'] ?? _missing(path, 'opId'),
        '$path.opId',
      ),
      reason: OpsApplyBatchResultResultsItemRejectedReason.fromWireName(
        _decodeString(
          object.value['reason'] ?? _missing(path, 'reason'),
          '$path.reason',
        ),
        '$path.reason',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'status': ConvexString('rejected'),
      if (current.isPresent) 'current': current.value.encode('$path.current'),
      'opId': ConvexString(opId),
      'reason': ConvexString(reason.wireName),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentElement
    extends OpsApplyBatchResultResultsItemRejectedCurrent {
  const OpsApplyBatchResultResultsItemRejectedCurrentElement({
    required this.revision,
    required this.value,
  });
  final double revision;
  final CloudPayload value;

  factory OpsApplyBatchResultResultsItemRejectedCurrentElement.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'type', 'revision', 'value'});
    return OpsApplyBatchResultResultsItemRejectedCurrentElement(
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      value: _decodeOpsApplyBatchResultResultsItemRejectedCurrentElementValue(
        object.value['value'] ?? _missing(path, 'value'),
        '$path.value',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('element'),
      'revision': _encodeNumber(revision, '$path.revision'),
      'value': _encodeOpsApplyBatchResultResultsItemRejectedCurrentElementValue(
        value,
        '$path.value',
      ),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentLineup
    extends OpsApplyBatchResultResultsItemRejectedCurrent {
  const OpsApplyBatchResultResultsItemRejectedCurrentLineup({
    required this.revision,
    required this.value,
  });
  final double revision;
  final CloudPayload value;

  factory OpsApplyBatchResultResultsItemRejectedCurrentLineup.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'type', 'revision', 'value'});
    return OpsApplyBatchResultResultsItemRejectedCurrentLineup(
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      value: _decodePayload(
        () => const LineupGroupConvexCodec().decode(
          object.value['value'] ?? _missing(path, 'value'),
        ),
        '$path.value',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('lineup'),
      'revision': _encodeNumber(revision, '$path.revision'),
      'value': _encodePayload(
        () => const LineupGroupConvexCodec().encode(value),
        '$path.value',
      ),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentPage
    extends OpsApplyBatchResultResultsItemRejectedCurrent {
  const OpsApplyBatchResultResultsItemRejectedCurrentPage({
    required this.revision,
    required this.value,
  });
  final double revision;
  final OpsApplyBatchResultResultsItemRejectedCurrentPageValue value;

  factory OpsApplyBatchResultResultsItemRejectedCurrentPage.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'type', 'revision', 'value'});
    return OpsApplyBatchResultResultsItemRejectedCurrentPage(
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      value: OpsApplyBatchResultResultsItemRejectedCurrentPageValue.decode(
        object.value['value'] ?? _missing(path, 'value'),
        '$path.value',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('page'),
      'revision': _encodeNumber(revision, '$path.revision'),
      'value': value.encode('$path.value'),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentPageContent
    extends OpsApplyBatchResultResultsItemRejectedCurrent {
  const OpsApplyBatchResultResultsItemRejectedCurrentPageContent({
    required this.revision,
    required this.value,
  });
  final double revision;
  final OpsApplyBatchResultResultsItemRejectedCurrentPageContentValue value;

  factory OpsApplyBatchResultResultsItemRejectedCurrentPageContent.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'type', 'revision', 'value'});
    return OpsApplyBatchResultResultsItemRejectedCurrentPageContent(
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      value:
          OpsApplyBatchResultResultsItemRejectedCurrentPageContentValue.decode(
            object.value['value'] ?? _missing(path, 'value'),
            '$path.value',
          ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('pageContent'),
      'revision': _encodeNumber(revision, '$path.revision'),
      'value': value.encode('$path.value'),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentPageContentValue {
  const OpsApplyBatchResultResultsItemRejectedCurrentPageContentValue({
    required this.settings,
  });
  final OpsApplyBatchArgsOpsItemPageAddPayloadSettings? settings;

  factory OpsApplyBatchResultResultsItemRejectedCurrentPageContentValue.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'settings'});
    return OpsApplyBatchResultResultsItemRejectedCurrentPageContentValue(
      settings:
          (object.value['settings'] ?? _missing(path, 'settings')) is ConvexNull
          ? null
          : OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
              object.value['settings'] ?? _missing(path, 'settings'),
              '$path.settings',
            ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'settings': settings == null
          ? const ConvexNull()
          : settings!.encode('$path.settings'),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentPageValue {
  const OpsApplyBatchResultResultsItemRejectedCurrentPageValue({
    required this.isAttack,
    required this.name,
    required this.sortIndex,
    this.isAutoNamed = const ConvexOptional.absent(),
  });
  final bool isAttack;
  final ConvexOptional<bool> isAutoNamed;
  final String name;
  final double sortIndex;

  factory OpsApplyBatchResultResultsItemRejectedCurrentPageValue.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'isAttack',
      'isAutoNamed',
      'name',
      'sortIndex',
    });
    return OpsApplyBatchResultResultsItemRejectedCurrentPageValue(
      isAttack: _decodeBoolean(
        object.value['isAttack'] ?? _missing(path, 'isAttack'),
        '$path.isAttack',
      ),
      isAutoNamed: object.value.containsKey('isAutoNamed')
          ? ConvexOptional.present(
              _decodeBoolean(object.value['isAutoNamed']!, '$path.isAutoNamed'),
            )
          : const ConvexOptional.absent(),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'isAttack': ConvexBoolean(isAttack),
      if (isAutoNamed.isPresent)
        'isAutoNamed': ConvexBoolean(isAutoNamed.value),
      'name': ConvexString(name),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentStrategy
    extends OpsApplyBatchResultResultsItemRejectedCurrent {
  const OpsApplyBatchResultResultsItemRejectedCurrentStrategy({
    required this.revision,
    required this.value,
  });
  final double revision;
  final OpsApplyBatchResultResultsItemRejectedCurrentStrategyValue value;

  factory OpsApplyBatchResultResultsItemRejectedCurrentStrategy.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'type', 'revision', 'value'});
    return OpsApplyBatchResultResultsItemRejectedCurrentStrategy(
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      value: OpsApplyBatchResultResultsItemRejectedCurrentStrategyValue.decode(
        object.value['value'] ?? _missing(path, 'value'),
        '$path.value',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'type': ConvexString('strategy'),
      'revision': _encodeNumber(revision, '$path.revision'),
      'value': value.encode('$path.value'),
    });
  }
}

final class OpsApplyBatchResultResultsItemRejectedCurrentStrategyValue {
  const OpsApplyBatchResultResultsItemRejectedCurrentStrategyValue({
    required this.mapData,
    required this.name,
    required this.themeOverridePalette,
    required this.themeProfileId,
  });
  final String mapData;
  final String name;
  final OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette?
  themeOverridePalette;
  final String? themeProfileId;

  factory OpsApplyBatchResultResultsItemRejectedCurrentStrategyValue.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'mapData',
      'name',
      'themeOverridePalette',
      'themeProfileId',
    });
    return OpsApplyBatchResultResultsItemRejectedCurrentStrategyValue(
      mapData: _decodeString(
        object.value['mapData'] ?? _missing(path, 'mapData'),
        '$path.mapData',
      ),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      themeOverridePalette:
          (object.value['themeOverridePalette'] ??
                  _missing(path, 'themeOverridePalette'))
              is ConvexNull
          ? null
          : OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette.decode(
              object.value['themeOverridePalette'] ??
                  _missing(path, 'themeOverridePalette'),
              '$path.themeOverridePalette',
            ),
      themeProfileId:
          (object.value['themeProfileId'] ?? _missing(path, 'themeProfileId'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['themeProfileId'] ??
                  _missing(path, 'themeProfileId'),
              '$path.themeProfileId',
            ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'mapData': ConvexString(mapData),
      'name': ConvexString(name),
      'themeOverridePalette': themeOverridePalette == null
          ? const ConvexNull()
          : themeOverridePalette!.encode('$path.themeOverridePalette'),
      'themeProfileId': themeProfileId == null
          ? const ConvexNull()
          : ConvexString(themeProfileId!),
    });
  }
}

final class PageGetSnapshotResult {
  const PageGetSnapshotResult({
    required this.assets,
    required this.content,
    required this.elements,
    required this.lineups,
    required this.page,
  });
  final List<ImagesListForStrategyResultItem> assets;
  final PageGetSnapshotResultContent content;
  final List<ElementsListForPageResultItem> elements;
  final List<LineupsListForPageResultItem> lineups;
  final PageGetSnapshotResultPage page;

  factory PageGetSnapshotResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'assets',
      'content',
      'elements',
      'lineups',
      'page',
    });
    return PageGetSnapshotResult(
      assets:
          _decodeArray(
                object.value['assets'] ?? _missing(path, 'assets'),
                '$path.assets',
              ).value.indexed
              .map(
                (entry) => ImagesListForStrategyResultItem.decode(
                  entry.$2,
                  _indexPath('$path.assets', entry.$1),
                ),
              )
              .toList(growable: false),
      content: PageGetSnapshotResultContent.decode(
        object.value['content'] ?? _missing(path, 'content'),
        '$path.content',
      ),
      elements:
          _decodeArray(
                object.value['elements'] ?? _missing(path, 'elements'),
                '$path.elements',
              ).value.indexed
              .map(
                (entry) => ElementsListForPageResultItem.decode(
                  entry.$2,
                  _indexPath('$path.elements', entry.$1),
                ),
              )
              .toList(growable: false),
      lineups:
          _decodeArray(
                object.value['lineups'] ?? _missing(path, 'lineups'),
                '$path.lineups',
              ).value.indexed
              .map(
                (entry) => LineupsListForPageResultItem.decode(
                  entry.$2,
                  _indexPath('$path.lineups', entry.$1),
                ),
              )
              .toList(growable: false),
      page: PageGetSnapshotResultPage.decode(
        object.value['page'] ?? _missing(path, 'page'),
        '$path.page',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'assets': ConvexArray(
        assets.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.assets', entry.$1)),
            )
            .toList(growable: false),
      ),
      'content': content.encode('$path.content'),
      'elements': ConvexArray(
        elements.indexed
            .map(
              (entry) =>
                  entry.$2.encode(_indexPath('$path.elements', entry.$1)),
            )
            .toList(growable: false),
      ),
      'lineups': ConvexArray(
        lineups.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.lineups', entry.$1)),
            )
            .toList(growable: false),
      ),
      'page': page.encode('$path.page'),
    });
  }
}

final class PageGetSnapshotResultContent {
  const PageGetSnapshotResultContent({
    required this.createdAt,
    required this.revision,
    required this.settings,
    required this.updatedAt,
  });
  final double createdAt;
  final double revision;
  final OpsApplyBatchArgsOpsItemPageAddPayloadSettings? settings;
  final double updatedAt;

  factory PageGetSnapshotResultContent.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'createdAt',
      'revision',
      'settings',
      'updatedAt',
    });
    return PageGetSnapshotResultContent(
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      settings:
          (object.value['settings'] ?? _missing(path, 'settings')) is ConvexNull
          ? null
          : OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
              object.value['settings'] ?? _missing(path, 'settings'),
              '$path.settings',
            ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'revision': _encodeNumber(revision, '$path.revision'),
      'settings': settings == null
          ? const ConvexNull()
          : settings!.encode('$path.settings'),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class PageGetSnapshotResultPage {
  const PageGetSnapshotResultPage({
    required this.createdAt,
    required this.isAttack,
    required this.name,
    required this.publicId,
    required this.revision,
    required this.sortIndex,
    required this.strategyPublicId,
    required this.updatedAt,
    this.isAutoNamed = const ConvexOptional.absent(),
  });
  final double createdAt;
  final bool isAttack;
  final ConvexOptional<bool> isAutoNamed;
  final String name;
  final String publicId;
  final double revision;
  final double sortIndex;
  final String strategyPublicId;
  final double updatedAt;

  factory PageGetSnapshotResultPage.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'createdAt',
      'isAttack',
      'isAutoNamed',
      'name',
      'publicId',
      'revision',
      'sortIndex',
      'strategyPublicId',
      'updatedAt',
    });
    return PageGetSnapshotResultPage(
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      isAttack: _decodeBoolean(
        object.value['isAttack'] ?? _missing(path, 'isAttack'),
        '$path.isAttack',
      ),
      isAutoNamed: object.value.containsKey('isAutoNamed')
          ? ConvexOptional.present(
              _decodeBoolean(object.value['isAutoNamed']!, '$path.isAutoNamed'),
            )
          : const ConvexOptional.absent(),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'isAttack': ConvexBoolean(isAttack),
      if (isAutoNamed.isPresent)
        'isAutoNamed': ConvexBoolean(isAutoNamed.value),
      'name': ConvexString(name),
      'publicId': ConvexString(publicId),
      'revision': _encodeNumber(revision, '$path.revision'),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
      'strategyPublicId': ConvexString(strategyPublicId),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class SharesListResultItem {
  const SharesListResultItem({
    required this.createdAt,
    required this.revokedAt,
    required this.role,
    required this.token,
  });
  final double createdAt;
  final double? revokedAt;
  final InvitesCreateArgsRole role;
  final String token;

  factory SharesListResultItem.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'createdAt',
      'revokedAt',
      'role',
      'token',
    });
    return SharesListResultItem(
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      revokedAt:
          (object.value['revokedAt'] ?? _missing(path, 'revokedAt'))
              is ConvexNull
          ? null
          : _decodeNumber(
              object.value['revokedAt'] ?? _missing(path, 'revokedAt'),
              '$path.revokedAt',
            ),
      role: InvitesCreateArgsRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
      token: _decodeString(
        object.value['token'] ?? _missing(path, 'token'),
        '$path.token',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'revokedAt': revokedAt == null
          ? const ConvexNull()
          : _encodeNumber(revokedAt!, '$path.revokedAt'),
      'role': ConvexString(role.wireName),
      'token': ConvexString(token),
    });
  }
}

final class SharesRedeemResultFolder extends SharesRedeemResult {
  const SharesRedeemResultFolder({
    required this.folderPublicId,
    required this.ok,
    required this.role,
  });
  final String folderPublicId;
  final bool ok;
  final FoldersListTreeResultItemRole role;

  factory SharesRedeemResultFolder.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'targetType',
      'folderPublicId',
      'ok',
      'role',
    });
    return SharesRedeemResultFolder(
      folderPublicId: _decodeString(
        object.value['folderPublicId'] ?? _missing(path, 'folderPublicId'),
        '$path.folderPublicId',
      ),
      ok: _expectLiteral(
        _decodeBoolean(object.value['ok'] ?? _missing(path, 'ok'), '$path.ok'),
        true,
        '$path.ok',
      ),
      role: FoldersListTreeResultItemRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'targetType': ConvexString('folder'),
      'folderPublicId': ConvexString(folderPublicId),
      'ok': ConvexBoolean(_expectLiteral(ok, true, '$path.ok')),
      'role': ConvexString(role.wireName),
    });
  }
}

final class SharesRedeemResultStrategy extends SharesRedeemResult {
  const SharesRedeemResultStrategy({
    required this.folderPublicId,
    required this.ok,
    required this.role,
    required this.strategyPublicId,
  });
  final String? folderPublicId;
  final bool ok;
  final FoldersListTreeResultItemRole role;
  final String strategyPublicId;

  factory SharesRedeemResultStrategy.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'targetType',
      'folderPublicId',
      'ok',
      'role',
      'strategyPublicId',
    });
    return SharesRedeemResultStrategy(
      folderPublicId:
          (object.value['folderPublicId'] ?? _missing(path, 'folderPublicId'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['folderPublicId'] ??
                  _missing(path, 'folderPublicId'),
              '$path.folderPublicId',
            ),
      ok: _expectLiteral(
        _decodeBoolean(object.value['ok'] ?? _missing(path, 'ok'), '$path.ok'),
        true,
        '$path.ok',
      ),
      role: FoldersListTreeResultItemRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
    );
  }

  @override
  ConvexObject encode(String path) {
    return ConvexObject({
      'targetType': ConvexString('strategy'),
      'folderPublicId': folderPublicId == null
          ? const ConvexNull()
          : ConvexString(folderPublicId!),
      'ok': ConvexBoolean(_expectLiteral(ok, true, '$path.ok')),
      'role': ConvexString(role.wireName),
      'strategyPublicId': ConvexString(strategyPublicId),
    });
  }
}

final class StrategiesGetHeaderResult {
  const StrategiesGetHeaderResult({
    required this.createdAt,
    required this.mapData,
    required this.name,
    required this.publicId,
    required this.revision,
    required this.role,
    required this.themeOverridePalette,
    required this.themeProfileId,
    required this.updatedAt,
  });
  final double createdAt;
  final String mapData;
  final String name;
  final String publicId;
  final double revision;
  final FoldersListTreeResultItemRole role;
  final OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette?
  themeOverridePalette;
  final String? themeProfileId;
  final double updatedAt;

  factory StrategiesGetHeaderResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'createdAt',
      'mapData',
      'name',
      'publicId',
      'revision',
      'role',
      'themeOverridePalette',
      'themeProfileId',
      'updatedAt',
    });
    return StrategiesGetHeaderResult(
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      mapData: _decodeString(
        object.value['mapData'] ?? _missing(path, 'mapData'),
        '$path.mapData',
      ),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      role: FoldersListTreeResultItemRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
      themeOverridePalette:
          (object.value['themeOverridePalette'] ??
                  _missing(path, 'themeOverridePalette'))
              is ConvexNull
          ? null
          : OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette.decode(
              object.value['themeOverridePalette'] ??
                  _missing(path, 'themeOverridePalette'),
              '$path.themeOverridePalette',
            ),
      themeProfileId:
          (object.value['themeProfileId'] ?? _missing(path, 'themeProfileId'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['themeProfileId'] ??
                  _missing(path, 'themeProfileId'),
              '$path.themeProfileId',
            ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'mapData': ConvexString(mapData),
      'name': ConvexString(name),
      'publicId': ConvexString(publicId),
      'revision': _encodeNumber(revision, '$path.revision'),
      'role': ConvexString(role.wireName),
      'themeOverridePalette': themeOverridePalette == null
          ? const ConvexNull()
          : themeOverridePalette!.encode('$path.themeOverridePalette'),
      'themeProfileId': themeProfileId == null
          ? const ConvexNull()
          : ConvexString(themeProfileId!),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class StrategiesListForFolderResultItem {
  const StrategiesListForFolderResultItem({
    required this.attackLabel,
    required this.createdAt,
    required this.folderPublicId,
    required this.mapData,
    required this.name,
    required this.publicId,
    required this.revision,
    required this.role,
    required this.themeOverridePalette,
    required this.themeProfileId,
    required this.updatedAt,
  });
  final StrategiesListForFolderResultItemAttackLabel attackLabel;
  final double createdAt;
  final String? folderPublicId;
  final String mapData;
  final String name;
  final String publicId;
  final double revision;
  final FoldersListTreeResultItemRole role;
  final OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette?
  themeOverridePalette;
  final String? themeProfileId;
  final double updatedAt;

  factory StrategiesListForFolderResultItem.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'attackLabel',
      'createdAt',
      'folderPublicId',
      'mapData',
      'name',
      'publicId',
      'revision',
      'role',
      'themeOverridePalette',
      'themeProfileId',
      'updatedAt',
    });
    return StrategiesListForFolderResultItem(
      attackLabel: StrategiesListForFolderResultItemAttackLabel.fromWireName(
        _decodeString(
          object.value['attackLabel'] ?? _missing(path, 'attackLabel'),
          '$path.attackLabel',
        ),
        '$path.attackLabel',
      ),
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      folderPublicId:
          (object.value['folderPublicId'] ?? _missing(path, 'folderPublicId'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['folderPublicId'] ??
                  _missing(path, 'folderPublicId'),
              '$path.folderPublicId',
            ),
      mapData: _decodeString(
        object.value['mapData'] ?? _missing(path, 'mapData'),
        '$path.mapData',
      ),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      role: FoldersListTreeResultItemRole.fromWireName(
        _decodeString(
          object.value['role'] ?? _missing(path, 'role'),
          '$path.role',
        ),
        '$path.role',
      ),
      themeOverridePalette:
          (object.value['themeOverridePalette'] ??
                  _missing(path, 'themeOverridePalette'))
              is ConvexNull
          ? null
          : OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette.decode(
              object.value['themeOverridePalette'] ??
                  _missing(path, 'themeOverridePalette'),
              '$path.themeOverridePalette',
            ),
      themeProfileId:
          (object.value['themeProfileId'] ?? _missing(path, 'themeProfileId'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['themeProfileId'] ??
                  _missing(path, 'themeProfileId'),
              '$path.themeProfileId',
            ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'attackLabel': ConvexString(attackLabel.wireName),
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'folderPublicId': folderPublicId == null
          ? const ConvexNull()
          : ConvexString(folderPublicId!),
      'mapData': ConvexString(mapData),
      'name': ConvexString(name),
      'publicId': ConvexString(publicId),
      'revision': _encodeNumber(revision, '$path.revision'),
      'role': ConvexString(role.wireName),
      'themeOverridePalette': themeOverridePalette == null
          ? const ConvexNull()
          : themeOverridePalette!.encode('$path.themeOverridePalette'),
      'themeProfileId': themeProfileId == null
          ? const ConvexNull()
          : ConvexString(themeProfileId!),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class StrategyGetFullSnapshotResult {
  const StrategyGetFullSnapshotResult({
    required this.assets,
    required this.elements,
    required this.header,
    required this.lineups,
    required this.pages,
  });
  final List<ImagesListForStrategyResultItem> assets;
  final List<ElementsListForPageResultItem> elements;
  final StrategiesGetHeaderResult header;
  final List<LineupsListForPageResultItem> lineups;
  final List<StrategyGetFullSnapshotResultPagesItem> pages;

  factory StrategyGetFullSnapshotResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'assets',
      'elements',
      'header',
      'lineups',
      'pages',
    });
    return StrategyGetFullSnapshotResult(
      assets:
          _decodeArray(
                object.value['assets'] ?? _missing(path, 'assets'),
                '$path.assets',
              ).value.indexed
              .map(
                (entry) => ImagesListForStrategyResultItem.decode(
                  entry.$2,
                  _indexPath('$path.assets', entry.$1),
                ),
              )
              .toList(growable: false),
      elements:
          _decodeArray(
                object.value['elements'] ?? _missing(path, 'elements'),
                '$path.elements',
              ).value.indexed
              .map(
                (entry) => ElementsListForPageResultItem.decode(
                  entry.$2,
                  _indexPath('$path.elements', entry.$1),
                ),
              )
              .toList(growable: false),
      header: StrategiesGetHeaderResult.decode(
        object.value['header'] ?? _missing(path, 'header'),
        '$path.header',
      ),
      lineups:
          _decodeArray(
                object.value['lineups'] ?? _missing(path, 'lineups'),
                '$path.lineups',
              ).value.indexed
              .map(
                (entry) => LineupsListForPageResultItem.decode(
                  entry.$2,
                  _indexPath('$path.lineups', entry.$1),
                ),
              )
              .toList(growable: false),
      pages:
          _decodeArray(
                object.value['pages'] ?? _missing(path, 'pages'),
                '$path.pages',
              ).value.indexed
              .map(
                (entry) => StrategyGetFullSnapshotResultPagesItem.decode(
                  entry.$2,
                  _indexPath('$path.pages', entry.$1),
                ),
              )
              .toList(growable: false),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'assets': ConvexArray(
        assets.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.assets', entry.$1)),
            )
            .toList(growable: false),
      ),
      'elements': ConvexArray(
        elements.indexed
            .map(
              (entry) =>
                  entry.$2.encode(_indexPath('$path.elements', entry.$1)),
            )
            .toList(growable: false),
      ),
      'header': header.encode('$path.header'),
      'lineups': ConvexArray(
        lineups.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.lineups', entry.$1)),
            )
            .toList(growable: false),
      ),
      'pages': ConvexArray(
        pages.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.pages', entry.$1)),
            )
            .toList(growable: false),
      ),
    });
  }
}

final class StrategyGetFullSnapshotResultPagesItem {
  const StrategyGetFullSnapshotResultPagesItem({
    required this.contentCreatedAt,
    required this.contentRevision,
    required this.contentUpdatedAt,
    required this.createdAt,
    required this.isAttack,
    required this.name,
    required this.publicId,
    required this.revision,
    required this.settings,
    required this.sortIndex,
    required this.strategyPublicId,
    required this.updatedAt,
    this.isAutoNamed = const ConvexOptional.absent(),
  });
  final double contentCreatedAt;
  final double contentRevision;
  final double contentUpdatedAt;
  final double createdAt;
  final bool isAttack;
  final ConvexOptional<bool> isAutoNamed;
  final String name;
  final String publicId;
  final double revision;
  final OpsApplyBatchArgsOpsItemPageAddPayloadSettings? settings;
  final double sortIndex;
  final String strategyPublicId;
  final double updatedAt;

  factory StrategyGetFullSnapshotResultPagesItem.decode(
    ConvexValue value,
    String path,
  ) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'contentCreatedAt',
      'contentRevision',
      'contentUpdatedAt',
      'createdAt',
      'isAttack',
      'isAutoNamed',
      'name',
      'publicId',
      'revision',
      'settings',
      'sortIndex',
      'strategyPublicId',
      'updatedAt',
    });
    return StrategyGetFullSnapshotResultPagesItem(
      contentCreatedAt: _decodeNumber(
        object.value['contentCreatedAt'] ?? _missing(path, 'contentCreatedAt'),
        '$path.contentCreatedAt',
      ),
      contentRevision: _decodeNumber(
        object.value['contentRevision'] ?? _missing(path, 'contentRevision'),
        '$path.contentRevision',
      ),
      contentUpdatedAt: _decodeNumber(
        object.value['contentUpdatedAt'] ?? _missing(path, 'contentUpdatedAt'),
        '$path.contentUpdatedAt',
      ),
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      isAttack: _decodeBoolean(
        object.value['isAttack'] ?? _missing(path, 'isAttack'),
        '$path.isAttack',
      ),
      isAutoNamed: object.value.containsKey('isAutoNamed')
          ? ConvexOptional.present(
              _decodeBoolean(object.value['isAutoNamed']!, '$path.isAutoNamed'),
            )
          : const ConvexOptional.absent(),
      name: _decodeString(
        object.value['name'] ?? _missing(path, 'name'),
        '$path.name',
      ),
      publicId: _decodeString(
        object.value['publicId'] ?? _missing(path, 'publicId'),
        '$path.publicId',
      ),
      revision: _decodeNumber(
        object.value['revision'] ?? _missing(path, 'revision'),
        '$path.revision',
      ),
      settings:
          (object.value['settings'] ?? _missing(path, 'settings')) is ConvexNull
          ? null
          : OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
              object.value['settings'] ?? _missing(path, 'settings'),
              '$path.settings',
            ),
      sortIndex: _decodeNumber(
        object.value['sortIndex'] ?? _missing(path, 'sortIndex'),
        '$path.sortIndex',
      ),
      strategyPublicId: _decodeString(
        object.value['strategyPublicId'] ?? _missing(path, 'strategyPublicId'),
        '$path.strategyPublicId',
      ),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'contentCreatedAt': _encodeNumber(
        contentCreatedAt,
        '$path.contentCreatedAt',
      ),
      'contentRevision': _encodeNumber(
        contentRevision,
        '$path.contentRevision',
      ),
      'contentUpdatedAt': _encodeNumber(
        contentUpdatedAt,
        '$path.contentUpdatedAt',
      ),
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'isAttack': ConvexBoolean(isAttack),
      if (isAutoNamed.isPresent)
        'isAutoNamed': ConvexBoolean(isAutoNamed.value),
      'name': ConvexString(name),
      'publicId': ConvexString(publicId),
      'revision': _encodeNumber(revision, '$path.revision'),
      'settings': settings == null
          ? const ConvexNull()
          : settings!.encode('$path.settings'),
      'sortIndex': _encodeNumber(sortIndex, '$path.sortIndex'),
      'strategyPublicId': ConvexString(strategyPublicId),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

final class StrategyGetShellResult {
  const StrategyGetShellResult({required this.header, required this.pages});
  final StrategiesGetHeaderResult header;
  final List<PageGetSnapshotResultPage> pages;

  factory StrategyGetShellResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {'header', 'pages'});
    return StrategyGetShellResult(
      header: StrategiesGetHeaderResult.decode(
        object.value['header'] ?? _missing(path, 'header'),
        '$path.header',
      ),
      pages:
          _decodeArray(
                object.value['pages'] ?? _missing(path, 'pages'),
                '$path.pages',
              ).value.indexed
              .map(
                (entry) => PageGetSnapshotResultPage.decode(
                  entry.$2,
                  _indexPath('$path.pages', entry.$1),
                ),
              )
              .toList(growable: false),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'header': header.encode('$path.header'),
      'pages': ConvexArray(
        pages.indexed
            .map(
              (entry) => entry.$2.encode(_indexPath('$path.pages', entry.$1)),
            )
            .toList(growable: false),
      ),
    });
  }
}

final class UsersMeResult {
  const UsersMeResult({
    required this.avatarUrl,
    required this.createdAt,
    required this.displayName,
    required this.externalId,
    required this.id,
    required this.updatedAt,
  });
  final String? avatarUrl;
  final double createdAt;
  final String displayName;
  final String externalId;
  final String id;
  final double updatedAt;

  factory UsersMeResult.decode(ConvexValue value, String path) {
    final object = _decodeObject(value, path);
    _checkObjectFields(object, path, const {
      'avatarUrl',
      'createdAt',
      'displayName',
      'externalId',
      'id',
      'updatedAt',
    });
    return UsersMeResult(
      avatarUrl:
          (object.value['avatarUrl'] ?? _missing(path, 'avatarUrl'))
              is ConvexNull
          ? null
          : _decodeString(
              object.value['avatarUrl'] ?? _missing(path, 'avatarUrl'),
              '$path.avatarUrl',
            ),
      createdAt: _decodeNumber(
        object.value['createdAt'] ?? _missing(path, 'createdAt'),
        '$path.createdAt',
      ),
      displayName: _decodeString(
        object.value['displayName'] ?? _missing(path, 'displayName'),
        '$path.displayName',
      ),
      externalId: _decodeString(
        object.value['externalId'] ?? _missing(path, 'externalId'),
        '$path.externalId',
      ),
      id: _decodeString(object.value['id'] ?? _missing(path, 'id'), '$path.id'),
      updatedAt: _decodeNumber(
        object.value['updatedAt'] ?? _missing(path, 'updatedAt'),
        '$path.updatedAt',
      ),
    );
  }

  ConvexObject encode(String path) {
    return ConvexObject({
      'avatarUrl': avatarUrl == null
          ? const ConvexNull()
          : ConvexString(avatarUrl!),
      'createdAt': _encodeNumber(createdAt, '$path.createdAt'),
      'displayName': ConvexString(displayName),
      'externalId': ConvexString(externalId),
      'id': ConvexString(id),
      'updatedAt': _encodeNumber(updatedAt, '$path.updatedAt'),
    });
  }
}

CloudPayload _decodeElementsListForPageResultItemPayload(
  ConvexValue value,
  String path,
) {
  final object = _decodeObject(value, path);
  final tag = _decodeString(
    object.value['kind'] ?? _missing(path, 'kind'),
    '$path.kind',
  );
  return switch (tag) {
    'agent' => _decodePayload(
      () => const AgentConvexCodec().decode(value),
      path,
    ),
    'ability' => _decodePayload(
      () => const AbilityConvexCodec().decode(value),
      path,
    ),
    'drawing' => _decodePayload(
      () => const DrawingConvexCodec().decode(value),
      path,
    ),
    'text' => _decodePayload(() => const TextConvexCodec().decode(value), path),
    'image' => _decodePayload(
      () => const ImageConvexCodec().decode(value),
      path,
    ),
    'utility' => _decodePayload(
      () => const UtilityConvexCodec().decode(value),
      path,
    ),
    _ => throw ConvexDecodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

ConvexValue _encodeElementsListForPageResultItemPayload(
  CloudPayload value,
  String path,
) {
  final tag = value['kind'];
  return switch (tag) {
    'agent' => _encodePayload(
      () => const AgentConvexCodec().encode(value),
      path,
    ),
    'ability' => _encodePayload(
      () => const AbilityConvexCodec().encode(value),
      path,
    ),
    'drawing' => _encodePayload(
      () => const DrawingConvexCodec().encode(value),
      path,
    ),
    'text' => _encodePayload(() => const TextConvexCodec().encode(value), path),
    'image' => _encodePayload(
      () => const ImageConvexCodec().encode(value),
      path,
    ),
    'utility' => _encodePayload(
      () => const UtilityConvexCodec().encode(value),
      path,
    ),
    _ => throw ConvexEncodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

CloudPayload _decodeOpsApplyBatchArgsOpsItemElementAddPayload(
  ConvexValue value,
  String path,
) {
  final object = _decodeObject(value, path);
  final tag = _decodeString(
    object.value['kind'] ?? _missing(path, 'kind'),
    '$path.kind',
  );
  return switch (tag) {
    'agent' => _decodePayload(
      () => const AgentConvexCodec().decode(value),
      path,
    ),
    'ability' => _decodePayload(
      () => const AbilityConvexCodec().decode(value),
      path,
    ),
    'drawing' => _decodePayload(
      () => const DrawingConvexCodec().decode(value),
      path,
    ),
    'text' => _decodePayload(() => const TextConvexCodec().decode(value), path),
    'image' => _decodePayload(
      () => const ImageConvexCodec().decode(value),
      path,
    ),
    'utility' => _decodePayload(
      () => const UtilityConvexCodec().decode(value),
      path,
    ),
    _ => throw ConvexDecodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

ConvexValue _encodeOpsApplyBatchArgsOpsItemElementAddPayload(
  CloudPayload value,
  String path,
) {
  final tag = value['kind'];
  return switch (tag) {
    'agent' => _encodePayload(
      () => const AgentConvexCodec().encode(value),
      path,
    ),
    'ability' => _encodePayload(
      () => const AbilityConvexCodec().encode(value),
      path,
    ),
    'drawing' => _encodePayload(
      () => const DrawingConvexCodec().encode(value),
      path,
    ),
    'text' => _encodePayload(() => const TextConvexCodec().encode(value), path),
    'image' => _encodePayload(
      () => const ImageConvexCodec().encode(value),
      path,
    ),
    'utility' => _encodePayload(
      () => const UtilityConvexCodec().encode(value),
      path,
    ),
    _ => throw ConvexEncodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

CloudPayload _decodeOpsApplyBatchArgsOpsItemElementPatchPayload(
  ConvexValue value,
  String path,
) {
  final object = _decodeObject(value, path);
  final tag = _decodeString(
    object.value['kind'] ?? _missing(path, 'kind'),
    '$path.kind',
  );
  return switch (tag) {
    'agent' => _decodePayload(
      () => const AgentConvexCodec().decode(value),
      path,
    ),
    'ability' => _decodePayload(
      () => const AbilityConvexCodec().decode(value),
      path,
    ),
    'drawing' => _decodePayload(
      () => const DrawingConvexCodec().decode(value),
      path,
    ),
    'text' => _decodePayload(() => const TextConvexCodec().decode(value), path),
    'image' => _decodePayload(
      () => const ImageConvexCodec().decode(value),
      path,
    ),
    'utility' => _decodePayload(
      () => const UtilityConvexCodec().decode(value),
      path,
    ),
    _ => throw ConvexDecodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

ConvexValue _encodeOpsApplyBatchArgsOpsItemElementPatchPayload(
  CloudPayload value,
  String path,
) {
  final tag = value['kind'];
  return switch (tag) {
    'agent' => _encodePayload(
      () => const AgentConvexCodec().encode(value),
      path,
    ),
    'ability' => _encodePayload(
      () => const AbilityConvexCodec().encode(value),
      path,
    ),
    'drawing' => _encodePayload(
      () => const DrawingConvexCodec().encode(value),
      path,
    ),
    'text' => _encodePayload(() => const TextConvexCodec().encode(value), path),
    'image' => _encodePayload(
      () => const ImageConvexCodec().encode(value),
      path,
    ),
    'utility' => _encodePayload(
      () => const UtilityConvexCodec().encode(value),
      path,
    ),
    _ => throw ConvexEncodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

CloudPayload _decodeOpsApplyBatchResultResultsItemRejectedCurrentElementValue(
  ConvexValue value,
  String path,
) {
  final object = _decodeObject(value, path);
  final tag = _decodeString(
    object.value['kind'] ?? _missing(path, 'kind'),
    '$path.kind',
  );
  return switch (tag) {
    'agent' => _decodePayload(
      () => const AgentConvexCodec().decode(value),
      path,
    ),
    'ability' => _decodePayload(
      () => const AbilityConvexCodec().decode(value),
      path,
    ),
    'drawing' => _decodePayload(
      () => const DrawingConvexCodec().decode(value),
      path,
    ),
    'text' => _decodePayload(() => const TextConvexCodec().decode(value), path),
    'image' => _decodePayload(
      () => const ImageConvexCodec().decode(value),
      path,
    ),
    'utility' => _decodePayload(
      () => const UtilityConvexCodec().decode(value),
      path,
    ),
    _ => throw ConvexDecodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

ConvexValue _encodeOpsApplyBatchResultResultsItemRejectedCurrentElementValue(
  CloudPayload value,
  String path,
) {
  final tag = value['kind'];
  return switch (tag) {
    'agent' => _encodePayload(
      () => const AgentConvexCodec().encode(value),
      path,
    ),
    'ability' => _encodePayload(
      () => const AbilityConvexCodec().encode(value),
      path,
    ),
    'drawing' => _encodePayload(
      () => const DrawingConvexCodec().encode(value),
      path,
    ),
    'text' => _encodePayload(() => const TextConvexCodec().encode(value), path),
    'image' => _encodePayload(
      () => const ImageConvexCodec().encode(value),
      path,
    ),
    'utility' => _encodePayload(
      () => const UtilityConvexCodec().encode(value),
      path,
    ),
    _ => throw ConvexEncodingException(
      '$path.kind',
      'unknown payload tag $tag',
    ),
  };
}

bool _validateFoldersCreateResult(ConvexValue value) =>
    (_matchesRaw0(value) || _matchesRaw2(value));

bool _matchesRaw0(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(const {'ok'}.contains) &&
    (value.value['ok'] != null && _matchesRaw1(value.value['ok']!));

bool _matchesRaw1(ConvexValue value) =>
    value is ConvexBoolean && value.value == true;

bool _matchesRaw2(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(const {'ok', 'reused'}.contains) &&
    (value.value['ok'] != null && _matchesRaw1(value.value['ok']!)) &&
    (value.value['reused'] != null && _matchesRaw1(value.value['reused']!));

bool _validateInvitesGetResult(ConvexValue value) =>
    (_matchesRaw3(value) || _matchesRaw12(value) || _matchesRaw6(value));

bool _matchesRaw3(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(
      const {
        'createdAt',
        'expiresAt',
        'hasAccessAlready',
        'inviteRole',
        'revoked',
        'strategyPublicId',
        'token',
      }.contains,
    ) &&
    (value.value['createdAt'] != null &&
        _matchesRaw4(value.value['createdAt']!)) &&
    (value.value['expiresAt'] != null &&
        _matchesRaw5(value.value['expiresAt']!)) &&
    (value.value['hasAccessAlready'] != null &&
        _matchesRaw7(value.value['hasAccessAlready']!)) &&
    (value.value['inviteRole'] != null &&
        _matchesRaw8(value.value['inviteRole']!)) &&
    (value.value['revoked'] != null && _matchesRaw7(value.value['revoked']!)) &&
    (value.value['strategyPublicId'] != null &&
        _matchesRaw11(value.value['strategyPublicId']!)) &&
    (value.value['token'] != null && _matchesRaw11(value.value['token']!));

bool _matchesRaw4(ConvexValue value) =>
    (value is ConvexFloat || value is ConvexInteger);

bool _matchesRaw5(ConvexValue value) =>
    (_matchesRaw4(value) || _matchesRaw6(value));

bool _matchesRaw6(ConvexValue value) => value is ConvexNull;

bool _matchesRaw7(ConvexValue value) => value is ConvexBoolean;

bool _matchesRaw8(ConvexValue value) =>
    (_matchesRaw9(value) || _matchesRaw10(value));

bool _matchesRaw9(ConvexValue value) =>
    value is ConvexString && value.value == 'editor';

bool _matchesRaw10(ConvexValue value) =>
    value is ConvexString && value.value == 'viewer';

bool _matchesRaw11(ConvexValue value) => value is ConvexString;

bool _matchesRaw12(ConvexValue value) =>
    value is ConvexArray && value.value.every((item) => _matchesRaw13(item));

bool _matchesRaw13(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(
      const {
        'createdAt',
        'expiresAt',
        'redeemed',
        'revokedAt',
        'role',
        'token',
      }.contains,
    ) &&
    (value.value['createdAt'] != null &&
        _matchesRaw4(value.value['createdAt']!)) &&
    (value.value['expiresAt'] != null &&
        _matchesRaw5(value.value['expiresAt']!)) &&
    (value.value['redeemed'] != null &&
        _matchesRaw7(value.value['redeemed']!)) &&
    (value.value['revokedAt'] != null &&
        _matchesRaw5(value.value['revokedAt']!)) &&
    (value.value['role'] != null && _matchesRaw8(value.value['role']!)) &&
    (value.value['token'] != null && _matchesRaw11(value.value['token']!));

bool _validatePagesAddResult(ConvexValue value) =>
    (_matchesRaw14(value) || _matchesRaw15(value));

bool _matchesRaw14(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(const {'ok', 'revision'}.contains) &&
    (value.value['ok'] != null && _matchesRaw1(value.value['ok']!)) &&
    (value.value['revision'] != null && _matchesRaw4(value.value['revision']!));

bool _matchesRaw15(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(const {'ok', 'reused', 'revision'}.contains) &&
    (value.value['ok'] != null && _matchesRaw1(value.value['ok']!)) &&
    (value.value['reused'] != null && _matchesRaw1(value.value['reused']!)) &&
    (value.value['revision'] != null && _matchesRaw4(value.value['revision']!));

ConvexObject encodeElementsListForPageArgs({
  required String pagePublicId,
  required String strategyPublicId,
}) => ConvexObject({
  'pagePublicId': ConvexString(pagePublicId),
  'strategyPublicId': ConvexString(strategyPublicId),
});

List<ElementsListForPageResultItem> decodeElementsListForPageResult(
  ConvexValue value,
) => _decodeArray(value, 'elements.js:listForPage.returns').value.indexed
    .map(
      (entry) => ElementsListForPageResultItem.decode(
        entry.$2,
        _indexPath('elements.js:listForPage.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeElementsListForStrategyArgs({
  required String strategyPublicId,
}) => ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

List<ElementsListForPageResultItem> decodeElementsListForStrategyResult(
  ConvexValue value,
) => _decodeArray(value, 'elements.js:listForStrategy.returns').value.indexed
    .map(
      (entry) => ElementsListForPageResultItem.decode(
        entry.$2,
        _indexPath('elements.js:listForStrategy.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeFoldersCreateArgs({
  required double clientProtocolVersion,
  ConvexOptional<String> color = const ConvexOptional.absent(),
  ConvexOptional<double> customColorValue = const ConvexOptional.absent(),
  ConvexOptional<double> iconCodePoint = const ConvexOptional.absent(),
  ConvexOptional<String> iconFontFamily = const ConvexOptional.absent(),
  ConvexOptional<String> iconFontPackage = const ConvexOptional.absent(),
  ConvexOptional<double> iconId = const ConvexOptional.absent(),
  required String name,
  ConvexOptional<String> parentFolderPublicId = const ConvexOptional.absent(),
  required String publicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'folders.js:create.args.clientProtocolVersion',
  ),
  if (color.isPresent) 'color': ConvexString(color.value),
  if (customColorValue.isPresent)
    'customColorValue': _encodeNumber(
      customColorValue.value,
      'folders.js:create.args.customColorValue',
    ),
  if (iconCodePoint.isPresent)
    'iconCodePoint': _encodeNumber(
      iconCodePoint.value,
      'folders.js:create.args.iconCodePoint',
    ),
  if (iconFontFamily.isPresent)
    'iconFontFamily': ConvexString(iconFontFamily.value),
  if (iconFontPackage.isPresent)
    'iconFontPackage': ConvexString(iconFontPackage.value),
  if (iconId.isPresent)
    'iconId': _encodeNumber(iconId.value, 'folders.js:create.args.iconId'),
  'name': ConvexString(name),
  if (parentFolderPublicId.isPresent)
    'parentFolderPublicId': ConvexString(parentFolderPublicId.value),
  'publicId': ConvexString(publicId),
});

ConvexValue decodeFoldersCreateResult(ConvexValue value) => _decodeRaw(
  value,
  'folders.js:create.returns',
  _validateFoldersCreateResult,
);

ConvexObject encodeFoldersDeleteArgs({
  required double clientProtocolVersion,
  required String folderPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'folders.js:delete.args.clientProtocolVersion',
  ),
  'folderPublicId': ConvexString(folderPublicId),
});

FoldersDeleteResult decodeFoldersDeleteResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'folders.js:delete.returns');

ConvexObject encodeFoldersListTreeArgs({
  ConvexOptional<FoldersListTreeArgsScope> scope =
      const ConvexOptional.absent(),
}) => ConvexObject({
  if (scope.isPresent) 'scope': ConvexString(scope.value.wireName),
});

List<FoldersListTreeResultItem> decodeFoldersListTreeResult(
  ConvexValue value,
) => _decodeArray(value, 'folders.js:listTree.returns').value.indexed
    .map(
      (entry) => FoldersListTreeResultItem.decode(
        entry.$2,
        _indexPath('folders.js:listTree.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeFoldersMoveArgs({
  required double clientProtocolVersion,
  required String folderPublicId,
  ConvexOptional<String> parentFolderPublicId = const ConvexOptional.absent(),
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'folders.js:move.args.clientProtocolVersion',
  ),
  'folderPublicId': ConvexString(folderPublicId),
  if (parentFolderPublicId.isPresent)
    'parentFolderPublicId': ConvexString(parentFolderPublicId.value),
});

FoldersDeleteResult decodeFoldersMoveResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'folders.js:move.returns');

ConvexObject encodeFoldersUpdateArgs({
  ConvexOptional<bool> clearCustomColorValue = const ConvexOptional.absent(),
  ConvexOptional<bool> clearIconFontFamily = const ConvexOptional.absent(),
  ConvexOptional<bool> clearIconFontPackage = const ConvexOptional.absent(),
  required double clientProtocolVersion,
  ConvexOptional<String> color = const ConvexOptional.absent(),
  ConvexOptional<double> customColorValue = const ConvexOptional.absent(),
  required String folderPublicId,
  ConvexOptional<double> iconCodePoint = const ConvexOptional.absent(),
  ConvexOptional<String> iconFontFamily = const ConvexOptional.absent(),
  ConvexOptional<String> iconFontPackage = const ConvexOptional.absent(),
  ConvexOptional<double> iconId = const ConvexOptional.absent(),
  ConvexOptional<String> name = const ConvexOptional.absent(),
}) => ConvexObject({
  if (clearCustomColorValue.isPresent)
    'clearCustomColorValue': ConvexBoolean(clearCustomColorValue.value),
  if (clearIconFontFamily.isPresent)
    'clearIconFontFamily': ConvexBoolean(clearIconFontFamily.value),
  if (clearIconFontPackage.isPresent)
    'clearIconFontPackage': ConvexBoolean(clearIconFontPackage.value),
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'folders.js:update.args.clientProtocolVersion',
  ),
  if (color.isPresent) 'color': ConvexString(color.value),
  if (customColorValue.isPresent)
    'customColorValue': _encodeNumber(
      customColorValue.value,
      'folders.js:update.args.customColorValue',
    ),
  'folderPublicId': ConvexString(folderPublicId),
  if (iconCodePoint.isPresent)
    'iconCodePoint': _encodeNumber(
      iconCodePoint.value,
      'folders.js:update.args.iconCodePoint',
    ),
  if (iconFontFamily.isPresent)
    'iconFontFamily': ConvexString(iconFontFamily.value),
  if (iconFontPackage.isPresent)
    'iconFontPackage': ConvexString(iconFontPackage.value),
  if (iconId.isPresent)
    'iconId': _encodeNumber(iconId.value, 'folders.js:update.args.iconId'),
  if (name.isPresent) 'name': ConvexString(name.value),
});

FoldersDeleteResult decodeFoldersUpdateResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'folders.js:update.returns');

ConvexObject encodeHealthPingArgs() => ConvexObject({});

HealthPingResult decodeHealthPingResult(ConvexValue value) =>
    HealthPingResult.fromWireName(
      _decodeString(value, 'health.js:ping.returns'),
      'health.js:ping.returns',
    );

ConvexObject encodeImagesCompleteUploadArgs({
  required String assetPublicId,
  ConvexOptional<double> byteSize = const ConvexOptional.absent(),
  required double clientProtocolVersion,
  ConvexOptional<String> etag = const ConvexOptional.absent(),
  ConvexOptional<String> fileExtension = const ConvexOptional.absent(),
  ConvexOptional<double> height = const ConvexOptional.absent(),
  ConvexOptional<String> mimeType = const ConvexOptional.absent(),
  ConvexOptional<String> objectKey = const ConvexOptional.absent(),
  ConvexOptional<ImagesCompleteUploadArgsProvider> provider =
      const ConvexOptional.absent(),
  ConvexOptional<String> storageId = const ConvexOptional.absent(),
  required String strategyPublicId,
  ConvexOptional<String> uploadId = const ConvexOptional.absent(),
  ConvexOptional<double> width = const ConvexOptional.absent(),
}) => ConvexObject({
  'assetPublicId': ConvexString(assetPublicId),
  if (byteSize.isPresent)
    'byteSize': _encodeNumber(
      byteSize.value,
      'images.js:completeUpload.args.byteSize',
    ),
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'images.js:completeUpload.args.clientProtocolVersion',
  ),
  if (etag.isPresent) 'etag': ConvexString(etag.value),
  if (fileExtension.isPresent)
    'fileExtension': ConvexString(fileExtension.value),
  if (height.isPresent)
    'height': _encodeNumber(
      height.value,
      'images.js:completeUpload.args.height',
    ),
  if (mimeType.isPresent) 'mimeType': ConvexString(mimeType.value),
  if (objectKey.isPresent) 'objectKey': ConvexString(objectKey.value),
  if (provider.isPresent) 'provider': ConvexString(provider.value.wireName),
  if (storageId.isPresent) 'storageId': ConvexString(storageId.value),
  'strategyPublicId': ConvexString(strategyPublicId),
  if (uploadId.isPresent) 'uploadId': ConvexString(uploadId.value),
  if (width.isPresent)
    'width': _encodeNumber(width.value, 'images.js:completeUpload.args.width'),
});

ImagesCompleteUploadResult decodeImagesCompleteUploadResult(
  ConvexValue value,
) => ImagesCompleteUploadResult.decode(
  value,
  'images.js:completeUpload.returns',
);

ConvexObject encodeImagesDeleteAssetRefArgs({
  required String assetPublicId,
  required double clientProtocolVersion,
  required String strategyPublicId,
}) => ConvexObject({
  'assetPublicId': ConvexString(assetPublicId),
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'images.js:deleteAssetRef.args.clientProtocolVersion',
  ),
  'strategyPublicId': ConvexString(strategyPublicId),
});

FoldersDeleteResult decodeImagesDeleteAssetRefResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'images.js:deleteAssetRef.returns');

ConvexObject encodeImagesGenerateUploadUrlArgs({
  required String assetPublicId,
  ConvexOptional<double> byteSize = const ConvexOptional.absent(),
  required double clientProtocolVersion,
  required String fileExtension,
  ConvexOptional<double> height = const ConvexOptional.absent(),
  required String mimeType,
  required String strategyPublicId,
  ConvexOptional<double> width = const ConvexOptional.absent(),
}) => ConvexObject({
  'assetPublicId': ConvexString(assetPublicId),
  if (byteSize.isPresent)
    'byteSize': _encodeNumber(
      byteSize.value,
      'images.js:generateUploadUrl.args.byteSize',
    ),
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'images.js:generateUploadUrl.args.clientProtocolVersion',
  ),
  'fileExtension': ConvexString(fileExtension),
  if (height.isPresent)
    'height': _encodeNumber(
      height.value,
      'images.js:generateUploadUrl.args.height',
    ),
  'mimeType': ConvexString(mimeType),
  'strategyPublicId': ConvexString(strategyPublicId),
  if (width.isPresent)
    'width': _encodeNumber(
      width.value,
      'images.js:generateUploadUrl.args.width',
    ),
});

ImagesGenerateUploadUrlResult decodeImagesGenerateUploadUrlResult(
  ConvexValue value,
) => ImagesGenerateUploadUrlResult.decode(
  value,
  'images.js:generateUploadUrl.returns',
);

ConvexObject encodeImagesGetAssetUrlArgs({
  required String assetPublicId,
  required String strategyPublicId,
}) => ConvexObject({
  'assetPublicId': ConvexString(assetPublicId),
  'strategyPublicId': ConvexString(strategyPublicId),
});

ImagesGetAssetUrlResult decodeImagesGetAssetUrlResult(ConvexValue value) =>
    ImagesGetAssetUrlResult.decode(value, 'images.js:getAssetUrl.returns');

ConvexObject encodeImagesListForStrategyArgs({
  required String strategyPublicId,
}) => ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

List<ImagesListForStrategyResultItem> decodeImagesListForStrategyResult(
  ConvexValue value,
) => _decodeArray(value, 'images.js:listForStrategy.returns').value.indexed
    .map(
      (entry) => ImagesListForStrategyResultItem.decode(
        entry.$2,
        _indexPath('images.js:listForStrategy.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeInvitesCreateArgs({
  required double clientProtocolVersion,
  ConvexOptional<double> expiresAt = const ConvexOptional.absent(),
  required InvitesCreateArgsRole role,
  required String strategyPublicId,
  required String token,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'invites.js:create.args.clientProtocolVersion',
  ),
  if (expiresAt.isPresent)
    'expiresAt': _encodeNumber(
      expiresAt.value,
      'invites.js:create.args.expiresAt',
    ),
  'role': ConvexString(role.wireName),
  'strategyPublicId': ConvexString(strategyPublicId),
  'token': ConvexString(token),
});

FoldersDeleteResult decodeInvitesCreateResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'invites.js:create.returns');

ConvexObject encodeInvitesGetArgs({
  ConvexOptional<String> strategyPublicId = const ConvexOptional.absent(),
  ConvexOptional<String> token = const ConvexOptional.absent(),
}) => ConvexObject({
  if (strategyPublicId.isPresent)
    'strategyPublicId': ConvexString(strategyPublicId.value),
  if (token.isPresent) 'token': ConvexString(token.value),
});

ConvexValue decodeInvitesGetResult(ConvexValue value) =>
    _decodeRaw(value, 'invites.js:get.returns', _validateInvitesGetResult);

ConvexObject encodeInvitesRedeemArgs({
  required double clientProtocolVersion,
  required String token,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'invites.js:redeem.args.clientProtocolVersion',
  ),
  'token': ConvexString(token),
});

InvitesRedeemResult decodeInvitesRedeemResult(ConvexValue value) =>
    InvitesRedeemResult.decode(value, 'invites.js:redeem.returns');

ConvexObject encodeInvitesRevokeArgs({
  required double clientProtocolVersion,
  required String strategyPublicId,
  required String token,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'invites.js:revoke.args.clientProtocolVersion',
  ),
  'strategyPublicId': ConvexString(strategyPublicId),
  'token': ConvexString(token),
});

FoldersDeleteResult decodeInvitesRevokeResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'invites.js:revoke.returns');

ConvexObject encodeLineupsListForPageArgs({
  required String pagePublicId,
  required String strategyPublicId,
}) => ConvexObject({
  'pagePublicId': ConvexString(pagePublicId),
  'strategyPublicId': ConvexString(strategyPublicId),
});

List<LineupsListForPageResultItem> decodeLineupsListForPageResult(
  ConvexValue value,
) => _decodeArray(value, 'lineups.js:listForPage.returns').value.indexed
    .map(
      (entry) => LineupsListForPageResultItem.decode(
        entry.$2,
        _indexPath('lineups.js:listForPage.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeLineupsListForStrategyArgs({
  required String strategyPublicId,
}) => ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

List<LineupsListForPageResultItem> decodeLineupsListForStrategyResult(
  ConvexValue value,
) => _decodeArray(value, 'lineups.js:listForStrategy.returns').value.indexed
    .map(
      (entry) => LineupsListForPageResultItem.decode(
        entry.$2,
        _indexPath('lineups.js:listForStrategy.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeOpsApplyBatchArgs({
  required String clientId,
  required double clientProtocolVersion,
  required List<OpsApplyBatchArgsOpsItem> ops,
  required String strategyPublicId,
}) => ConvexObject({
  'clientId': ConvexString(clientId),
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'ops.js:applyBatch.args.clientProtocolVersion',
  ),
  'ops': ConvexArray(
    ops.indexed
        .map(
          (entry) => entry.$2.encode(
            _indexPath('ops.js:applyBatch.args.ops', entry.$1),
          ),
        )
        .toList(growable: false),
  ),
  'strategyPublicId': ConvexString(strategyPublicId),
});

OpsApplyBatchResult decodeOpsApplyBatchResult(ConvexValue value) =>
    OpsApplyBatchResult.decode(value, 'ops.js:applyBatch.returns');

ConvexObject encodePageGetSnapshotArgs({
  required String pagePublicId,
  required String strategyPublicId,
}) => ConvexObject({
  'pagePublicId': ConvexString(pagePublicId),
  'strategyPublicId': ConvexString(strategyPublicId),
});

PageGetSnapshotResult decodePageGetSnapshotResult(ConvexValue value) =>
    PageGetSnapshotResult.decode(value, 'page.js:getSnapshot.returns');

ConvexObject encodePagesAddArgs({
  required double clientProtocolVersion,
  required double expectedRevision,
  required bool isAttack,
  ConvexOptional<bool> isAutoNamed = const ConvexOptional.absent(),
  required String name,
  required String pagePublicId,
  ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings> settings =
      const ConvexOptional.absent(),
  required double sortIndex,
  required String strategyPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'pages.js:add.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'pages.js:add.args.expectedRevision',
  ),
  'isAttack': ConvexBoolean(isAttack),
  if (isAutoNamed.isPresent) 'isAutoNamed': ConvexBoolean(isAutoNamed.value),
  'name': ConvexString(name),
  'pagePublicId': ConvexString(pagePublicId),
  if (settings.isPresent)
    'settings': settings.value.encode('pages.js:add.args.settings'),
  'sortIndex': _encodeNumber(sortIndex, 'pages.js:add.args.sortIndex'),
  'strategyPublicId': ConvexString(strategyPublicId),
});

ConvexValue decodePagesAddResult(ConvexValue value) =>
    _decodeRaw(value, 'pages.js:add.returns', _validatePagesAddResult);

ConvexObject encodePagesDeleteArgs({
  required double clientProtocolVersion,
  required double expectedRevision,
  required String pagePublicId,
  required String strategyPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'pages.js:delete.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'pages.js:delete.args.expectedRevision',
  ),
  'pagePublicId': ConvexString(pagePublicId),
  'strategyPublicId': ConvexString(strategyPublicId),
});

ConvexValue decodePagesDeleteResult(ConvexValue value) =>
    _decodeRaw(value, 'pages.js:delete.returns', _validatePagesAddResult);

ConvexObject encodePagesListForStrategyArgs({
  required String strategyPublicId,
}) => ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

List<PageGetSnapshotResultPage> decodePagesListForStrategyResult(
  ConvexValue value,
) => _decodeArray(value, 'pages.js:listForStrategy.returns').value.indexed
    .map(
      (entry) => PageGetSnapshotResultPage.decode(
        entry.$2,
        _indexPath('pages.js:listForStrategy.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodePagesRenameArgs({
  required double clientProtocolVersion,
  required double expectedRevision,
  ConvexOptional<bool> isAutoNamed = const ConvexOptional.absent(),
  required String name,
  required String pagePublicId,
  required String strategyPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'pages.js:rename.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'pages.js:rename.args.expectedRevision',
  ),
  if (isAutoNamed.isPresent) 'isAutoNamed': ConvexBoolean(isAutoNamed.value),
  'name': ConvexString(name),
  'pagePublicId': ConvexString(pagePublicId),
  'strategyPublicId': ConvexString(strategyPublicId),
});

ConvexValue decodePagesRenameResult(ConvexValue value) =>
    _decodeRaw(value, 'pages.js:rename.returns', _validatePagesAddResult);

ConvexObject encodePagesReorderArgs({
  required double clientProtocolVersion,
  required double expectedRevision,
  required List<String> orderedPagePublicIds,
  required String strategyPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'pages.js:reorder.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'pages.js:reorder.args.expectedRevision',
  ),
  'orderedPagePublicIds': ConvexArray(
    orderedPagePublicIds.indexed
        .map((entry) => ConvexString(entry.$2))
        .toList(growable: false),
  ),
  'strategyPublicId': ConvexString(strategyPublicId),
});

ConvexValue decodePagesReorderResult(ConvexValue value) =>
    _decodeRaw(value, 'pages.js:reorder.returns', _validatePagesAddResult);

ConvexObject encodeSharesCreateArgs({
  required double clientProtocolVersion,
  required InvitesCreateArgsRole role,
  required String targetPublicId,
  required SharesCreateArgsTargetType targetType,
  required String token,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'shares.js:create.args.clientProtocolVersion',
  ),
  'role': ConvexString(role.wireName),
  'targetPublicId': ConvexString(targetPublicId),
  'targetType': ConvexString(targetType.wireName),
  'token': ConvexString(token),
});

FoldersDeleteResult decodeSharesCreateResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'shares.js:create.returns');

ConvexObject encodeSharesListArgs({
  required String targetPublicId,
  required SharesCreateArgsTargetType targetType,
}) => ConvexObject({
  'targetPublicId': ConvexString(targetPublicId),
  'targetType': ConvexString(targetType.wireName),
});

List<SharesListResultItem> decodeSharesListResult(ConvexValue value) =>
    _decodeArray(value, 'shares.js:list.returns').value.indexed
        .map(
          (entry) => SharesListResultItem.decode(
            entry.$2,
            _indexPath('shares.js:list.returns', entry.$1),
          ),
        )
        .toList(growable: false);

ConvexObject encodeSharesRedeemArgs({
  required double clientProtocolVersion,
  required String token,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'shares.js:redeem.args.clientProtocolVersion',
  ),
  'token': ConvexString(token),
});

SharesRedeemResult decodeSharesRedeemResult(ConvexValue value) =>
    SharesRedeemResult.decode(value, 'shares.js:redeem.returns');

ConvexObject encodeSharesRevokeArgs({
  required double clientProtocolVersion,
  required String targetPublicId,
  required SharesCreateArgsTargetType targetType,
  required String token,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'shares.js:revoke.args.clientProtocolVersion',
  ),
  'targetPublicId': ConvexString(targetPublicId),
  'targetType': ConvexString(targetType.wireName),
  'token': ConvexString(token),
});

FoldersDeleteResult decodeSharesRevokeResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'shares.js:revoke.returns');

ConvexObject encodeStrategiesCreateArgs({
  required double clientProtocolVersion,
  ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
  required String mapData,
  required String name,
  required String publicId,
  ConvexOptional<
        OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
      >
      themeOverridePalette =
      const ConvexOptional.absent(),
  ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'strategies.js:create.args.clientProtocolVersion',
  ),
  if (folderPublicId.isPresent)
    'folderPublicId': ConvexString(folderPublicId.value),
  'mapData': ConvexString(mapData),
  'name': ConvexString(name),
  'publicId': ConvexString(publicId),
  if (themeOverridePalette.isPresent)
    'themeOverridePalette': themeOverridePalette.value.encode(
      'strategies.js:create.args.themeOverridePalette',
    ),
  if (themeProfileId.isPresent)
    'themeProfileId': ConvexString(themeProfileId.value),
});

ConvexValue decodeStrategiesCreateResult(ConvexValue value) => _decodeRaw(
  value,
  'strategies.js:create.returns',
  _validateFoldersCreateResult,
);

ConvexObject encodeStrategiesCreateWithInitialPageArgs({
  required double clientProtocolVersion,
  ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
  required bool initialPageIsAttack,
  ConvexOptional<bool> initialPageIsAutoNamed = const ConvexOptional.absent(),
  required String initialPageName,
  required String initialPagePublicId,
  ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings>
      initialPageSettings =
      const ConvexOptional.absent(),
  required String mapData,
  required String name,
  required String publicId,
  ConvexOptional<
        OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
      >
      themeOverridePalette =
      const ConvexOptional.absent(),
  ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'strategies.js:createWithInitialPage.args.clientProtocolVersion',
  ),
  if (folderPublicId.isPresent)
    'folderPublicId': ConvexString(folderPublicId.value),
  'initialPageIsAttack': ConvexBoolean(initialPageIsAttack),
  if (initialPageIsAutoNamed.isPresent)
    'initialPageIsAutoNamed': ConvexBoolean(initialPageIsAutoNamed.value),
  'initialPageName': ConvexString(initialPageName),
  'initialPagePublicId': ConvexString(initialPagePublicId),
  if (initialPageSettings.isPresent)
    'initialPageSettings': initialPageSettings.value.encode(
      'strategies.js:createWithInitialPage.args.initialPageSettings',
    ),
  'mapData': ConvexString(mapData),
  'name': ConvexString(name),
  'publicId': ConvexString(publicId),
  if (themeOverridePalette.isPresent)
    'themeOverridePalette': themeOverridePalette.value.encode(
      'strategies.js:createWithInitialPage.args.themeOverridePalette',
    ),
  if (themeProfileId.isPresent)
    'themeProfileId': ConvexString(themeProfileId.value),
});

ConvexValue decodeStrategiesCreateWithInitialPageResult(ConvexValue value) =>
    _decodeRaw(
      value,
      'strategies.js:createWithInitialPage.returns',
      _validateFoldersCreateResult,
    );

ConvexObject encodeStrategiesDeleteArgs({
  required double clientProtocolVersion,
  required double expectedRevision,
  required String strategyPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'strategies.js:delete.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'strategies.js:delete.args.expectedRevision',
  ),
  'strategyPublicId': ConvexString(strategyPublicId),
});

FoldersDeleteResult decodeStrategiesDeleteResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'strategies.js:delete.returns');

ConvexObject encodeStrategiesGetHeaderArgs({
  required String strategyPublicId,
}) => ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

StrategiesGetHeaderResult decodeStrategiesGetHeaderResult(ConvexValue value) =>
    StrategiesGetHeaderResult.decode(value, 'strategies.js:getHeader.returns');

ConvexObject encodeStrategiesListForFolderArgs({
  ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
  ConvexOptional<FoldersListTreeArgsScope> scope =
      const ConvexOptional.absent(),
}) => ConvexObject({
  if (folderPublicId.isPresent)
    'folderPublicId': ConvexString(folderPublicId.value),
  if (scope.isPresent) 'scope': ConvexString(scope.value.wireName),
});

List<StrategiesListForFolderResultItem> decodeStrategiesListForFolderResult(
  ConvexValue value,
) => _decodeArray(value, 'strategies.js:listForFolder.returns').value.indexed
    .map(
      (entry) => StrategiesListForFolderResultItem.decode(
        entry.$2,
        _indexPath('strategies.js:listForFolder.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeStrategiesListSharedWithMeArgs() => ConvexObject({});

List<StrategiesListForFolderResultItem> decodeStrategiesListSharedWithMeResult(
  ConvexValue value,
) => _decodeArray(value, 'strategies.js:listSharedWithMe.returns').value.indexed
    .map(
      (entry) => StrategiesListForFolderResultItem.decode(
        entry.$2,
        _indexPath('strategies.js:listSharedWithMe.returns', entry.$1),
      ),
    )
    .toList(growable: false);

ConvexObject encodeStrategiesMoveArgs({
  required double clientProtocolVersion,
  required double expectedRevision,
  ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
  required String strategyPublicId,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'strategies.js:move.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'strategies.js:move.args.expectedRevision',
  ),
  if (folderPublicId.isPresent)
    'folderPublicId': ConvexString(folderPublicId.value),
  'strategyPublicId': ConvexString(strategyPublicId),
});

ConvexValue decodeStrategiesMoveResult(ConvexValue value) =>
    _decodeRaw(value, 'strategies.js:move.returns', _validatePagesAddResult);

ConvexObject encodeStrategiesUpdateArgs({
  ConvexOptional<bool> clearThemeOverridePalette =
      const ConvexOptional.absent(),
  ConvexOptional<bool> clearThemeProfileId = const ConvexOptional.absent(),
  required double clientProtocolVersion,
  required double expectedRevision,
  ConvexOptional<String> mapData = const ConvexOptional.absent(),
  ConvexOptional<String> name = const ConvexOptional.absent(),
  required String strategyPublicId,
  ConvexOptional<
        OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
      >
      themeOverridePalette =
      const ConvexOptional.absent(),
  ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
}) => ConvexObject({
  if (clearThemeOverridePalette.isPresent)
    'clearThemeOverridePalette': ConvexBoolean(clearThemeOverridePalette.value),
  if (clearThemeProfileId.isPresent)
    'clearThemeProfileId': ConvexBoolean(clearThemeProfileId.value),
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'strategies.js:update.args.clientProtocolVersion',
  ),
  'expectedRevision': _encodeNumber(
    expectedRevision,
    'strategies.js:update.args.expectedRevision',
  ),
  if (mapData.isPresent) 'mapData': ConvexString(mapData.value),
  if (name.isPresent) 'name': ConvexString(name.value),
  'strategyPublicId': ConvexString(strategyPublicId),
  if (themeOverridePalette.isPresent)
    'themeOverridePalette': themeOverridePalette.value.encode(
      'strategies.js:update.args.themeOverridePalette',
    ),
  if (themeProfileId.isPresent)
    'themeProfileId': ConvexString(themeProfileId.value),
});

ConvexValue decodeStrategiesUpdateResult(ConvexValue value) =>
    _decodeRaw(value, 'strategies.js:update.returns', _validatePagesAddResult);

ConvexObject encodeStrategyGetFullSnapshotArgs({
  required String strategyPublicId,
}) => ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

StrategyGetFullSnapshotResult decodeStrategyGetFullSnapshotResult(
  ConvexValue value,
) => StrategyGetFullSnapshotResult.decode(
  value,
  'strategy.js:getFullSnapshot.returns',
);

ConvexObject encodeStrategyGetShellArgs({required String strategyPublicId}) =>
    ConvexObject({'strategyPublicId': ConvexString(strategyPublicId)});

StrategyGetShellResult decodeStrategyGetShellResult(ConvexValue value) =>
    StrategyGetShellResult.decode(value, 'strategy.js:getShell.returns');

ConvexObject encodeUsersEnsureCurrentUserArgs({
  required double clientProtocolVersion,
}) => ConvexObject({
  'clientProtocolVersion': _encodeNumber(
    clientProtocolVersion,
    'users.js:ensureCurrentUser.args.clientProtocolVersion',
  ),
});

FoldersDeleteResult decodeUsersEnsureCurrentUserResult(ConvexValue value) =>
    FoldersDeleteResult.decode(value, 'users.js:ensureCurrentUser.returns');

ConvexObject encodeUsersMeArgs() => ConvexObject({});

UsersMeResult? decodeUsersMeResult(ConvexValue value) => (value) is ConvexNull
    ? null
    : UsersMeResult.decode(value, 'users.js:me.returns');
