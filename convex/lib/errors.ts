import { ConvexError } from 'convex/values';

export type ErrorCode =
  | "CLIENT_UPGRADE_REQUIRED"
  | "CONFLICT"
  | "ELEMENT_STRATEGY_MISMATCH"
  | "ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH"
  | "FORBIDDEN"
  | "INTERNAL_ERROR"
  | "INVALID_ELEMENT_PAYLOAD_DATA"
  | "INVALID_ELEMENT_PAYLOAD_KIND"
  | "INVALID_ELEMENT_PAYLOAD_VERSION"
  | "INVALID_LINEUP_PAYLOAD_DATA"
  | "INVALID_LINEUP_PAYLOAD_KIND"
  | "INVALID_LINEUP_PAYLOAD_VERSION"
  | "INVALID_OP"
  | "INVALID_PAYLOAD"
  | "INVITE_EXPIRED"
  | "INVITE_REVOKED"
  | "LINEUP_STRATEGY_MISMATCH"
  | "MISSING_ADD_ELEMENT_ARGS"
  | "MISSING_ADD_LINEUP_ARGS"
  | "MISSING_ELEMENT_PAYLOAD"
  | "MISSING_ENTITY_PUBLIC_ID"
  | "MISSING_LINEUP_PAYLOAD"
  | "MISSING_PAGE_ID"
  | "MISSING_PAGE_PUBLIC_ID"
  | "NOT_FOUND"
  | "PAGE_STRATEGY_MISMATCH"
  | "R2_OBJECT_KEY_MISMATCH"
  | "SHARE_LINK_REVOKED"
  | "UNAUTHENTICATED"
  | "UNSUPPORTED_OP"
  | "UPLOAD_INTENT_NOT_FOUND";

type ErrorData = {
  code: ErrorCode;
  message: string;
};

function makeError(code: ErrorCode, message: string): ConvexError<ErrorData> {
  return new ConvexError({ code, message });
}

export function unauthenticatedError(): ConvexError<ErrorData> {
  return makeError("UNAUTHENTICATED", "Unauthenticated");
}

export function forbiddenError(): ConvexError<ErrorData> {
  return makeError("FORBIDDEN", "Forbidden");
}

export function notFoundError(entity: string, id: string): ConvexError<ErrorData> {
  return makeError("NOT_FOUND", `${entity} not found: ${id}`);
}

export function clientUpgradeRequiredError(): ConvexError<ErrorData> {
  return makeError("CLIENT_UPGRADE_REQUIRED", "Client upgrade required");
}

export function invalidPayloadError(detail: string): ConvexError<ErrorData> {
  return makeError("INVALID_PAYLOAD", detail);
}

export function conflictError(detail: string): ConvexError<ErrorData> {
  return makeError("CONFLICT", detail);
}

export function invalidOpError(detail: string): ConvexError<ErrorData> {
  return makeError("INVALID_OP", detail);
}

export function internalError(detail: string): ConvexError<ErrorData> {
  return makeError("INTERNAL_ERROR", detail);
}

export function errorWithCode(code: ErrorCode, detail: string): ConvexError<ErrorData> {
  return makeError(code, detail);
}
