import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deploy, startBackend } from "./convex_cost/lib/backend.mjs";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function run(script, args, env = process.env) {
  console.log(`> node ${script} ${args.join(" ")}`.trimEnd());
  const result = spawnSync(process.execPath, [resolve(repositoryRoot, script), ...args], {
    cwd: repositoryRoot,
    env,
    stdio: "inherit",
  });
  return result.status === 0;
}

let passed = false;
const backend = await startBackend({ port: 3330 });
try {
  deploy({ url: backend.url, adminKey: backend.adminKey, projectDir: repositoryRoot });
  const env = {
    ...process.env,
    CONVEX_SELF_HOSTED_URL: backend.url,
    CONVEX_SELF_HOSTED_ADMIN_KEY: backend.adminKey,
  };
  delete env.CONVEX_DEPLOY_KEY;
  delete env.CONVEX_DEPLOYMENT;
  delete env.CONVEX_PREVIEW_NAME;
  passed = run("tool/snapshot_convex_contract.mjs", ["--check"], env);
} finally {
  await backend.stop();
}
passed =
  passed &&
  run("tool/audit_convex_contract.mjs", []) &&
  run("tool/check_convex_shipped_clients.mjs", []);
if (!passed) {
  console.error("The Convex contract check failed; this commit must not deploy.");
  process.exit(1);
}
