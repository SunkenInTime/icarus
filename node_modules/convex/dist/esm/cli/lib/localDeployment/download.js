"use strict";
import { version as npmVersion } from "../../version.js";
import AdmZip from "adm-zip";
import {
  logFinishedStep,
  startLogProgress,
  logVerbose,
  logMessage,
  logError,
  logWarning
} from "../../../bundler/log.js";
import {
  dashboardZip,
  executablePath,
  versionedBinaryDir,
  dashboardOutDir,
  resetDashboardDir,
  loadDashboardConfig,
  executableName
} from "./filePaths.js";
import child_process from "child_process";
import { promisify } from "util";
import { Readable } from "stream";
import { nodeFs, withTmpDir } from "../../../bundler/fs.js";
import { recursivelyDelete, recursivelyCopy } from "../fsUtils.js";
import { LocalDeploymentError } from "./errors.js";
import path from "path";
async function makeExecutable(p) {
  switch (process.platform) {
    case "darwin":
    case "linux": {
      await promisify(child_process.exec)(`chmod +x ${p}`);
    }
  }
}
export async function ensureBackendBinaryDownloaded(ctx, version) {
  if (version.kind === "version") {
    return _ensureBackendBinaryDownloaded(ctx, version.version);
  }
  if (version.allowedVersion) {
    const latestVersionWithBinary2 = await findLatestVersionWithBinary(
      ctx,
      false
    );
    if (latestVersionWithBinary2 === null) {
      logWarning(
        `Failed to get latest version from GitHub, using downloaded version ${version.allowedVersion}`
      );
      return _ensureBackendBinaryDownloaded(ctx, version.allowedVersion);
    }
    return _ensureBackendBinaryDownloaded(ctx, latestVersionWithBinary2);
  }
  const latestVersionWithBinary = await findLatestVersionWithBinary(ctx, true);
  return _ensureBackendBinaryDownloaded(ctx, latestVersionWithBinary);
}
async function _ensureBackendBinaryDownloaded(ctx, version) {
  logVerbose(`Ensuring backend binary downloaded for version ${version}`);
  const existingDownload = await checkForExistingDownload(ctx, version);
  if (existingDownload !== null) {
    logVerbose(`Using existing download at ${existingDownload}`);
    return {
      binaryPath: existingDownload,
      version
    };
  }
  const binaryPath = await downloadBackendBinary(ctx, version);
  return { version, binaryPath };
}
export async function findLatestVersionWithBinary(ctx, requireSuccess) {
  async function maybeCrash(...args) {
    if (requireSuccess) {
      return await ctx.crash(...args);
    }
    if (args[0].printedMessage) {
      logError(args[0].printedMessage);
    } else {
      logError("Error fetching latest version");
    }
    return null;
  }
  logVerbose("Fetching latest backend version from version API");
  try {
    const response = await fetch(
      "https://version.convex.dev/v1/local_backend_version",
      {
        headers: { "Convex-Client": `npm-cli-${npmVersion}` }
      }
    );
    if (!response.ok) {
      const text = await response.text();
      return await maybeCrash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: `version.convex.dev returned ${response.status}: ${text}`,
        errForSentry: new LocalDeploymentError(
          `version.convex.dev returned ${response.status}: ${text}`
        )
      });
    }
    const data = await response.json();
    if (!data.version) {
      return await maybeCrash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "Invalid response missing version field",
        errForSentry: new LocalDeploymentError(
          "Invalid response missing version field"
        )
      });
    }
    logVerbose(`Latest backend version is ${data.version}`);
    return data.version;
  } catch (e) {
    return maybeCrash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: "Failed to fetch latest backend version",
      errForSentry: new LocalDeploymentError(e?.toString())
    });
  }
}
async function checkForExistingDownload(ctx, version) {
  const destDir = versionedBinaryDir(version);
  if (!ctx.fs.exists(destDir)) {
    return null;
  }
  const p = executablePath(version);
  if (!ctx.fs.exists(p)) {
    recursivelyDelete(ctx, destDir, { force: true });
    return null;
  }
  await makeExecutable(p);
  return p;
}
async function downloadBackendBinary(ctx, version) {
  const downloadPath = getDownloadPath();
  if (downloadPath === null) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Unsupported platform ${process.platform} and architecture ${process.arch} for local deployment.`
    });
  }
  await downloadZipFile(ctx, {
    version,
    filename: downloadPath,
    nameForLogging: "Convex backend binary",
    onDownloadComplete: async (ctx2, unzippedPath) => {
      const name = executableName();
      const tempExecPath = path.join(unzippedPath, name);
      await makeExecutable(tempExecPath);
      logVerbose("Marked as executable");
      ctx2.fs.mkdir(versionedBinaryDir(version), { recursive: true });
      ctx2.fs.swapTmpFile(tempExecPath, executablePath(version));
    }
  });
  return executablePath(version);
}
function getDownloadPath() {
  switch (process.platform) {
    case "darwin":
      if (process.arch === "arm64") {
        return "convex-local-backend-aarch64-apple-darwin.zip";
      } else if (process.arch === "x64") {
        return "convex-local-backend-x86_64-apple-darwin.zip";
      }
      break;
    case "linux":
      if (process.arch === "arm64") {
        return "convex-local-backend-aarch64-unknown-linux-gnu.zip";
      } else if (process.arch === "x64") {
        return "convex-local-backend-x86_64-unknown-linux-gnu.zip";
      }
      break;
    case "win32":
      return "convex-local-backend-x86_64-pc-windows-msvc.zip";
  }
  return null;
}
function getGithubDownloadUrl(version, filename) {
  return `https://github.com/get-convex/convex-backend/releases/download/${version}/${filename}`;
}
async function downloadZipFile(ctx, args) {
  const { version, filename, nameForLogging } = args;
  const url = getGithubDownloadUrl(version, filename);
  const response = await fetch(url);
  const contentLength = parseInt(
    response.headers.get("content-length") ?? "",
    10
  );
  let progressBar = null;
  if (!isNaN(contentLength) && contentLength !== 0 && process.stdout.isTTY) {
    progressBar = startLogProgress(
      `Downloading ${nameForLogging} [:bar] :percent :etas`,
      {
        width: 40,
        total: contentLength,
        clear: true
      }
    );
  } else {
    logMessage(`Downloading ${nameForLogging}`);
  }
  if (response.status !== 200) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `File not found at ${url}.`
    });
  }
  await withTmpDir(async (tmpDir) => {
    logVerbose(`Created tmp dir ${tmpDir.path}`);
    const zipLocation = tmpDir.registerTempPath(null);
    const readable = Readable.fromWeb(response.body);
    await tmpDir.writeFileStream(zipLocation, readable, (chunk) => {
      if (progressBar !== null) {
        progressBar.tick(chunk.length);
      }
    });
    if (progressBar) {
      progressBar.terminate();
      logFinishedStep(`Downloaded ${nameForLogging}`);
    }
    logVerbose("Downloaded zip file");
    const zip = new AdmZip(zipLocation);
    await withTmpDir(async (versionDir) => {
      logVerbose(`Created tmp dir ${versionDir.path}`);
      zip.extractAllTo(versionDir.path, true);
      logVerbose("Extracted from zip file");
      await args.onDownloadComplete(ctx, versionDir.path);
    });
  });
  return executablePath(version);
}
export async function ensureDashboardDownloaded(ctx, version) {
  const config = loadDashboardConfig(ctx);
  if (config !== null && config.version === version) {
    return;
  }
  await resetDashboardDir(ctx);
  await _ensureDashboardDownloaded(ctx, version);
}
async function _ensureDashboardDownloaded(ctx, version) {
  const zipLocation = dashboardZip();
  if (ctx.fs.exists(zipLocation)) {
    ctx.fs.unlink(zipLocation);
  }
  const outDir = dashboardOutDir();
  await downloadZipFile(ctx, {
    version,
    filename: "dashboard.zip",
    nameForLogging: "Convex dashboard",
    onDownloadComplete: async (ctx2, unzippedPath) => {
      await recursivelyCopy(ctx2, nodeFs, unzippedPath, outDir);
      logVerbose("Copied into out dir");
    }
  });
  return outDir;
}
//# sourceMappingURL=download.js.map
