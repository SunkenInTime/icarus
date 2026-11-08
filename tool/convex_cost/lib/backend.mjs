// A private Convex backend for one cost run: the open-source local backend
// binary, on a fresh database, with this checkout's convex/ deployed to it.
//
// The local backend is the same backend the cloud runs. It reports the same
// per-call usage (usageStats) in its function log stream, and re-runs live
// queries the way the cloud does, which convex-test (vitest) can't show.

import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";

/// The backend release the budgets were measured on. A newer backend may
/// count reads differently: move this only together with budgets.json.
export const BACKEND_RELEASE = "precompiled-2026-10-22-1447815";

function assetName() {
  const { platform, arch } = process;
  if (platform === "win32") return "convex-local-backend-x86_64-pc-windows-msvc.zip";
  if (platform === "darwin") {
    return arch === "arm64"
      ? "convex-local-backend-aarch64-apple-darwin.zip"
      : "convex-local-backend-x86_64-apple-darwin.zip";
  }
  return arch === "arm64"
    ? "convex-local-backend-aarch64-unknown-linux-gnu.zip"
    : "convex-local-backend-x86_64-unknown-linux-gnu.zip";
}

/// Where the Convex CLI keeps backend binaries, so a machine that ran
/// `npx convex dev --local` already has this one.
function binariesDir() {
  if (process.platform === "win32") {
    const base = process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
    return join(base, "convex", "binaries");
  }
  return join(homedir(), ".cache", "convex", "binaries");
}

/// The backend binary: CONVEX_LOCAL_BACKEND_BINARY when set, else
/// [BACKEND_RELEASE] from the CLI's cache, downloaded there when missing.
export async function backendBinary() {
  const override = process.env.CONVEX_LOCAL_BACKEND_BINARY;
  if (override) return override;
  const dir = join(binariesDir(), BACKEND_RELEASE);
  const binary = join(dir, process.platform === "win32" ? "convex-local-backend.exe" : "convex-local-backend");
  if (existsSync(binary)) return binary;
  mkdirSync(dir, { recursive: true });
  const url = `https://github.com/get-convex/convex-backend/releases/download/${BACKEND_RELEASE}/${assetName()}`;
  console.log(`Downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Download failed: ${response.status} ${url}`);
  const zip = join(dir, "backend.zip");
  await pipeline(Readable.fromWeb(response.body), createWriteStream(zip));
  // bsdtar (Windows, macOS) reads zips; Linux runners have unzip.
  const unpack =
    process.platform === "linux"
      ? spawnSync("unzip", ["-o", zip, "-d", dir], { stdio: "inherit" })
      : spawnSync("tar", ["-xf", zip, "-C", dir], { stdio: "inherit" });
  if (unpack.status !== 0) throw new Error("Could not unpack the backend");
  rmSync(zip);
  if (process.platform !== "win32") spawnSync("chmod", ["+x", binary]);
  return binary;
}

/// Starts a backend on [port] with an empty database. Returns its url, an
/// admin key and stop().
export async function startBackend({ port, keep = false }) {
  const binary = await backendBinary();
  const dir = mkdtempSync(join(tmpdir(), "icarus-convex-cost-"));
  const instanceName = "icarus-cost";
  const instanceSecret = randomBytes(32).toString("hex");
  const keygen = spawnSync(binary, [
    "keygen",
    "admin-key",
    "--instance-name",
    instanceName,
    "--instance-secret",
    instanceSecret,
  ]);
  if (keygen.status !== 0) throw new Error(`keygen failed: ${keygen.stderr}`);
  const adminKey = keygen.stdout.toString().trim();
  const child = spawn(
    binary,
    [
      "--port",
      String(port),
      "--site-proxy-port",
      String(port + 1),
      "--interface",
      "127.0.0.1",
      "--instance-name",
      instanceName,
      "--instance-secret",
      instanceSecret,
      "--local-storage",
      join(dir, "storage"),
      "--disable-beacon",
      join(dir, "db.sqlite3"),
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr = (stderr + chunk).slice(-4000);
  });
  const url = `http://127.0.0.1:${port}`;
  const started = Date.now();
  while (true) {
    if (child.exitCode !== null) throw new Error(`Backend exited:\n${stderr}`);
    try {
      const response = await fetch(`${url}/version`);
      if (response.ok) break;
    } catch {
      // Not listening yet.
    }
    if (Date.now() - started > 60_000) {
      child.kill();
      await new Promise((resolve) => (child.exitCode !== null ? resolve() : child.once("exit", resolve)));
      rmSync(dir, { recursive: true, force: true });
      throw new Error(`Backend did not start:\n${stderr}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return {
    url,
    adminKey,
    async stop() {
      child.kill();
      await new Promise((resolve) => (child.exitCode !== null ? resolve() : child.once("exit", resolve)));
      if (!keep) rmSync(dir, { recursive: true, force: true });
    },
  };
}

/// Pushes the functions and schema in [projectDir]/convex to the backend.
/// Codegen is off, so convex/_generated is left as committed.
export function deploy({ url, adminKey, projectDir }) {
  const env = { ...process.env, CONVEX_SELF_HOSTED_URL: url, CONVEX_SELF_HOSTED_ADMIN_KEY: adminKey };
  // A deploy key or a selected deployment would win over the self-hosted
  // backend; CI's convex lane has one in its environment.
  delete env.CONVEX_DEPLOY_KEY;
  delete env.CONVEX_DEPLOYMENT;
  const cli = join(projectDir, "node_modules", "convex", "bin", "main.js");
  const result = spawnSync(
    process.execPath,
    [cli, "deploy", "--typecheck", "disable", "--codegen", "disable", "--yes"],
    { cwd: projectDir, env, encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error(`convex deploy failed:\n${result.stdout}\n${result.stderr}`);
  }
}
