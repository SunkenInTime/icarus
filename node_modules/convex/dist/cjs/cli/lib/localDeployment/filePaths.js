"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
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
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var filePaths_exports = {};
__export(filePaths_exports, {
  binariesDir: () => binariesDir,
  dashboardDir: () => dashboardDir,
  dashboardOutDir: () => dashboardOutDir,
  dashboardZip: () => dashboardZip,
  deploymentStateDir: () => deploymentStateDir,
  deploymentStateDirUnchecked: () => deploymentStateDirUnchecked,
  ensureDotConvexGitignore: () => ensureDotConvexGitignore,
  ensureUuidForAnonymousUser: () => ensureUuidForAnonymousUser,
  executableName: () => executableName,
  executablePath: () => executablePath,
  legacyDeploymentStateDir: () => legacyDeploymentStateDir,
  loadDashboardConfig: () => loadDashboardConfig,
  loadDeploymentConfig: () => loadDeploymentConfig,
  loadDeploymentConfigFromDir: () => loadDeploymentConfigFromDir,
  loadProjectLocalConfig: () => loadProjectLocalConfig,
  loadUuidForAnonymousUser: () => loadUuidForAnonymousUser,
  projectLocalStateDir: () => projectLocalStateDir,
  resetDashboardDir: () => resetDashboardDir,
  rootDeploymentStateDir: () => rootDeploymentStateDir,
  saveDashboardConfig: () => saveDashboardConfig,
  saveDeploymentConfig: () => saveDeploymentConfig,
  versionedBinaryDir: () => versionedBinaryDir
});
module.exports = __toCommonJS(filePaths_exports);
var import_path = __toESM(require("path"), 1);
var import_utils = require("../utils/utils.js");
var import_log = require("../../../bundler/log.js");
var import_fsUtils = require("../fsUtils.js");
var import_crypto = __toESM(require("crypto"), 1);
function ensureDotConvexGitignore(ctx, projectDir) {
  const baseDir = projectDir ?? process.cwd();
  const dotConvexDir = import_path.default.join(baseDir, ".convex");
  const gitignorePath = import_path.default.join(dotConvexDir, ".gitignore");
  if (ctx.fs.exists(dotConvexDir) && !ctx.fs.exists(gitignorePath)) {
    ctx.fs.writeUtf8File(gitignorePath, "/*\n");
    (0, import_log.logVerbose)(`Created .convex/.gitignore to ignore local/`);
  }
}
function rootDeploymentStateDir(kind) {
  return import_path.default.join(
    (0, import_utils.rootDirectory)(),
    kind === "local" ? "convex-backend-state" : "anonymous-convex-backend-state"
  );
}
function projectLocalStateDir(projectDir) {
  const baseDir = projectDir ?? process.cwd();
  return import_path.default.join(baseDir, ".convex", "local", "default");
}
function legacyDeploymentStateDir(deploymentKind, deploymentName) {
  return import_path.default.join(rootDeploymentStateDir(deploymentKind), deploymentName);
}
function deploymentStateDir(ctx, deploymentKind, deploymentName, projectDir) {
  const localDir = projectLocalStateDir(projectDir);
  const localConfigFile = import_path.default.join(localDir, "config.json");
  if (ctx.fs.exists(localConfigFile)) {
    (0, import_log.logVerbose)(
      `Using project-local state for deployment ${deploymentName}: ${localDir}`
    );
    return localDir;
  }
  const legacyDir = legacyDeploymentStateDir(deploymentKind, deploymentName);
  if (ctx.fs.exists(legacyDir) && ctx.fs.stat(legacyDir).isDirectory()) {
    (0, import_log.logVerbose)(
      `Using legacy home directory state for deployment ${deploymentName}: ${legacyDir}`
    );
    return legacyDir;
  }
  (0, import_log.logVerbose)(
    `Using project-local state for new deployment ${deploymentName}: ${localDir}`
  );
  return localDir;
}
function deploymentStateDirUnchecked(projectDir) {
  return projectLocalStateDir(projectDir);
}
function loadDeploymentConfigFromDir(ctx, dir) {
  const configFile = import_path.default.join(dir, "config.json");
  if (!ctx.fs.exists(configFile)) {
    return null;
  }
  const content = ctx.fs.readUtf8File(configFile);
  try {
    return JSON.parse(content);
  } catch (e) {
    (0, import_log.logVerbose)(
      `Failed to parse local deployment config at ${dir}: ${e}`
    );
    return null;
  }
}
function loadProjectLocalConfig(ctx, projectDir) {
  const localDir = projectLocalStateDir(projectDir);
  const config = loadDeploymentConfigFromDir(ctx, localDir);
  if (config !== null && config.deploymentName) {
    (0, import_log.logVerbose)(
      `Found project-local deployment config for ${config.deploymentName}`
    );
    return { deploymentName: config.deploymentName, config };
  }
  return null;
}
function loadDeploymentConfig(ctx, deploymentKind, deploymentName, projectDir) {
  const localDir = projectLocalStateDir(projectDir);
  const localConfig = loadDeploymentConfigFromDir(ctx, localDir);
  if (localConfig !== null) {
    if (!localConfig.deploymentName || localConfig.deploymentName === deploymentName) {
      (0, import_log.logVerbose)(
        `Found deployment config in project-local location for ${deploymentName}`
      );
      return localConfig;
    }
    (0, import_log.logVerbose)(
      `Project-local config is for ${localConfig.deploymentName}, not ${deploymentName}`
    );
  }
  const legacyDir = legacyDeploymentStateDir(deploymentKind, deploymentName);
  const legacyConfig = loadDeploymentConfigFromDir(ctx, legacyDir);
  if (legacyConfig !== null) {
    (0, import_log.logVerbose)(
      `Found deployment config in legacy location for ${deploymentName}`
    );
    return legacyConfig;
  }
  return null;
}
function saveDeploymentConfig(ctx, deploymentKind, deploymentName, config, projectDir) {
  const dir = deploymentStateDir(
    ctx,
    deploymentKind,
    deploymentName,
    projectDir
  );
  const configFile = import_path.default.join(dir, "config.json");
  if (!ctx.fs.exists(dir)) {
    ctx.fs.mkdir(dir, { recursive: true });
  }
  ensureDotConvexGitignore(ctx, projectDir);
  const configWithName = { ...config, deploymentName };
  ctx.fs.writeUtf8File(configFile, JSON.stringify(configWithName));
}
function binariesDir() {
  return import_path.default.join((0, import_utils.cacheDir)(), "binaries");
}
function dashboardZip() {
  return import_path.default.join(dashboardDir(), "dashboard.zip");
}
function versionedBinaryDir(version) {
  return import_path.default.join(binariesDir(), version);
}
function executablePath(version) {
  return import_path.default.join(versionedBinaryDir(version), executableName());
}
function executableName() {
  const ext = process.platform === "win32" ? ".exe" : "";
  return `convex-local-backend${ext}`;
}
function dashboardDir() {
  return import_path.default.join((0, import_utils.cacheDir)(), "dashboard");
}
async function resetDashboardDir(ctx) {
  const dir = dashboardDir();
  if (ctx.fs.exists(dir)) {
    await (0, import_fsUtils.recursivelyDelete)(ctx, dir);
  }
  ctx.fs.mkdir(dir, { recursive: true });
}
function dashboardOutDir() {
  return import_path.default.join(dashboardDir(), "out");
}
function loadDashboardConfig(ctx) {
  const configFile = import_path.default.join(dashboardDir(), "config.json");
  if (!ctx.fs.exists(configFile)) {
    return null;
  }
  const content = ctx.fs.readUtf8File(configFile);
  try {
    return JSON.parse(content);
  } catch (e) {
    (0, import_log.logVerbose)(`Failed to parse dashboard config: ${e}`);
    return null;
  }
}
function saveDashboardConfig(ctx, config) {
  const configFile = import_path.default.join(dashboardDir(), "config.json");
  if (!ctx.fs.exists(dashboardDir())) {
    ctx.fs.mkdir(dashboardDir(), { recursive: true });
  }
  ctx.fs.writeUtf8File(configFile, JSON.stringify(config));
}
function loadUuidForAnonymousUser(ctx) {
  const configFile = import_path.default.join(
    rootDeploymentStateDir("anonymous"),
    "config.json"
  );
  if (!ctx.fs.exists(configFile)) {
    return null;
  }
  const content = ctx.fs.readUtf8File(configFile);
  try {
    const config = JSON.parse(content);
    return config.uuid ?? null;
  } catch (e) {
    (0, import_log.logVerbose)(`Failed to parse uuid for anonymous user: ${e}`);
    return null;
  }
}
function ensureUuidForAnonymousUser(ctx) {
  const uuid = loadUuidForAnonymousUser(ctx);
  if (uuid) {
    return uuid;
  }
  const newUuid = import_crypto.default.randomUUID();
  const anonymousDir = rootDeploymentStateDir("anonymous");
  if (!ctx.fs.exists(anonymousDir)) {
    ctx.fs.mkdir(anonymousDir, { recursive: true });
  }
  ctx.fs.writeUtf8File(
    import_path.default.join(anonymousDir, "config.json"),
    JSON.stringify({ uuid: newUuid })
  );
  return newUuid;
}
//# sourceMappingURL=filePaths.js.map
