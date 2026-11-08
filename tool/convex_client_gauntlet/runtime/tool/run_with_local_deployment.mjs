#!/usr/bin/env node
// Runs the gauntlet against a throwaway local Convex deployment, with no
// Supabase project and no stored credentials.
//
// The deployment is made from a copy of convex/ in a temporary directory. The
// copy's auth.config.ts trusts one issuer whose key is generated here and
// lives only in this process, so it accepts the two access tokens minted
// below and nothing else. The repository's convex/auth.config.ts, which
// production deploys, is never read or changed.
//
// When the runner stops at its mid-run checkpoint, the test runs again in a
// new process: that is the process-restart fault.
//
// Usage, from the repository root after `npm ci`, a release cargo build of
// third_party/convex_flutter/rust, and `flutter pub get` in the runtime
// package:
//
//   node tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs
//
// Settings (environment):
//   GAUNTLET_SEEDS        seeds to run (default 3: seed 0 refreshes auth,
//                         seed 1 restarts the process)
//   GAUNTLET_PORT         local backend port (default 3410; the site proxy
//                         uses the next one)
//   GAUNTLET_ADAPTER      convex_flutter (default) or dartvex
//   GAUNTLET_REPORT       where to copy the final report (optional)
//   FLUTTER               the flutter command (default "flutter"; CI uses
//                         "fvm flutter")
//   FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR
//                         directory holding the native bridge (default the
//                         convex_flutter cargo release directory)

import { spawn, spawnSync } from "node:child_process";
import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const runtimeDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoDir = path.resolve(runtimeDir, "../../..");
const seeds = Number(process.env.GAUNTLET_SEEDS ?? 3);
const port = Number(process.env.GAUNTLET_PORT ?? 3410);
const adapter = process.env.GAUNTLET_ADAPTER ?? "convex_flutter";
const flutter = (process.env.FLUTTER ?? "flutter").split(" ").filter(Boolean);
const nativeLibDir =
  process.env.FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR ??
  path.join(repoDir, "third_party/convex_flutter/rust/target/release");
const issuer = "https://gauntlet.icarus.invalid";
const deploymentUrl = `http://127.0.0.1:${port}`;

const workDir = fs.mkdtempSync(
  path.join(process.env.RUNNER_TEMP ?? os.tmpdir(), "icarus-gauntlet-"),
);
const reportPath = path.join(workDir, "report.json");
let backend = null;
// The deployment's own output and function logs, last part only, printed
// when the gauntlet fails.
let backendLog = "";

try {
  const { privateKey, jwks } = makeIssuerKey();
  makeProject(jwks);
  backend = await startDeployment();
  const tokens = [mintToken(privateKey), mintToken(privateKey)];
  const report = runGauntlet(tokens);
  if (process.env.GAUNTLET_REPORT) {
    fs.copyFileSync(reportPath, process.env.GAUNTLET_REPORT);
  }
  printSummary(report);
} catch (error) {
  console.error("--- local deployment log (last part) ---");
  console.error(backendLog);
  console.error("---");
  if (process.env.GAUNTLET_REPORT && fs.existsSync(reportPath)) {
    fs.copyFileSync(reportPath, process.env.GAUNTLET_REPORT);
  }
  throw error;
} finally {
  if (backend !== null) await stopDeployment(backend);
  fs.rmSync(workDir, { recursive: true, force: true });
}

function makeIssuerKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = { ...publicKey.export({ format: "jwk" }), kid: "gauntlet", alg: "ES256", use: "sig" };
  return { privateKey, jwks: JSON.stringify({ keys: [jwk] }) };
}

function makeProject(jwks) {
  const projectConvex = path.join(workDir, "convex");
  fs.cpSync(path.join(repoDir, "convex"), projectConvex, { recursive: true });
  fs.copyFileSync(path.join(repoDir, "package.json"), path.join(workDir, "package.json"));
  // What convex/ imports from outside itself: its packages, and the presence
  // pass it signs and verifies.
  for (const name of ["node_modules", "presence"]) {
    fs.symlinkSync(path.join(repoDir, name), path.join(workDir, name), "junction");
  }
  const jwksUri = `data:text/plain;charset=utf-8;base64,${Buffer.from(jwks).toString("base64")}`;
  fs.writeFileSync(
    path.join(projectConvex, "auth.config.ts"),
    [
      "// Written by run_with_local_deployment.mjs for one throwaway local deployment.",
      "export default {",
      "  providers: [",
      "    {",
      '      type: "customJwt",',
      '      applicationID: "authenticated",',
      `      issuer: ${JSON.stringify(issuer)},`,
      `      jwks: ${JSON.stringify(jwksUri)},`,
      '      algorithm: "ES256",',
      "    },",
      "  ],",
      "};",
      "",
    ].join("\n"),
  );
}

// One account, the same claims a Supabase access token carries. Each token is
// distinct, so the runner sees its refresh return a new one.
function mintToken(privateKey) {
  const now = Math.floor(Date.now() / 1000);
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const header = encode({ alg: "ES256", typ: "JWT", kid: "gauntlet" });
  const payload = encode({
    iss: issuer,
    sub: "gauntlet-user",
    aud: "authenticated",
    role: "authenticated",
    email: "gauntlet@icarus.invalid",
    iat: now,
    exp: now + 2 * 60 * 60,
    jti: randomUUID(),
  });
  const signature = sign("sha256", Buffer.from(`${header}.${payload}`), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  }).toString("base64url");
  return `${header}.${payload}.${signature}`;
}

// Never let the copy reach a cloud deployment: anonymous mode, and no
// deployment variables from the caller's environment.
function deploymentEnv() {
  const env = { ...process.env, CONVEX_AGENT_MODE: "anonymous" };
  for (const name of Object.keys(env)) {
    if (/^CONVEX_(DEPLOYMENT|DEPLOY_KEY|SELF_HOSTED_|URL$)/.test(name)) delete env[name];
  }
  return env;
}

async function startDeployment() {
  const child = spawn(
    process.execPath,
    [
      path.join(repoDir, "node_modules/convex/bin/main.js"),
      "dev",
      "--typecheck",
      "disable",
      "--codegen",
      "disable",
      "--tail-logs",
      "always",
      "--local-cloud-port",
      String(port),
      "--local-site-port",
      String(port + 1),
    ],
    {
      cwd: workDir,
      env: deploymentEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      detached: process.platform !== "win32",
    },
  );
  // Keeps draining both pipes for the whole run: a full pipe would stall
  // the deployment.
  const onData = (chunk) => {
    backendLog = (backendLog + chunk).slice(-40_000);
  };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("convex dev was not ready after 180 s")), 180_000);
    const poll = setInterval(() => {
      if (backendLog.includes("Convex functions ready!")) {
        clearInterval(poll);
        clearTimeout(timer);
        resolve();
      } else if (backendLog.includes("✘")) {
        // convex dev marks a failed push with this cross and waits for edits.
        clearInterval(poll);
        clearTimeout(timer);
        reject(new Error("convex dev could not push the functions"));
      }
    }, 200);
    child.on("exit", (code) => {
      clearInterval(poll);
      clearTimeout(timer);
      reject(new Error(`convex dev exited with ${code}`));
    });
  });
  child.removeAllListeners("exit");
  console.log(`Local deployment ready at ${deploymentUrl}`);
  return child;
}

async function stopDeployment(child) {
  const exited = new Promise((resolve) => child.once("exit", resolve));
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(child.pid), "/t", "/f"], { stdio: "ignore" });
  } else {
    // convex dev stops its backend on SIGINT; the group catches a straggler.
    try {
      process.kill(-child.pid, "SIGINT");
    } catch {}
  }
  await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 10_000))]);
  if (process.platform !== "win32") {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {}
  }
}

function runGauntlet([accessToken, refreshedAccessToken]) {
  const gitCommit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: repoDir, encoding: "utf8" }).stdout?.trim() ?? "";
  for (let run = 0; run < 2; run += 1) {
    fs.rmSync(reportPath, { force: true });
    const started = Date.now();
    const result = spawnSync(
      flutter[0],
      [...flutter.slice(1), "test", "test/live_deployment_test.dart", "--reporter", "expanded"],
      {
        cwd: runtimeDir,
        stdio: "inherit",
        shell: process.platform === "win32",
        env: {
          ...process.env,
          CONVEX_URL: deploymentUrl,
          ADAPTER: adapter,
          SEED_COUNT: String(seeds),
          ALLOW_CHECKPOINT: "1",
          RESET_PROGRESS: run === 0 ? "1" : "0",
          GAUNTLET_ACCESS_TOKEN: accessToken,
          GAUNTLET_REFRESHED_ACCESS_TOKEN: refreshedAccessToken,
          REPORT_PATH: reportPath,
          GIT_COMMIT: gitCommit,
          FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR: nativeLibDir,
        },
      },
    );
    console.log(`Gauntlet process ${run + 1} took ${((Date.now() - started) / 1000).toFixed(1)} s`);
    const report = fs.existsSync(reportPath) ? JSON.parse(fs.readFileSync(reportPath, "utf8")) : null;
    if (result.status !== 0 || report === null) {
      throw new Error(`The gauntlet failed (exit ${result.status})${report ? `: ${report.losingCondition}: ${report.message}` : ""}`);
    }
    if (report.status === "passed") return report;
    if (report.status !== "checkpoint") throw new Error(`Unexpected gauntlet status ${report.status}`);
    console.log(`Checkpoint at seed ${report.seed}, operation ${report.nextOperation}; restarting the process`);
  }
  throw new Error("The gauntlet did not pass after its process restart");
}

function printSummary(report) {
  const restarts = report.seeds.filter((seed) => seed.faults.processRestart).length;
  console.log(
    `Gauntlet passed: ${report.adapter}, ${report.seedCount} seeds, ${report.totalOperations} ops, ` +
      `${restarts} process restart(s), ${(report.wallClockMs / 1000).toFixed(1)} s of runner time`,
  );
  for (const seed of report.seeds) {
    const faults = Object.entries(seed.faults)
      .filter(([, hit]) => hit)
      .map(([name]) => name)
      .join(", ");
    console.log(
      `  seed ${seed.seed}: ${seed.acknowledged} landed, ${seed.rejected} rejected, ` +
        `state ${seed.canonicalVerifierHash.slice(0, 12)}, .ica ${seed.roundTripHash.slice(0, 12)}; ${faults}`,
    );
  }
}
