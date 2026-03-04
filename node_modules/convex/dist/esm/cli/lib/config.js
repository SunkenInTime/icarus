"use strict";
import { chalkStderr } from "chalk";
import path from "path";
import { z } from "zod";
import {
  changeSpinner,
  logError,
  logFailure,
  logFinishedStep,
  logMessage,
  logWarning,
  showSpinner
} from "../../bundler/log.js";
import {
  bundle,
  bundleAuthConfig,
  entryPointsByEnvironment
} from "../../bundler/index.js";
import { version } from "../version.js";
import { deploymentDashboardUrlPage } from "./dashboard.js";
import {
  functionsDir,
  loadPackageJson,
  deploymentFetch,
  deprecationCheckWarning,
  logAndHandleFetchError,
  ThrowingFetchError,
  currentPackageHomepage
} from "./utils/utils.js";
import { recursivelyDelete } from "./fsUtils.js";
import {
  LocalDeploymentError,
  printLocalDeploymentOnError
} from "./localDeployment/errors.js";
import { debugIsolateBundlesSerially } from "../../bundler/debugBundle.js";
export { productionProvisionHost, provisionHost } from "./utils/utils.js";
const DEFAULT_FUNCTIONS_PATH = "convex/";
export function usesTypeScriptCodegen(projectConfig) {
  return projectConfig.codegen.fileType === "ts";
}
export function usesComponentApiImports(projectConfig) {
  return projectConfig.codegen.legacyComponentApi === false;
}
export async function getAuthKitConfig(ctx, projectConfig) {
  if ("authKit" in projectConfig) {
    return projectConfig.authKit;
  }
  const homepage = await currentPackageHomepage(ctx);
  const isOldWorkOSTemplate = !!(homepage && [
    "https://github.com/workos/template-convex-nextjs-authkit/#readme",
    "https://github.com/workos/template-convex-react-vite-authkit/#readme",
    "https://github.com:workos/template-convex-react-vite-authkit/#readme",
    "https://github.com/workos/template-convex-tanstack-start-authkit/#readme"
  ].includes(homepage));
  if (isOldWorkOSTemplate) {
    logWarning(
      "The template this project is based on has been updated to work with this version of Convex."
    );
    logWarning(
      "Please copy the convex.json from the latest template version or add an 'authKit' section."
    );
    logMessage("Learn more at https://docs.convex.dev/auth/authkit");
  }
}
export async function getAuthKitEnvironmentConfig(ctx, projectConfig, deploymentType) {
  const authKitConfig = await getAuthKitConfig(ctx, projectConfig);
  return authKitConfig?.[deploymentType];
}
class ParseError extends Error {
}
const AuthKitConfigureSchema = z.union([
  z.literal(false),
  z.object({
    redirectUris: z.array(z.string()).optional(),
    appHomepageUrl: z.string().optional(),
    corsOrigins: z.array(z.string()).optional()
  })
]);
const AuthKitLocalEnvVarsSchema = z.union([
  z.literal(false),
  z.record(z.string())
]);
const AuthKitEnvironmentConfigSchema = z.object({
  environmentType: z.enum(["development", "staging", "production"]).optional(),
  configure: AuthKitConfigureSchema.optional(),
  localEnvVars: AuthKitLocalEnvVarsSchema.optional()
});
const AuthKitConfigSchema = z.object({
  dev: AuthKitEnvironmentConfigSchema.optional(),
  preview: AuthKitEnvironmentConfigSchema.optional(),
  prod: AuthKitEnvironmentConfigSchema.optional()
}).refine(
  (data) => {
    const devEnvType = data.dev?.environmentType;
    const previewEnvType = data.preview?.environmentType;
    if (devEnvType || previewEnvType) {
      return false;
    }
    return true;
  },
  {
    message: "authKit.environmentType is only allowed in the prod section",
    path: ["environmentType"]
  }
).refine(
  (data) => {
    if (data.preview?.localEnvVars !== void 0 && data.preview?.localEnvVars !== false) {
      return false;
    }
    if (data.prod?.localEnvVars !== void 0 && data.prod?.localEnvVars !== false) {
      return false;
    }
    return true;
  },
  {
    message: "authKit.localEnvVars is only supported for dev deployments. Preview and prod deployments must configure environment variables directly in the deployment platform.",
    path: ["localEnvVars"]
  }
);
const NodeSchema = z.object({
  externalPackages: z.array(z.string()).default([]).describe(
    "list of npm packages to install at deploy time instead of bundling. Packages with binaries should be added here."
  ),
  nodeVersion: z.string().optional().describe("The Node.js version to use for Node.js functions")
});
const CodegenSchema = z.object({
  staticApi: z.boolean().default(false).describe(
    "Use Convex function argument validators and return value validators to generate a typed API object"
  ),
  staticDataModel: z.boolean().default(false),
  // These optional fields have no defaults - their presence/absence is meaningful
  legacyComponentApi: z.boolean().optional(),
  fileType: z.enum(["ts", "js/dts"]).optional()
});
const BundlerSchema = z.object({
  includeSourcesContent: z.boolean().default(false).describe(
    "Whether to include original source code in source maps. Set to false to reduce bundle size."
  )
});
const refineToObject = (schema) => schema.refine((val) => val !== null && !Array.isArray(val), {
  message: "Expected `convex.json` to contain an object"
});
const createProjectConfigSchema = (strict) => {
  const nodeSchema = strict ? NodeSchema.strict() : NodeSchema.passthrough();
  const codegenSchema = strict ? CodegenSchema.strict() : CodegenSchema.passthrough();
  const bundlerSchema = strict ? BundlerSchema.strict() : BundlerSchema.passthrough();
  const baseObject = z.object({
    functions: z.string().default(DEFAULT_FUNCTIONS_PATH).describe("Relative file path to the convex directory"),
    node: nodeSchema.default({ externalPackages: [] }),
    codegen: codegenSchema.default({
      staticApi: false,
      staticDataModel: false
    }),
    bundler: bundlerSchema.default({ includeSourcesContent: false }).optional(),
    generateCommonJSApi: z.boolean().default(false),
    typescriptCompiler: z.enum(["tsc", "tsgo"]).optional().describe(
      "TypeScript compiler to use for typechecking (`@typescript/native-preview` must be installed to use `tsgo`)"
    ),
    // Optional $schema field for JSON schema validation in editors
    $schema: z.string().optional(),
    // WorkOS AuthKit integration configuration
    authKit: AuthKitConfigSchema.optional(),
    // Deprecated fields that have been deprecated for years, only here so we
    // know it's safe to delete them.
    project: z.string().optional(),
    team: z.string().optional(),
    prodUrl: z.string().optional()
  });
  const withStrictness = strict ? baseObject.strict() : baseObject.passthrough();
  return withStrictness.refine(
    (data) => {
      if (data.generateCommonJSApi && data.codegen.fileType === "ts") {
        return false;
      }
      return true;
    },
    {
      message: 'Cannot use `generateCommonJSApi: true` with `codegen.fileType: "ts"`. CommonJS modules require JavaScript generation. Either set `codegen.fileType: "js/dts"` or remove `generateCommonJSApi`.',
      path: ["generateCommonJSApi"]
    }
  );
};
const ProjectConfigSchema = refineToObject(createProjectConfigSchema(false));
const ProjectConfigSchemaStrict = refineToObject(
  createProjectConfigSchema(true)
);
const warnedUnknownKeys = /* @__PURE__ */ new Set();
export function resetUnknownKeyWarnings() {
  warnedUnknownKeys.clear();
}
export async function parseProjectConfig(ctx, obj) {
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "invalid filesystem data",
      printedMessage: "Expected `convex.json` to contain an object"
    });
  }
  try {
    return ProjectConfigSchemaStrict.parse(obj);
  } catch (error) {
    if (error instanceof z.ZodError) {
      const unknownKeyIssues = error.issues.filter(
        (issue) => issue.code === "unrecognized_keys"
      );
      if (unknownKeyIssues.length > 0 && unknownKeyIssues.length === error.issues.length) {
        for (const issue of unknownKeyIssues) {
          if (issue.code === "unrecognized_keys") {
            const pathPrefix = issue.path.length > 0 ? issue.path.join(".") + "." : "";
            const unknownKeys = issue.keys;
            const newUnknownKeys = unknownKeys.filter(
              (key) => !warnedUnknownKeys.has(pathPrefix + key)
            );
            if (newUnknownKeys.length > 0) {
              const fullPath = issue.path.length > 0 ? `\`${issue.path.join(".")}\`` : "`convex.json`";
              logMessage(
                chalkStderr.yellow(
                  `Warning: Unknown ${newUnknownKeys.length === 1 ? "property" : "properties"} in ${fullPath}: ${newUnknownKeys.map((k) => `\`${k}\``).join(", ")}`
                )
              );
              logMessage(
                chalkStderr.gray(
                  "  These properties will be preserved but are not recognized by this version of Convex."
                )
              );
              newUnknownKeys.forEach(
                (key) => warnedUnknownKeys.add(pathPrefix + key)
              );
            }
          }
        }
        return ProjectConfigSchema.parse(obj);
      }
      if (error instanceof z.ZodError) {
        const issue = error.issues[0];
        const pathStr = issue.path.join(".");
        const message = pathStr ? `\`${pathStr}\` in \`convex.json\`: ${issue.message}` : `\`convex.json\`: ${issue.message}`;
        return await ctx.crash({
          exitCode: 1,
          errorType: "invalid filesystem data",
          printedMessage: message
        });
      }
    }
    return await ctx.crash({
      exitCode: 1,
      errorType: "invalid filesystem data",
      printedMessage: error.toString()
    });
  }
}
function parseBackendConfig(obj) {
  function throwParseError(message) {
    throw new ParseError(message);
  }
  if (typeof obj !== "object") {
    throwParseError("Expected an object");
  }
  const { functions, nodeVersion } = obj;
  if (typeof functions !== "string") {
    throwParseError("Expected functions to be a string");
  }
  if (typeof nodeVersion !== "undefined" && typeof nodeVersion !== "string") {
    throwParseError("Expected nodeVersion to be a string");
  }
  return {
    functions,
    ...(nodeVersion ?? null) !== null ? { nodeVersion } : {}
  };
}
export function configName() {
  return "convex.json";
}
export async function configFilepath(ctx) {
  const configFn = configName();
  const preferredLocation = configFn;
  const wrongLocation = path.join("src", configFn);
  const preferredLocationExists = ctx.fs.exists(preferredLocation);
  const wrongLocationExists = ctx.fs.exists(wrongLocation);
  if (preferredLocationExists && wrongLocationExists) {
    const message = `${chalkStderr.red(`Error: both ${preferredLocation} and ${wrongLocation} files exist!`)}
Consolidate these and remove ${wrongLocation}.`;
    return await ctx.crash({
      exitCode: 1,
      errorType: "invalid filesystem data",
      printedMessage: message
    });
  }
  if (!preferredLocationExists && wrongLocationExists) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "invalid filesystem data",
      printedMessage: `Error: Please move ${wrongLocation} to the root of your project`
    });
  }
  return preferredLocation;
}
export async function getFunctionsDirectoryPath(ctx) {
  const { projectConfig, configPath } = await readProjectConfig(ctx);
  return functionsDir(configPath, projectConfig);
}
export async function readProjectConfig(ctx) {
  if (!ctx.fs.exists("convex.json")) {
    const packages = await loadPackageJson(ctx);
    const isCreateReactApp = "react-scripts" in packages;
    return {
      projectConfig: {
        functions: isCreateReactApp ? `src/${DEFAULT_FUNCTIONS_PATH}` : DEFAULT_FUNCTIONS_PATH,
        node: {
          externalPackages: []
        },
        generateCommonJSApi: false,
        codegen: {
          staticApi: false,
          staticDataModel: false
        }
      },
      configPath: configName()
    };
  }
  let projectConfig;
  const configPath = await configFilepath(ctx);
  try {
    projectConfig = await parseProjectConfig(
      ctx,
      JSON.parse(ctx.fs.readUtf8File(configPath))
    );
  } catch (err) {
    if (err instanceof ParseError || err instanceof SyntaxError) {
      logError(chalkStderr.red(`Error: Parsing "${configPath}" failed`));
      logMessage(chalkStderr.gray(err.toString()));
    } else {
      logFailure(
        `Error: Unable to read project config file "${configPath}"
  Are you running this command from the root directory of a Convex project? If so, run \`npx convex dev\` first.`
      );
      if (err instanceof Error) {
        logError(chalkStderr.red(err.message));
      }
    }
    return await ctx.crash({
      exitCode: 1,
      errorType: "invalid filesystem data",
      errForSentry: err,
      // TODO -- move the logging above in here
      printedMessage: null
    });
  }
  return {
    projectConfig,
    configPath
  };
}
export async function configFromProjectConfig(ctx, projectConfig, configPath, verbose) {
  const baseDir = functionsDir(configPath, projectConfig);
  const entryPoints = await entryPointsByEnvironment(ctx, baseDir);
  if (verbose) {
    showSpinner("Bundling modules for Convex's runtime...");
  }
  const convexResult = await bundle({
    ctx,
    dir: baseDir,
    entryPoints: entryPoints.isolate,
    generateSourceMaps: true,
    platform: "browser"
  });
  if (verbose) {
    logMessage(
      "Convex's runtime modules: ",
      convexResult.modules.map((m) => m.path)
    );
  }
  if (verbose && entryPoints.node.length !== 0) {
    showSpinner("Bundling modules for Node.js runtime...");
  }
  const nodeResult = await bundle({
    ctx,
    dir: baseDir,
    entryPoints: entryPoints.node,
    generateSourceMaps: true,
    platform: "node",
    chunksFolder: path.join("_deps", "node"),
    externalPackagesAllowList: projectConfig.node.externalPackages
  });
  if (verbose && entryPoints.node.length !== 0) {
    logMessage(
      "Node.js runtime modules: ",
      nodeResult.modules.map((m) => m.path)
    );
    if (projectConfig.node.externalPackages.length > 0) {
      logMessage(
        "Node.js runtime external dependencies (to be installed on the server): ",
        [...nodeResult.externalDependencies.entries()].map(
          (a) => `${a[0]}: ${a[1]}`
        )
      );
    }
  }
  const modules = convexResult.modules;
  modules.push(...nodeResult.modules);
  modules.push(...await bundleAuthConfig(ctx, baseDir));
  const nodeDependencies = [];
  for (const [moduleName, moduleVersion] of nodeResult.externalDependencies) {
    nodeDependencies.push({ name: moduleName, version: moduleVersion });
  }
  const bundledModuleInfos = Array.from(
    convexResult.bundledModuleNames.keys()
  ).map((moduleName) => {
    return {
      name: moduleName,
      platform: "convex"
    };
  });
  bundledModuleInfos.push(
    ...Array.from(nodeResult.bundledModuleNames.keys()).map(
      (moduleName) => {
        return {
          name: moduleName,
          platform: "node"
        };
      }
    )
  );
  return {
    config: {
      projectConfig,
      modules,
      nodeDependencies,
      // We're just using the version this CLI is running with for now.
      // This could be different than the version of `convex` the app runs with
      // if the CLI is installed globally.
      udfServerVersion: version,
      nodeVersion: projectConfig.node.nodeVersion
    },
    bundledModuleInfos
  };
}
export async function debugIsolateEndpointBundles(ctx, projectConfig, configPath) {
  const baseDir = functionsDir(configPath, projectConfig);
  const entryPoints = await entryPointsByEnvironment(ctx, baseDir);
  if (entryPoints.isolate.length === 0) {
    logFinishedStep("No non-'use node' modules found.");
  }
  await debugIsolateBundlesSerially(ctx, {
    entryPoints: entryPoints.isolate,
    extraConditions: [],
    dir: baseDir
  });
}
export async function readConfig(ctx, verbose) {
  const { projectConfig, configPath } = await readProjectConfig(ctx);
  const { config, bundledModuleInfos } = await configFromProjectConfig(
    ctx,
    projectConfig,
    configPath,
    verbose
  );
  return { config, configPath, bundledModuleInfos };
}
export async function writeProjectConfig(ctx, projectConfig) {
  const configPath = await configFilepath(ctx);
  ctx.fs.mkdir(functionsDir(configPath, projectConfig), {
    allowExisting: true
  });
}
export function removedExistingConfig(ctx, configPath, options) {
  if (!options.allowExistingConfig) {
    return false;
  }
  recursivelyDelete(ctx, configPath);
  logFinishedStep(`Removed existing ${configPath}`);
  return true;
}
export async function pullConfig(ctx, project, team, origin, adminKey) {
  const fetch = deploymentFetch(ctx, {
    deploymentUrl: origin,
    adminKey
  });
  changeSpinner("Downloading current deployment state...");
  try {
    const res = await fetch("/api/get_config_hashes", {
      method: "POST",
      body: JSON.stringify({ version, adminKey })
    });
    deprecationCheckWarning(ctx, res);
    const data = await res.json();
    const backendConfig = parseBackendConfig(data.config);
    const projectConfig = {
      ...backendConfig,
      node: {
        // This field is not stored in the backend, which is ok since it is also
        // not used to diff configs.
        externalPackages: [],
        nodeVersion: data.nodeVersion
      },
      // This field is not stored in the backend, it only affects the client.
      generateCommonJSApi: false,
      // This field is also not stored in the backend, it only affects the client.
      codegen: {
        staticApi: false,
        staticDataModel: false
      },
      project,
      team,
      prodUrl: origin
    };
    return {
      projectConfig,
      moduleHashes: data.moduleHashes,
      // TODO(presley): Add this to diffConfig().
      nodeDependencies: data.nodeDependencies,
      udfServerVersion: data.udfServerVersion
    };
  } catch (err) {
    logFailure(`Error: Unable to pull deployment config from ${origin}`);
    return await logAndHandleFetchError(ctx, err);
  }
}
export function diffConfig(oldConfig, newConfig) {
  let diff = "";
  let versionMessage = "";
  const matches = oldConfig.udfServerVersion === newConfig.udfServerVersion;
  if (oldConfig.udfServerVersion && (!newConfig.udfServerVersion || !matches)) {
    versionMessage += `[-] ${oldConfig.udfServerVersion}
`;
  }
  if (newConfig.udfServerVersion && (!oldConfig.udfServerVersion || !matches)) {
    versionMessage += `[+] ${newConfig.udfServerVersion}
`;
  }
  if (versionMessage) {
    diff += "Change the server's function version:\n";
    diff += versionMessage;
  }
  if (oldConfig.projectConfig.node.nodeVersion !== newConfig.nodeVersion) {
    diff += "Change the server's version for Node.js actions:\n";
    if (oldConfig.projectConfig.node.nodeVersion) {
      diff += `[-] ${oldConfig.projectConfig.node.nodeVersion}
`;
    }
    if (newConfig.nodeVersion) {
      diff += `[+] ${newConfig.nodeVersion}
`;
    }
  }
  return { diffString: diff };
}
export async function handlePushConfigError(ctx, error, defaultMessage, deploymentName, deployment, _deploymentType) {
  const data = error instanceof ThrowingFetchError ? error.serverErrorData : void 0;
  if (data?.code === "AuthConfigMissingEnvironmentVariable") {
    const errorMessage = data.message || "(no error message given)";
    const [, variableName] = errorMessage.match(/Environment variable (\S+)/i) ?? [];
    if (variableName === "WORKOS_CLIENT_ID" && deploymentName && deployment) {
      logWarning(
        "WORKOS_CLIENT_ID is not set; you can set it manually on the deployment or for hosted Convex deployments, use auto-provisioning."
      );
      logMessage(
        "Learn more at https://docs.convex.dev/auth/authkit/auto-provision"
      );
      logMessage("");
    }
    const envVarMessage = `Environment variable ${chalkStderr.bold(
      variableName
    )} is used in auth config file but its value was not set.`;
    let setEnvVarInstructions = "Go set it in the dashboard or using `npx convex env set`";
    if (deploymentName !== null) {
      const variableQuery = variableName !== void 0 ? `?var=${variableName}` : "";
      const dashboardUrl = deploymentDashboardUrlPage(
        deploymentName,
        `/settings/environment-variables${variableQuery}`
      );
      setEnvVarInstructions = `Go to:

    ${chalkStderr.bold(
        dashboardUrl
      )}

  to set it up. `;
    }
    await ctx.crash({
      exitCode: 1,
      errorType: "invalid filesystem or env vars",
      errForSentry: error,
      printedMessage: envVarMessage + "\n" + setEnvVarInstructions
    });
  }
  if (data?.code === "RaceDetected") {
    const message = data.message || "Schema or environment variables changed during push";
    return await ctx.crash({
      exitCode: 1,
      errorType: "transient",
      errForSentry: error,
      printedMessage: chalkStderr.yellow(message)
    });
  }
  if (data?.code === "InternalServerError") {
    if (deploymentName?.startsWith("local-")) {
      printLocalDeploymentOnError();
      return ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        errForSentry: new LocalDeploymentError(
          "InternalServerError while pushing to local deployment"
        ),
        printedMessage: defaultMessage
      });
    }
  }
  logFailure(defaultMessage);
  return await logAndHandleFetchError(ctx, error);
}
//# sourceMappingURL=config.js.map
