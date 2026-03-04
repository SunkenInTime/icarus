"use strict";
import { chalkStderr } from "chalk";
import * as dotenv from "dotenv";
import { logWarning } from "../../bundler/log.js";
import { loadPackageJson } from "./utils/utils.js";
const _FRAMEWORKS = [
  "create-react-app",
  "Next.js",
  "Vite",
  "Remix",
  "SvelteKit",
  "Expo",
  "TanStackStart"
];
export async function writeUrlsToEnvFile(ctx, options) {
  const envFileConfig = await loadEnvFileUrlConfig(ctx, options);
  if (envFileConfig === null) {
    return null;
  }
  const { envFile, convexUrlEnvVar, siteUrlEnvVar, existingFileContent } = envFileConfig;
  let updatedFileContent = null;
  if (convexUrlEnvVar) {
    updatedFileContent = changedEnvVarFile({
      existingFileContent,
      envVarName: convexUrlEnvVar,
      envVarValue: options.convexUrl,
      commentAfterValue: null,
      commentOnPreviousLine: null
    });
  }
  if (siteUrlEnvVar && options.siteUrl) {
    updatedFileContent = changedEnvVarFile({
      existingFileContent: updatedFileContent ?? existingFileContent,
      envVarName: siteUrlEnvVar,
      envVarValue: options.siteUrl,
      commentAfterValue: null,
      commentOnPreviousLine: null
    });
  }
  if (updatedFileContent) {
    ctx.fs.writeUtf8File(envFile, updatedFileContent);
  }
  return envFileConfig;
}
export function changedEnvVarFile({
  existingFileContent,
  envVarName,
  envVarValue,
  commentAfterValue,
  commentOnPreviousLine
}) {
  const varAssignment = `${envVarName}=${envVarValue}${commentAfterValue === null ? "" : ` # ${commentAfterValue}`}`;
  const commentOnPreviousLineWithLineBreak = commentOnPreviousLine === null ? "" : `${commentOnPreviousLine}
`;
  if (existingFileContent === null) {
    return `${commentOnPreviousLineWithLineBreak}${varAssignment}
`;
  }
  const config = dotenv.parse(existingFileContent);
  const existing = config[envVarName];
  if (existing === envVarValue) {
    return null;
  }
  if (existing !== void 0) {
    return existingFileContent.replace(
      getEnvVarRegex(envVarName),
      `${varAssignment}`
    );
  } else {
    const doubleLineBreak = existingFileContent.endsWith("\n") ? "\n" : "\n\n";
    return existingFileContent + doubleLineBreak + commentOnPreviousLineWithLineBreak + varAssignment + "\n";
  }
}
export function getEnvVarRegex(envVarName) {
  return new RegExp(`^${envVarName}.*$`, "m");
}
export async function suggestedEnvVarNames(ctx) {
  if (!ctx.fs.exists("package.json")) {
    return {
      convexUrlEnvVar: "CONVEX_URL",
      convexSiteEnvVar: "CONVEX_SITE_URL"
    };
  }
  const packages = await loadPackageJson(ctx);
  const isCreateReactApp = "react-scripts" in packages;
  if (isCreateReactApp) {
    return {
      detectedFramework: "create-react-app",
      convexUrlEnvVar: "REACT_APP_CONVEX_URL",
      convexSiteEnvVar: "REACT_APP_CONVEX_SITE_URL",
      frontendDevUrl: "http://localhost:3000",
      publicPrefix: "REACT_APP_"
    };
  }
  const isNextJs = "next" in packages;
  if (isNextJs) {
    return {
      detectedFramework: "Next.js",
      convexUrlEnvVar: "NEXT_PUBLIC_CONVEX_URL",
      convexSiteEnvVar: "NEXT_PUBLIC_CONVEX_SITE_URL",
      frontendDevUrl: "http://localhost:3000",
      publicPrefix: "NEXT_PUBLIC_"
    };
  }
  const isExpo = "expo" in packages;
  if (isExpo) {
    return {
      detectedFramework: "Expo",
      convexUrlEnvVar: "EXPO_PUBLIC_CONVEX_URL",
      convexSiteEnvVar: "EXPO_PUBLIC_CONVEX_SITE_URL",
      publicPrefix: "EXPO_PUBLIC_"
    };
  }
  const isSvelteKit = "@sveltejs/kit" in packages;
  if (isSvelteKit) {
    return {
      detectedFramework: "SvelteKit",
      convexUrlEnvVar: "PUBLIC_CONVEX_URL",
      convexSiteEnvVar: "PUBLIC_CONVEX_SITE_URL",
      frontendDevUrl: "http://localhost:5173",
      publicPrefix: "PUBLIC_"
    };
  }
  const isTanStackStart = "@tanstack/start" in packages || "@tanstack/react-start" in packages;
  if (isTanStackStart) {
    return {
      detectedFramework: "TanStackStart",
      convexUrlEnvVar: "VITE_CONVEX_URL",
      convexSiteEnvVar: "VITE_CONVEX_SITE_URL",
      frontendDevUrl: "http://localhost:3000",
      publicPrefix: "VITE_"
    };
  }
  const isVite = "vite" in packages;
  if (isVite) {
    return {
      detectedFramework: "Vite",
      convexUrlEnvVar: "VITE_CONVEX_URL",
      convexSiteEnvVar: "VITE_CONVEX_SITE_URL",
      frontendDevUrl: "http://localhost:5173",
      publicPrefix: "VITE_"
    };
  }
  const isRemix = "@remix-run/dev" in packages;
  if (isRemix) {
    return {
      detectedFramework: "Remix",
      convexUrlEnvVar: "CONVEX_URL",
      convexSiteEnvVar: "CONVEX_SITE_URL",
      frontendDevUrl: "http://localhost:3000"
    };
  }
  return {
    convexUrlEnvVar: "CONVEX_URL",
    convexSiteEnvVar: "CONVEX_SITE_URL"
  };
}
async function loadEnvFileUrlConfig(ctx, options) {
  const { detectedFramework, convexUrlEnvVar, convexSiteEnvVar } = await suggestedEnvVarNames(ctx);
  const { envFile, existing } = suggestedDevEnvFile(ctx, detectedFramework);
  if (!existing) {
    return {
      envFile,
      convexUrlEnvVar,
      siteUrlEnvVar: convexSiteEnvVar,
      existingFileContent: null
    };
  }
  const existingFileContent = ctx.fs.readUtf8File(envFile);
  const config = dotenv.parse(existingFileContent);
  const resolvedConvexUrlEnvVar = resolveEnvVarName(
    convexUrlEnvVar,
    options.convexUrl,
    envFile,
    config,
    EXPECTED_CONVEX_URL_NAMES
  );
  const resolvedSiteUrlEnvVar = resolveEnvVarName(
    convexSiteEnvVar,
    options.siteUrl ?? "",
    envFile,
    config,
    EXPECTED_SITE_URL_NAMES
  );
  if (resolvedConvexUrlEnvVar.kind === "invalid" || resolvedSiteUrlEnvVar.kind === "invalid") {
    return null;
  }
  return {
    envFile,
    convexUrlEnvVar: resolvedConvexUrlEnvVar.envVarName,
    siteUrlEnvVar: resolvedSiteUrlEnvVar.envVarName,
    existingFileContent
  };
}
function resolveEnvVarName(envVarName, envVarValue, envFile, config, expectedNames) {
  const matching = Object.keys(config).filter((key) => expectedNames.has(key));
  if (matching.length > 1) {
    logWarning(
      chalkStderr.yellow(
        `Found multiple ${envVarName} environment variables in ${envFile} so cannot update automatically.`
      )
    );
    return { kind: "invalid" };
  }
  if (matching.length === 1) {
    const [existingEnvVarName, oldValue] = [matching[0], config[matching[0]]];
    if (oldValue === envVarValue) {
      return { kind: "valid", envVarName: null };
    }
    if (oldValue !== "" && Object.values(config).filter((v) => v === oldValue).length !== 1) {
      logWarning(
        chalkStderr.yellow(
          `Can't safely modify ${envFile} for ${envVarName}, please edit manually.`
        )
      );
      return { kind: "invalid" };
    }
    return { kind: "valid", envVarName: existingEnvVarName };
  }
  return { kind: "valid", envVarName };
}
function suggestedDevEnvFile(ctx, framework) {
  if (ctx.fs.exists(".env.local")) {
    return {
      existing: true,
      envFile: ".env.local"
    };
  }
  if (framework === "Remix") {
    return {
      existing: ctx.fs.exists(".env"),
      envFile: ".env"
    };
  }
  return {
    existing: ctx.fs.exists(".env.local"),
    envFile: ".env.local"
  };
}
const EXPECTED_CONVEX_URL_NAMES = /* @__PURE__ */ new Set([
  "CONVEX_URL",
  "PUBLIC_CONVEX_URL",
  "NEXT_PUBLIC_CONVEX_URL",
  "VITE_CONVEX_URL",
  "REACT_APP_CONVEX_URL",
  "EXPO_PUBLIC_CONVEX_URL"
]);
const EXPECTED_SITE_URL_NAMES = /* @__PURE__ */ new Set([
  "CONVEX_SITE_URL",
  "PUBLIC_CONVEX_SITE_URL",
  "NEXT_PUBLIC_CONVEX_SITE_URL",
  "VITE_CONVEX_SITE_URL",
  "REACT_APP_CONVEX_SITE_URL",
  "EXPO_PUBLIC_CONVEX_SITE_URL"
]);
export async function detectSuspiciousEnvironmentVariables(ctx, ignoreSuspiciousEnvVars = false) {
  for (const [key, value] of Object.entries(process.env)) {
    if (value === "" && key.startsWith("ey")) {
      try {
        const decoded = JSON.parse(
          Buffer.from(key + "=", "base64").toString("utf8")
        );
        if (!("v2" in decoded)) {
          continue;
        }
      } catch {
        continue;
      }
      if (ignoreSuspiciousEnvVars) {
        logWarning(
          `ignoring suspicious environment variable ${key}, did you mean to use quotes like CONVEX_DEPLOY_KEY='...'?`
        );
      } else {
        return await ctx.crash({
          exitCode: 1,
          errorType: "fatal",
          printedMessage: `Quotes are required around environment variable values by your shell: CONVEX_DEPLOY_KEY='project:name:project|${key.slice(0, 4)}...${key.slice(key.length - 4)}=' npx convex dev`
        });
      }
    }
  }
}
export function getBuildEnvironment() {
  return process.env.VERCEL ? "Vercel" : process.env.NETLIFY ? "Netlify" : false;
}
export function gitBranchFromEnvironment() {
  if (process.env.VERCEL) {
    return process.env.VERCEL_GIT_COMMIT_REF ?? null;
  }
  if (process.env.NETLIFY) {
    return process.env.HEAD ?? null;
  }
  if (process.env.CI) {
    return process.env.GITHUB_HEAD_REF ?? process.env.CI_COMMIT_REF_NAME ?? null;
  }
  return null;
}
export function isNonProdBuildEnvironment() {
  if (process.env.VERCEL) {
    return process.env.VERCEL_ENV !== "production";
  }
  if (process.env.NETLIFY) {
    return process.env.CONTEXT !== "production";
  }
  return false;
}
//# sourceMappingURL=envvars.js.map
