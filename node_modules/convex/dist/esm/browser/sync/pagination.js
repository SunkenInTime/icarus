"use strict";
export function asPaginationArgs(value) {
  if (typeof value.paginationOpts.numItems !== "number") {
    throw new Error(`Not valid paginated query args: ${JSON.stringify(value)}`);
  }
  return value;
}
export function asPaginationResult(value) {
  if (typeof value !== "object" || value === null || !Array.isArray(value.page) || typeof value.isDone !== "boolean" || typeof value.continueCursor !== "string") {
    throw new Error(`Not a valid paginated query result: ${value?.toString()}`);
  }
  return value;
}
//# sourceMappingURL=pagination.js.map
