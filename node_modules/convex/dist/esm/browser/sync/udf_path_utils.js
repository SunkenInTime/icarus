"use strict";
import { convexToJson } from "../../values/index.js";
export function canonicalizeUdfPath(udfPath) {
  const pieces = udfPath.split(":");
  let moduleName;
  let functionName;
  if (pieces.length === 1) {
    moduleName = pieces[0];
    functionName = "default";
  } else {
    moduleName = pieces.slice(0, pieces.length - 1).join(":");
    functionName = pieces[pieces.length - 1];
  }
  if (moduleName.endsWith(".js")) {
    moduleName = moduleName.slice(0, -3);
  }
  return `${moduleName}:${functionName}`;
}
export function serializePathAndArgs(udfPath, args) {
  return JSON.stringify({
    udfPath: canonicalizeUdfPath(udfPath),
    args: convexToJson(args)
  });
}
export function serializePaginatedPathAndArgs(udfPath, args, options) {
  const { initialNumItems, id } = options;
  const result = JSON.stringify({
    type: "paginated",
    udfPath: canonicalizeUdfPath(udfPath),
    args: convexToJson(args),
    options: convexToJson({ initialNumItems, id })
  });
  return result;
}
export function serializedQueryTokenIsPaginated(token) {
  return JSON.parse(token).type === "paginated";
}
//# sourceMappingURL=udf_path_utils.js.map
