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
var config_exports = {};
__export(config_exports, {
  configFilepath: () => configFilepath,
  configFromProjectConfig: () => configFromProjectConfig,
  configName: () => configName,
  debugIsolateEndpointBundles: () => debugIsolateEndpointBundles,
  diffConfig: () => diffConfig,
  getAuthKitConfig: () => getAuthKitConfig,
  getAuthKitEnvironmentConfig: () => getAuthKitEnvironmentConfig,
  getFunctionsDirectoryPath: () => getFunctionsDirectoryPath,
  handlePushConfigError: () => handlePushConfigError,
  parseProjectConfig: () => parseProjectConfig,
  productionProvisionHost: () => import_utils2.productionProvisionHost,
  provisionHost: () => import_utils2.provisionHost,
  pullConfig: () => pullConfig,
  readConfig: () => readConfig,
  readProjectConfig: () => readProjectConfig,
  removedExistingConfig: () => removedExistingConfig,
  resetUnknownKeyWarnings: () => resetUnknownKeyWarnings,
  usesComponentApiImports: () => usesComponentApiImports,
  usesTypeScriptCodegen: () => usesTypeScriptCodegen,
  writeProjectConfig: () => writeProjectConfig
});
module.exports = __toCommonJS(config_exports);
var import_chalk = require("chalk");
var import_path = __toESM(require("path"), 1);
var import_zod = require("zod");
var import_log = require("../../bundler/log.js");
var import_bundler = require("../../bundler/index.js");
var import_version = require("../version.js");
var import_dashboard = require("./dashboard.js");
var import_utils = require("./utils/utils.js");
var import_fsUtils = require("./fsUtils.js");
var import_errors = require("./localDeployment/errors.js");
var import_debugBundle = require("../../bundler/debugBundle.js");
var import_utils2 = require("./utils/utils.js");
const DEFAULT_FUNCTIONS_PATH = "convex/";
function usesTypeScriptCodegen(projectConfig) {
  return projectConfig.codegen.fileType === "ts";
}
function usesComponentApiImports(projectConfig) {
  return projectConfig.codegen.legacyComponentApi === false;
}
async function getAuthKitConfig(ctx, projectConfig) {
  if ("authKit" in projectConfig) {
    return projectConfig.authKit;
  }
  const homepage = await (0, import_utils.currentPackageHomepage)(ctx);
  const isOldWorkOSTemplate = !!(homepage && [
    "https://github.com/workos/template-convex-nextjs-authkit/#readme",
    "https://github.com/workos/template-convex-react-vite-authkit/#readme",
    "https://github.com:workos/template-convex-react-vite-authkit/#readme",
    "https://github.com/workos/template-convex-tanstack-start-authkit/#readme"
  ].includes(homepage));
  if (isOldWorkOSTemplate) {
    (0, import_log.logWarning)(
      "The template this project is based on has been updated to work with this version of Convex."
    );
    (0, import_log.logWarning)(
      "Please copy the convex.json from the latest template version or add an 'authKit' section."
    );
    (0, import_log.logMessage)("Learn more at https://docs.convex.dev/auth/authkit");
  }
}
async function getAuthKitEnvironmentConfig(ctx, projectConfig, deploymentType) {
  const authKitConfig = await getAuthKitConfig(ctx, projectConfig);
  return authKitConfig?.[deploymentType];
}
class ParseError extends Error {
}
const AuthKitConfigureSchema = import_zod.z.union([
  import_zod.z.literal(false),
  import_zod.z.object({
    redirectUris: import_zod.z.array(import_zod.z.string()).optional(),
    appHomepageUrl: import_zod.z.string().optional(),
    corsOrigins: import_zod.z.array(import_zod.z.string()).optional()
  })
]);
const AuthKitLocalEnvVarsSchema = import_zod.z.union([
  import_zod.z.literal(false),
  import_zod.z.record(import_zod.z.string())
]);
const AuthKitEnvironmentConfigSchema = import_zod.z.object({
  environmentType: import_zod.z.enum(["development", "staging", "production"]).optional(),
  configure: AuthKitConfigureSchema.optional(),
  localEnvVars: AuthKitLocalEnvVarsSchema.optional()
});
const AuthKitConfigSchema = import_zod.z.object({
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
const NodeSchema = import_zod.z.object({
  externalPackages: import_zod.z.array(import_zod.z.string()).default([]).describe(
    "list of npm packages to install at deploy time instead of bundling. Packages with binaries should be added here."
  ),
  nodeVersion: import_zod.z.string().optional().describe("The Node.js version to use for Node.js functions")
});
const CodegenSchema = import_zod.z.object({
  staticApi: import_zod.z.boolean().default(false).describe(
    "Use Convex function argument validators and return value validators to generate a typed API object"
  ),
  staticDataModel: import_zod.z.boolean().default(false),
  // These optional fields have no defaults - their presence/absence is meaningful
  legacyComponentApi: import_zod.z.boolean().optional(),
  fileType: import_zod.z.enum(["ts", "js/dts"]).optional()
});
const BundlerSchema = import_zod.z.object({
  includeSourcesContent: import_zod.z.boolean().default(false).describe(
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
  const baseObject = import_zod.z.object({
    functions: import_zod.z.string().default(DEFAULT_FUNCTIONS_PATH).describe("Relative file path to the convex directory"),
    node: nodeSchema.default({ externalPackages: [] }),
    codegen: codegenSchema.default({
      staticApi: false,
      staticDataModel: false
    }),
    bundler: bundlerSchema.default({ includeSourcesContent: false }).optional(),
    generateCommonJSApi: import_zod.z.boolean().default(false),
    typescriptCompiler: import_zod.z.enum(["tsc", "tsgo"]).optional().describe(
      "TypeScript compiler to use for typechecking (`@typescript/native-preview` must be installed to use `tsgo`)"
    ),
    // Optional $schema field for JSON schema validation in editors
    $schema: import_zod.z.string().optional(),
    // WorkOS AuthKit integration configuration
    authKit: AuthKitConfigSchema.optional(),
    // Deprecated fields that have been deprecated for years, only here so we
    // know it's safe to delete them.
    project: import_zod.z.string().optional(),
    team: import_zod.z.string().optional(),
    prodUrl: import_zod.z.string().optional()
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
function resetUnknownKeyWarnings() {
  warnedUnknownKeys.clear();
}
async function parseProjectConfig(ctx, obj) {
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
    if (error instanceof import_zod.z.ZodError) {
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
              (0, import_log.logMessage)(
                import_chalk.chalkStderr.yellow(
                  `Warning: Unknown ${newUnknownKeys.length === 1 ? "property" : "properties"} in ${fullPath}: ${newUnknownKeys.map((k) => `\`${k}\``).join(", ")}`
                )
              );
              (0, import_log.logMessage)(
                import_chalk.chalkStderr.gray(
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
      if (error instanceof import_zod.z.ZodError) {
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
function configName() {
  return "convex.json";
}
async function configFilepath(ctx) {
  const configFn = configName();
  const preferredLocation = configFn;
  const wrongLocation = import_path.default.join("src", configFn);
  const preferredLocationExists = ctx.fs.exists(preferredLocation);
  const wrongLocationExists = ctx.fs.exists(wrongLocation);
  if (preferredLocationExists && wrongLocationExists) {
    const message = `${import_chalk.chalkStderr.red(`Error: both ${preferredLocation} and ${wrongLocation} files exist!`)}
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
async function getFunctionsDirectoryPath(ctx) {
  const { projectConfig, configPath } = await readProjectConfig(ctx);
  return (0, import_utils.functionsDir)(configPath, projectConfig);
}
async function readProjectConfig(ctx) {
  if (!ctx.fs.exists("convex.json")) {
    const packages = await (0, import_utils.loadPackageJson)(ctx);
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
      (0, import_log.logError)(import_chalk.chalkStderr.red(`Error: Parsing "${configPath}" failed`));
      (0, import_log.logMessage)(import_chalk.chalkStderr.gray(err.toString()));
    } else {
      (0, import_log.logFailure)(
        `Error: Unable to read project config file "${configPath}"
  Are you running this command from the root directory of a Convex project? If so, run \`npx convex dev\` first.`
      );
      if (err instanceof Error) {
        (0, import_log.logError)(import_chalk.chalkStderr.red(err.message));
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
async function configFromProjectConfig(ctx, projectConfig, configPath, verbose) {
  const baseDir = (0, import_utils.functionsDir)(configPath, projectConfig);
  const entryPoints = await (0, import_bundler.entryPointsByEnvironment)(ctx, baseDir);
  if (verbose) {
    (0, import_log.showSpinner)("Bundling modules for Convex's runtime...");
  }
  const convexResult = await (0, import_bundler.bundle)({
    ctx,
    dir: baseDir,
    entryPoints: entryPoints.isolate,
    generateSourceMaps: true,
    platform: "browser"
  });
  if (verbose) {
    (0, import_log.logMessage)(
      "Convex's runtime modules: ",
      convexResult.modules.map((m) => m.path)
    );
  }
  if (verbose && entryPoints.node.length !== 0) {
    (0, import_log.showSpinner)("Bundling modules for Node.js runtime...");
  }
  const nodeResult = await (0, import_bundler.bundle)({
    ctx,
    dir: baseDir,
    entryPoints: entryPoints.node,
    generateSourceMaps: true,
    platform: "node",
    chunksFolder: import_path.default.join("_deps", "node"),
    externalPackagesAllowList: projectConfig.node.externalPackages
  });
  if (verbose && entryPoints.node.length !== 0) {
    (0, import_log.logMessage)(
      "Node.js runtime modules: ",
      nodeResult.modules.map((m) => m.path)
    );
    if (projectConfig.node.externalPackages.length > 0) {
      (0, import_log.logMessage)(
        "Node.js runtime external dependencies (to be installed on the server): ",
        [...nodeResult.externalDependencies.entries()].map(
          (a) => `${a[0]}: ${a[1]}`
        )
      );
    }
  }
  const modules = convexResult.modules;
  modules.push(...nodeResult.modules);
  modules.push(...await (0, import_bundler.bundleAuthConfig)(ctx, baseDir));
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
      udfServerVersion: import_version.version,
      nodeVersion: projectConfig.node.nodeVersion
    },
    bundledModuleInfos
  };
}
async function debugIsolateEndpointBundles(ctx, projectConfig, configPath) {
  const baseDir = (0, import_utils.functionsDir)(configPath, projectConfig);
  const entryPoints = await (0, import_bundler.entryPointsByEnvironment)(ctx, baseDir);
  if (entryPoints.isolate.length === 0) {
    (0, import_log.logFinishedStep)("No non-'use node' modules found.");
  }
  await (0, import_debugBundle.debugIsolateBundlesSerially)(ctx, {
    entryPoints: entryPoints.isolate,
    extraConditions: [],
    dir: baseDir
  });
}
async function readConfig(ctx, verbose) {
  const { projectConfig, configPath } = await readProjectConfig(ctx);
  const { config, bundledModuleInfos } = await configFromProjectConfig(
    ctx,
    projectConfig,
    configPath,
    verbose
  );
  return { config, configPath, bundledModuleInfos };
}
async function writeProjectConfig(ctx, projectConfig) {
  const configPath = await configFilepath(ctx);
  ctx.fs.mkdir((0, import_utils.functionsDir)(configPath, projectConfig), {
    allowExisting: true
  });
}
function removedExistingConfig(ctx, configPath, options) {
  if (!options.allowExistingConfig) {
    return false;
  }
  (0, import_fsUtils.recursivelyDelete)(ctx, configPath);
  (0, import_log.logFinishedStep)(`Removed existing ${configPath}`);
  return true;
}
async function pullConfig(ctx, project, team, origin, adminKey) {
  const fetch = (0, import_utils.deploymentFetch)(ctx, {
    deploymentUrl: origin,
    adminKey
  });
  (0, import_log.changeSpinner)("Downloading current deployment state...");
  try {
    const res = await fetch("/api/get_config_hashes", {
      method: "POST",
      body: JSON.stringify({ version: import_version.version, adminKey })
    });
    (0, import_utils.deprecationCheckWarning)(ctx, res);
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
    (0, import_log.logFailure)(`Error: Unable to pull deployment config from ${origin}`);
    return await (0, import_utils.logAndHandleFetchError)(ctx, err);
  }
}
function diffConfig(oldConfig, newConfig) {
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
async function handlePushConfigError(ctx, error, defaultMessage, deploymentName, deployment, _deploymentType) {
  const data = error instanceof import_utils.ThrowingFetchError ? error.serverErrorData : void 0;
  if (data?.code === "AuthConfigMissingEnvironmentVariable") {
    const errorMessage = data.message || "(no error message given)";
    const [, variableName] = errorMessage.match(/Environment variable (\S+)/i) ?? [];
    if (variableName === "WORKOS_CLIENT_ID" && deploymentName && deployment) {
      (0, import_log.logWarning)(
        "WORKOS_CLIENT_ID is not set; you can set it manually on the deployment or for hosted Convex deployments, use auto-provisioning."
      );
      (0, import_log.logMessage)(
        "Learn more at https://docs.convex.dev/auth/authkit/auto-provision"
      );
      (0, import_log.logMessage)("");
    }
    const envVarMessage = `Environment variable ${import_chalk.chalkStderr.bold(
      variableName
    )} is used in auth config file but its value was not set.`;
    let setEnvVarInstructions = "Go set it in the dashboard or using `npx convex env set`";
    if (deploymentName !== null) {
      const variableQuery = variableName !== void 0 ? `?var=${variableName}` : "";
      const dashboardUrl = (0, import_dashboard.deploymentDashboardUrlPage)(
        deploymentName,
        `/settings/environment-variables${variableQuery}`
      );
      setEnvVarInstructions = `Go to:

    ${import_chalk.chalkStderr.bold(
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
      printedMessage: import_chalk.chalkStderr.yellow(message)
    });
  }
  if (data?.code === "InternalServerError") {
    if (deploymentName?.startsWith("local-")) {
      (0, import_errors.printLocalDeploymentOnError)();
      return ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        errForSentry: new import_errors.LocalDeploymentError(
          "InternalServerError while pushing to local deployment"
        ),
        printedMessage: defaultMessage
      });
    }
  }
  (0, import_log.logFailure)(defaultMessage);
  return await (0, import_utils.logAndHandleFetchError)(ctx, error);
}
//# sourceMappingURL=config.js.map
