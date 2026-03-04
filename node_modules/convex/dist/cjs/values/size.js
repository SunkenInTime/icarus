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
var size_exports = {};
__export(size_exports, {
  SYSTEM_FIELD_CREATION_TIME_SIZE: () => SYSTEM_FIELD_CREATION_TIME_SIZE,
  SYSTEM_FIELD_ID_ESTIMATE: () => SYSTEM_FIELD_ID_ESTIMATE,
  getConvexSize: () => getConvexSize,
  getDocumentSize: () => getDocumentSize
});
module.exports = __toCommonJS(size_exports);
var import_common = require("../common/index.js");
function getConvexSize(value) {
  if (value === null) {
    return 1;
  }
  if (typeof value === "boolean") {
    return 1;
  }
  if (typeof value === "bigint") {
    return 9;
  }
  if (typeof value === "number") {
    return 9;
  }
  if (typeof value === "string") {
    return 2 + getUtf8ByteLength(value);
  }
  if (value instanceof ArrayBuffer) {
    return 2 + value.byteLength;
  }
  if (Array.isArray(value)) {
    let size = 2;
    for (const element of value) {
      size += getConvexSize(element);
    }
    return size;
  }
  if ((0, import_common.isSimpleObject)(value)) {
    let size = 2;
    for (const [key, val] of Object.entries(value)) {
      if (val !== void 0) {
        size += getUtf8ByteLength(key) + 1 + getConvexSize(val);
      }
    }
    return size;
  }
  throw new Error(`Unsupported value type: ${typeof value}`);
}
const UTF8_LENGTH_THRESHOLD = 500;
function getUtf8ByteLength(str) {
  if (str.length > UTF8_LENGTH_THRESHOLD) {
    return new TextEncoder().encode(str).length;
  }
  let bytes = 0;
  for (let i = 0; i < str.length; i++) {
    const code = str.charCodeAt(i);
    if (code < 128) {
      bytes += 1;
    } else if (code < 2048) {
      bytes += 2;
    } else if (code >= 55296 && code <= 56319) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
const SYSTEM_FIELD_ID_ESTIMATE = 38;
const SYSTEM_FIELD_CREATION_TIME_SIZE = 23;
function getDocumentSize(value, options) {
  const baseSize = getConvexSize(value);
  const hasId = "_id" in value && value["_id"] !== void 0;
  const hasCreationTime = "_creationTime" in value && value["_creationTime"] !== void 0;
  if (hasId && hasCreationTime) {
    return baseSize;
  }
  let additionalSize = 0;
  if (!hasId) {
    if (options?.customIdLength) {
      additionalSize += options.customIdLength + 6;
    } else {
      additionalSize += SYSTEM_FIELD_ID_ESTIMATE;
    }
  }
  if (!hasCreationTime) {
    additionalSize += SYSTEM_FIELD_CREATION_TIME_SIZE;
  }
  return baseSize + additionalSize;
}
//# sourceMappingURL=size.js.map
