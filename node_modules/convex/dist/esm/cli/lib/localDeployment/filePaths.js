"use strict";
import path from "path";
import { cacheDir, rootDirectory } from "../utils/utils.js";
import { logVerbose } from "../../../bundler/log.js";
import { recursivelyDelete } from "../fsUtils.js";
import crypto from "crypto";
export function ensureDotConvexGitignore(ctx, projectDir) {
  const baseDir = projectDir ?? process.cwd();
  const dotConvexDir = path.join(baseDir, ".convex");
  const gitignorePath = path.join(dotConvexDir, ".gitignore");
  if (ctx.fs.exists(dotConvexDir) && !ctx.fs.exists(gitignorePath)) {
    ctx.fs.writeUtf8File(gitignorePath, "/*\n");
    logVerbose(`Created .convex/.gitignore to ignore local/`);
  }
}
export function rootDeploymentStateDir(kind) {
  return path.join(
    rootDirectory(),
    kind === "local" ? "convex-backend-state" : "anonymous-convex-backend-state"
  );
}
export function projectLocalStateDir(projectDir) {
  const baseDir = projectDir ?? process.cwd();
  return path.join(baseDir, ".convex", "local", "default");
}
export function legacyDeploymentStateDir(deploymentKind, deploymentName) {
  return path.join(rootDeploymentStateDir(deploymentKind), deploymentName);
}
export function deploymentStateDir(ctx, deploymentKind, deploymentName, projectDir) {
  const localDir = projectLocalStateDir(projectDir);
  const localConfigFile = path.join(localDir, "config.json");
  if (ctx.fs.exists(localConfigFile)) {
    logVerbose(
      `Using project-local state for deployment ${deploymentName}: ${localDir}`
    );
    return localDir;
  }
  const legacyDir = legacyDeploymentStateDir(deploymentKind, deploymentName);
  if (ctx.fs.exists(legacyDir) && ctx.fs.stat(legacyDir).isDirectory()) {
    logVerbose(
      `Using legacy home directory state for deployment ${deploymentName}: ${legacyDir}`
    );
    return legacyDir;
  }
  logVerbose(
    `Using project-local state for new deployment ${deploymentName}: ${localDir}`
  );
  return localDir;
}
export function deploymentStateDirUnchecked(projectDir) {
  return projectLocalStateDir(projectDir);
}
export function loadDeploymentConfigFromDir(ctx, dir) {
  const configFile = path.join(dir, "config.json");
  if (!ctx.fs.exists(configFile)) {
    return null;
  }
  const content = ctx.fs.readUtf8File(configFile);
  try {
    return JSON.parse(content);
  } catch (e) {
    logVerbose(
      `Failed to parse local deployment config at ${dir}: ${e}`
    );
    return null;
  }
}
export function loadProjectLocalConfig(ctx, projectDir) {
  const localDir = projectLocalStateDir(projectDir);
  const config = loadDeploymentConfigFromDir(ctx, localDir);
  if (config !== null && config.deploymentName) {
    logVerbose(
      `Found project-local deployment config for ${config.deploymentName}`
    );
    return { deploymentName: config.deploymentName, config };
  }
  return null;
}
export function loadDeploymentConfig(ctx, deploymentKind, deploymentName, projectDir) {
  const localDir = projectLocalStateDir(projectDir);
  const localConfig = loadDeploymentConfigFromDir(ctx, localDir);
  if (localConfig !== null) {
    if (!localConfig.deploymentName || localConfig.deploymentName === deploymentName) {
      logVerbose(
        `Found deployment config in project-local location for ${deploymentName}`
      );
      return localConfig;
    }
    logVerbose(
      `Project-local config is for ${localConfig.deploymentName}, not ${deploymentName}`
    );
  }
  const legacyDir = legacyDeploymentStateDir(deploymentKind, deploymentName);
  const legacyConfig = loadDeploymentConfigFromDir(ctx, legacyDir);
  if (legacyConfig !== null) {
    logVerbose(
      `Found deployment config in legacy location for ${deploymentName}`
    );
    return legacyConfig;
  }
  return null;
}
export function saveDeploymentConfig(ctx, deploymentKind, deploymentName, config, projectDir) {
  const dir = deploymentStateDir(
    ctx,
    deploymentKind,
    deploymentName,
    projectDir
  );
  const configFile = path.join(dir, "config.json");
  if (!ctx.fs.exists(dir)) {
    ctx.fs.mkdir(dir, { recursive: true });
  }
  ensureDotConvexGitignore(ctx, projectDir);
  const configWithName = { ...config, deploymentName };
  ctx.fs.writeUtf8File(configFile, JSON.stringify(configWithName));
}
export function binariesDir() {
  return path.join(cacheDir(), "binaries");
}
export function dashboardZip() {
  return path.join(dashboardDir(), "dashboard.zip");
}
export function versionedBinaryDir(version) {
  return path.join(binariesDir(), version);
}
export function executablePath(version) {
  return path.join(versionedBinaryDir(version), executableName());
}
export function executableName() {
  const ext = process.platform === "win32" ? ".exe" : "";
  return `convex-local-backend${ext}`;
}
export function dashboardDir() {
  return path.join(cacheDir(), "dashboard");
}
export async function resetDashboardDir(ctx) {
  const dir = dashboardDir();
  if (ctx.fs.exists(dir)) {
    await recursivelyDelete(ctx, dir);
  }
  ctx.fs.mkdir(dir, { recursive: true });
}
export function dashboardOutDir() {
  return path.join(dashboardDir(), "out");
}
export function loadDashboardConfig(ctx) {
  const configFile = path.join(dashboardDir(), "config.json");
  if (!ctx.fs.exists(configFile)) {
    return null;
  }
  const content = ctx.fs.readUtf8File(configFile);
  try {
    return JSON.parse(content);
  } catch (e) {
    logVerbose(`Failed to parse dashboard config: ${e}`);
    return null;
  }
}
export function saveDashboardConfig(ctx, config) {
  const configFile = path.join(dashboardDir(), "config.json");
  if (!ctx.fs.exists(dashboardDir())) {
    ctx.fs.mkdir(dashboardDir(), { recursive: true });
  }
  ctx.fs.writeUtf8File(configFile, JSON.stringify(config));
}
export function loadUuidForAnonymousUser(ctx) {
  const configFile = path.join(
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
    logVerbose(`Failed to parse uuid for anonymous user: ${e}`);
    return null;
  }
}
export function ensureUuidForAnonymousUser(ctx) {
  const uuid = loadUuidForAnonymousUser(ctx);
  if (uuid) {
    return uuid;
  }
  const newUuid = crypto.randomUUID();
  const anonymousDir = rootDeploymentStateDir("anonymous");
  if (!ctx.fs.exists(anonymousDir)) {
    ctx.fs.mkdir(anonymousDir, { recursive: true });
  }
  ctx.fs.writeUtf8File(
    path.join(anonymousDir, "config.json"),
    JSON.stringify({ uuid: newUuid })
  );
  return newUuid;
}
//# sourceMappingURL=filePaths.js.map
