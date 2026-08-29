// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated from convex/function_spec.json by tool/icarus_convex_codegen.
// ignore_for_file: prefer_const_constructors, unused_element, unused_import

import '../transport/convex_transport.dart';

enum ConvexErrorCode {
  clientUpgradeRequired('CLIENT_UPGRADE_REQUIRED'),
  conflict('CONFLICT'),
  elementStrategyMismatch('ELEMENT_STRATEGY_MISMATCH'),
  elementTypePayloadKindMismatch('ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH'),
  forbidden('FORBIDDEN'),
  internalError('INTERNAL_ERROR'),
  invalidElementPayloadData('INVALID_ELEMENT_PAYLOAD_DATA'),
  invalidElementPayloadKind('INVALID_ELEMENT_PAYLOAD_KIND'),
  invalidElementPayloadVersion('INVALID_ELEMENT_PAYLOAD_VERSION'),
  invalidLineupPayloadData('INVALID_LINEUP_PAYLOAD_DATA'),
  invalidLineupPayloadKind('INVALID_LINEUP_PAYLOAD_KIND'),
  invalidLineupPayloadVersion('INVALID_LINEUP_PAYLOAD_VERSION'),
  invalidOp('INVALID_OP'),
  invalidPageContentCount('INVALID_PAGE_CONTENT_COUNT'),
  invalidPayload('INVALID_PAYLOAD'),
  inviteExpired('INVITE_EXPIRED'),
  inviteRevoked('INVITE_REVOKED'),
  lineupStrategyMismatch('LINEUP_STRATEGY_MISMATCH'),
  missingAddElementArgs('MISSING_ADD_ELEMENT_ARGS'),
  missingAddLineupArgs('MISSING_ADD_LINEUP_ARGS'),
  missingElementPayload('MISSING_ELEMENT_PAYLOAD'),
  missingEntityPublicId('MISSING_ENTITY_PUBLIC_ID'),
  missingLineupPayload('MISSING_LINEUP_PAYLOAD'),
  missingPageId('MISSING_PAGE_ID'),
  missingPagePublicId('MISSING_PAGE_PUBLIC_ID'),
  notFound('NOT_FOUND'),
  pageDescriptorRequiresPageOp('PAGE_DESCRIPTOR_REQUIRES_PAGE_OP'),
  pageSettingsRequirePageContent('PAGE_SETTINGS_REQUIRE_PAGE_CONTENT'),
  pageStrategyMismatch('PAGE_STRATEGY_MISMATCH'),
  r2ObjectKeyMismatch('R2_OBJECT_KEY_MISMATCH'),
  shareLinkRevoked('SHARE_LINK_REVOKED'),
  unauthenticated('UNAUTHENTICATED'),
  unsupportedOp('UNSUPPORTED_OP'),
  uploadIntentNotFound('UPLOAD_INTENT_NOT_FOUND'),
  unknown('UNKNOWN');

  const ConvexErrorCode(this.wireName);
  final String wireName;

  static ConvexErrorCode fromWireName(String rawCode) {
    for (final code in values) {
      if (code != unknown && code.wireName == rawCode) return code;
    }
    return unknown;
  }
}

final class ConvexFunctionException implements Exception {
  const ConvexFunctionException({
    required this.code,
    required this.rawCode,
    required this.message,
    this.data,
  });

  factory ConvexFunctionException.fromTransport(ConvexTransportError error) =>
      ConvexFunctionException(
        code: ConvexErrorCode.fromWireName(error.rawCode),
        rawCode: error.rawCode,
        message: error.message,
        data: error.data,
      );

  final ConvexErrorCode code;
  final String rawCode;
  final String message;
  final ConvexValue? data;

  @override
  String toString() =>
      'ConvexFunctionException('
      '$rawCode, $message)';
}
