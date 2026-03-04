"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var pagination_exports = {};
__export(pagination_exports, {
  asPaginationArgs: () => asPaginationArgs,
  asPaginationResult: () => asPaginationResult
});
module.exports = __toCommonJS(pagination_exports);
function asPaginationArgs(value) {
  if (typeof value.paginationOpts.numItems !== "number") {
    throw new Error(`Not valid paginated query args: ${JSON.stringify(value)}`);
  }
  return value;
}
function asPaginationResult(value) {
  if (typeof value !== "object" || value === null || !Array.isArray(value.page) || typeof value.isDone !== "boolean" || typeof value.continueCursor !== "string") {
    throw new Error(`Not a valid paginated query result: ${value?.toString()}`);
  }
  return value;
}
//# sourceMappingURL=pagination.js.map
