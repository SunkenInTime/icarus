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
var extractDeploymentNameForWorkOS_exports = {};
__export(extractDeploymentNameForWorkOS_exports, {
  extractDeploymentNameForWorkOS: () => extractDeploymentNameForWorkOS
});
module.exports = __toCommonJS(extractDeploymentNameForWorkOS_exports);
function extractDeploymentNameForWorkOS(url) {
  return url.match(
    /^https:\/\/([a-z]+-[a-z]+-[0-9]+)\.(?:[^.]+\.)?convex\.cloud$/
  )?.[1] ?? null;
}
//# sourceMappingURL=extractDeploymentNameForWorkOS.js.map
