"use strict";
export function extractDeploymentNameForWorkOS(url) {
  return url.match(
    /^https:\/\/([a-z]+-[a-z]+-[0-9]+)\.(?:[^.]+\.)?convex\.cloud$/
  )?.[1] ?? null;
}
//# sourceMappingURL=extractDeploymentNameForWorkOS.js.map
