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
var workos_exports = {};
__export(workos_exports, {
  ensureAuthKitProvisionedBeforeBuild: () => ensureAuthKitProvisionedBeforeBuild,
  ensureWorkosEnvironmentProvisioned: () => ensureWorkosEnvironmentProvisioned,
  provisionWorkosTeamInteractive: () => provisionWorkosTeamInteractive,
  resolveTemplate: () => resolveTemplate,
  syncAuthKitConfigAfterPush: () => syncAuthKitConfigAfterPush,
  tryToCreateAssociatedWorkosTeam: () => tryToCreateAssociatedWorkosTeam
});
module.exports = __toCommonJS(workos_exports);
var import_crypto = __toESM(require("crypto"), 1);
var dotenv = __toESM(require("dotenv"), 1);
var import_log = require("../../../bundler/log.js");
var import_api = require("../api.js");
var import_env = require("../env.js");
var import_dashboard = require("../dashboard.js");
var import_envvars = require("../envvars.js");
var import_prompts = require("../utils/prompts.js");
var import_environmentApi = require("./environmentApi.js");
var import_platformApi = require("./platformApi.js");
var import_config = require("../config.js");
async function getWorkOSEnvVarsFromDeployment(ctx, deployment) {
  const [clientId, apiKey, environmentId] = await Promise.all([
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_CLIENT_ID"),
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_API_KEY"),
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_ENVIRONMENT_ID")
  ]);
  return { clientId, apiKey, environmentId };
}
async function resolveWorkOSCredentials(ctx, deployment, deploymentName, authKitConfig, workosDeploymentType) {
  const deploymentEnvVars = await getWorkOSEnvVarsFromDeployment(
    ctx,
    deployment
  );
  let clientId;
  let apiKey;
  let environmentId;
  if (workosDeploymentType === "dev") {
    clientId = process.env.WORKOS_CLIENT_ID || deploymentEnvVars.clientId || null;
    apiKey = deploymentEnvVars.apiKey || null;
    environmentId = process.env.WORKOS_ENVIRONMENT_ID || deploymentEnvVars.environmentId || null;
  } else {
    clientId = deploymentEnvVars.clientId || process.env.WORKOS_CLIENT_ID || null;
    apiKey = deploymentEnvVars.apiKey || null;
    environmentId = deploymentEnvVars.environmentId || process.env.WORKOS_ENVIRONMENT_ID || null;
  }
  if (!clientId || !apiKey) {
    const auth = ctx.bigBrainAuth();
    const isUsingDeploymentKey = auth?.kind === "deploymentKey";
    if (isUsingDeploymentKey) {
      await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: buildDeploymentKeyError(
          deploymentName,
          workosDeploymentType
        )
      });
    }
    (0, import_log.showSpinner)("Provisioning AuthKit environment...");
    try {
      const result = await ensureWorkosEnvironmentProvisioned(
        ctx,
        deploymentName,
        { ...deployment, deploymentNotice: "" },
        authKitConfig,
        workosDeploymentType
      );
      if (result !== "ready") {
        return await ctx.crash({
          exitCode: 1,
          errorType: "fatal",
          printedMessage: "Failed to provision WorkOS environment"
        });
      }
      const provisionedEnvVars = await getWorkOSEnvVarsFromDeployment(
        ctx,
        deployment
      );
      clientId = provisionedEnvVars.clientId;
      apiKey = provisionedEnvVars.apiKey;
      environmentId = provisionedEnvVars.environmentId;
      if (!clientId || !apiKey) {
        return await ctx.crash({
          exitCode: 1,
          errorType: "fatal",
          printedMessage: "Failed to retrieve WorkOS credentials after provisioning"
        });
      }
    } catch (error) {
      if (error.message?.includes("permission") || error.message?.includes("deploy key") || error.message?.includes("UnexpectedAuthHeaderFormat")) {
        await ctx.crash({
          exitCode: 1,
          errorType: "fatal",
          printedMessage: `Cannot provision WorkOS environment with current authentication.
You need to manually set WORKOS_CLIENT_ID and WORKOS_API_KEY
environment variables in your build environment or deployment settings.`
        });
      }
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: `Error provisioning WorkOS environment: ${error.message}`
      });
    }
  }
  return { clientId, apiKey, environmentId, deploymentEnvVars };
}
function buildDeploymentKeyError(deploymentName, deploymentType) {
  const integrationsUrl = (0, import_dashboard.deploymentDashboardUrlPage)(
    deploymentName,
    "/settings/integrations"
  );
  return `AuthKit configuration in convex.json requires WorkOS credentials.

Checked for credentials in:
  1. Build environment variables (WORKOS_CLIENT_ID, WORKOS_API_KEY)
  2. Deployment environment variables, see WorkOS integration at ${integrationsUrl}

When using a deployment-specific key, you cannot automatically provision WorkOS environments.
You must provide these credentials in your build platform (e.g., Vercel, Netlify)
or set them in your deployment settings.

Alternatively, remove the 'authKit.${deploymentType}' section from convex.json to skip
AuthKit configuration.`;
}
async function ensureDeploymentHasWorkOSCredentials(ctx, deployment, credentials, deploymentEnvVars) {
  const mismatches = [];
  if (deploymentEnvVars.clientId && deploymentEnvVars.clientId !== credentials.clientId) {
    mismatches.push(
      `  WORKOS_CLIENT_ID: deployment has '${deploymentEnvVars.clientId}' but we need '${credentials.clientId}'`
    );
  }
  if (deploymentEnvVars.apiKey && deploymentEnvVars.apiKey !== credentials.apiKey) {
    mismatches.push(
      `  WORKOS_API_KEY: deployment has different value than what we need`
    );
  }
  if (deploymentEnvVars.environmentId && credentials.environmentId && deploymentEnvVars.environmentId !== credentials.environmentId) {
    mismatches.push(
      `  WORKOS_ENVIRONMENT_ID: deployment has '${deploymentEnvVars.environmentId}' but we need '${credentials.environmentId}'`
    );
  }
  if (mismatches.length > 0) {
    await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `WorkOS environment variable mismatch detected!

The following environment variables in your Convex deployment don't match what's needed:
` + mismatches.join("\n") + `

This would cause your auth configuration to use different credentials at runtime than during build.

To fix this, remove the conflicting environment variables from your deployment:
  npx convex env remove WORKOS_CLIENT_ID
  npx convex env remove WORKOS_API_KEY
  npx convex env remove WORKOS_ENVIRONMENT_ID

Or remove them from the Convex dashboard deployment settings.

Then run your deployment command again.`
    });
  }
  const updates = [];
  if (!deploymentEnvVars.clientId && credentials.clientId) {
    updates.push({ name: "WORKOS_CLIENT_ID", value: credentials.clientId });
  }
  if (!deploymentEnvVars.apiKey && credentials.apiKey) {
    updates.push({ name: "WORKOS_API_KEY", value: credentials.apiKey });
  }
  if (!deploymentEnvVars.environmentId && credentials.environmentId) {
    updates.push({
      name: "WORKOS_ENVIRONMENT_ID",
      value: credentials.environmentId
    });
  }
  if (updates.length > 0) {
    (0, import_log.changeSpinner)("Setting WorkOS credentials in deployment...");
    await (0, import_env.callUpdateEnvironmentVariables)(
      ctx,
      { ...deployment, deploymentNotice: "" },
      updates
    );
    (0, import_log.logVerbose)(
      `WorkOS credentials propagated to deployment: ${updates.map((u) => u.name).join(", ")}`
    );
  }
}
async function ensureWorkosEnvironmentProvisioned(ctx, deploymentName, deployment, authKitConfig, deploymentType) {
  const envConfig = authKitConfig?.[deploymentType];
  if (!envConfig) {
    return "choseNotToAssociatedTeam";
  }
  (0, import_log.showSpinner)("Checking for associated AuthKit environment...");
  const existingEnvVars = await getExistingWorkosEnvVars(ctx, deployment);
  if (existingEnvVars.clientId && existingEnvVars.environmentId && existingEnvVars.apiKey) {
    (0, import_log.logOutput)(
      "Deployment already has environment variables for a WorkOS environment configured for AuthKit."
    );
    if (envConfig.localEnvVars !== void 0 && envConfig.localEnvVars !== false) {
      await updateEnvLocal(
        ctx,
        existingEnvVars.clientId,
        existingEnvVars.apiKey,
        existingEnvVars.environmentId,
        envConfig.localEnvVars
      );
    }
    if (envConfig.configure !== void 0 && envConfig.configure !== false) {
      if (!existingEnvVars.apiKey) {
        (0, import_log.logWarning)(
          `Skipping WorkOS AuthKit environment configuration: WORKOS_API_KEY is not set.
To configure redirect URIs and CORS origins, you need to set this environment variable.
You can set it at: ${deployment.deploymentUrl.replace(/\/$/, "")}/settings/environment-variables`
        );
      } else {
        await updateWorkosEnvironment(
          ctx,
          existingEnvVars.apiKey,
          envConfig.configure,
          {
            clientId: existingEnvVars.clientId,
            apiKey: existingEnvVars.apiKey,
            environmentId: existingEnvVars.environmentId
          }
        );
      }
    }
    (0, import_log.logFinishedStep)("WorkOS AuthKit environment ready");
    return "ready";
  }
  const response = await (0, import_platformApi.getDeploymentCanProvisionWorkOSEnvironments)(
    ctx,
    deploymentName
  );
  const { hasAssociatedWorkosTeam, teamId } = response;
  if (response.disabled) {
    return "choseNotToAssociatedTeam";
  }
  if (!hasAssociatedWorkosTeam) {
    const result = await tryToCreateAssociatedWorkosTeam(
      ctx,
      deploymentName,
      teamId,
      deploymentType
    );
    if (result === "choseNotToAssociatedTeam") {
      return "choseNotToAssociatedTeam";
    }
    result;
  }
  let workosEnvironmentType;
  if (envConfig.environmentType) {
    workosEnvironmentType = envConfig.environmentType === "production" ? "production" : "nonproduction";
  } else {
    workosEnvironmentType = deploymentType === "prod" ? "production" : "nonproduction";
  }
  const environmentResult = await (0, import_platformApi.createEnvironmentAndAPIKey)(
    ctx,
    deploymentName,
    workosEnvironmentType
  );
  if (!environmentResult.success) {
    if ("error" in environmentResult && environmentResult.error === "team_not_provisioned") {
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: `Team unexpectedly has no provisioned WorkOS team: ${environmentResult.message}`
      });
    }
    const errorMessage = "message" in environmentResult ? environmentResult.message : "Failed to provision WorkOS environment";
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: errorMessage
    });
  }
  const data = environmentResult.data;
  if (data.newlyProvisioned) {
    (0, import_log.logMessage)("New AuthKit environment provisioned");
  } else {
    (0, import_log.logMessage)(
      "Using credentials from existing AuthKit environment already created for this deployment"
    );
  }
  (0, import_log.changeSpinner)("Setting WORKOS_* deployment environment variables...");
  await setConvexEnvVars(
    ctx,
    deployment,
    data.clientId,
    data.environmentId,
    data.apiKey
  );
  if (envConfig.localEnvVars !== void 0 && envConfig.localEnvVars !== false) {
    (0, import_log.showSpinner)("Updating .env.local with WorkOS configuration");
    await updateEnvLocal(
      ctx,
      data.clientId,
      data.apiKey,
      data.environmentId,
      envConfig.localEnvVars
    );
  }
  if (envConfig.configure !== void 0 && envConfig.configure !== false) {
    await updateWorkosEnvironment(ctx, data.apiKey, envConfig.configure, {
      clientId: data.clientId,
      apiKey: data.apiKey,
      environmentId: data.environmentId
    });
  }
  (0, import_log.logFinishedStep)("WorkOS AuthKit environment ready");
  return "ready";
}
async function provisionWorkosTeamInteractive(ctx, deploymentName, teamId, deploymentType, options = {}) {
  const teamInfo = await (0, import_api.getTeamAndProjectSlugForDeployment)(ctx, {
    deploymentName
  });
  if (teamInfo === null) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Can't find Convex Cloud team for deployment ${deploymentName}`
    });
  }
  (0, import_log.stopSpinner)();
  const defaultPrefix = `A WorkOS team needs to be created for your Convex team "${teamInfo.teamSlug}" in order to use AuthKit.

You and other members of this team will be able to create WorkOS environments for each Convex dev deployment for projects in this team.

By creating this account you agree to the WorkOS Terms of Service (https://workos.com/legal/terms-of-service) and Privacy Policy (https://workos.com/legal/privacy).
Alternately, choose no and set WORKOS_CLIENT_ID for an existing WorkOS environment.

`;
  const defaultMessage = `Create a WorkOS team and enable automatic AuthKit environment provisioning for team "${teamInfo.teamSlug}"?`;
  const agree = await (0, import_prompts.promptYesNo)(ctx, {
    prefix: options.promptPrefix ?? defaultPrefix,
    message: options.promptMessage ?? defaultMessage,
    nonInteractiveError: `Cannot provision WorkOS AuthKit in non-interactive mode.

A WorkOS workspace needs to be associated with your Convex team to enable automatic environment provisioning.

To fix this, either:
1. Run this command in an interactive terminal to set up WorkOS provisioning
2. Remove the authKit.${deploymentType} section from convex.json and provide your own WorkOS credentials via the dashboard
3. Set WORKOS_CLIENT_ID and WORKOS_API_KEY environment variables before deploying`
  });
  if (!agree) {
    (0, import_log.logMessage)("\nGot it. We won't create your WorkOS account.");
    return { success: false, reason: "cancelled" };
  }
  const alreadyTried = /* @__PURE__ */ new Map();
  let email;
  while (true) {
    let choice = "refresh";
    while (choice === "refresh") {
      const { availableEmails } = await (0, import_platformApi.getCandidateEmailsForWorkIntegration)(ctx);
      choice = await (0, import_prompts.promptOptions)(ctx, {
        message: availableEmails.length === 1 ? "Create a new WorkOS team with this email address?" : "Create a new WorkOS team with which email address?",
        suffix: availableEmails.length === 0 ? "\nVisit https://dashboard.convex.dev/profile to add a verified email to use to provision a WorkOS account" : availableEmails.length === 1 ? "\nCreate a new WorkOS team with this email address?" : "\nTo use another email address visit https://dashboard.convex.dev/profile to add and verify, then choose 'refresh'",
        choices: [
          ...availableEmails.map((email2) => ({
            name: `${email2}${alreadyTried.has(email2) ? ` (can't create, a WorkOS team already exists with this email)` : ""}`,
            value: email2
          })),
          {
            name: "refresh (add an email at https://dashboard.convex.dev/profile)",
            value: "refresh"
          },
          {
            name: "cancel (do not create a WorkOS account)",
            value: "cancel"
          }
        ]
      });
    }
    if (choice === "cancel") {
      return { success: false, reason: "cancelled" };
    }
    email = choice;
    const teamResult = await (0, import_platformApi.createAssociatedWorkosTeam)(ctx, teamId, email);
    if (teamResult.result === "emailAlreadyUsed") {
      (0, import_log.logMessage)(teamResult.message);
      alreadyTried.set(email, teamResult.message);
      continue;
    }
    return {
      success: true,
      workosTeamId: teamResult.workosTeamId,
      workosTeamName: teamResult.workosTeamName
    };
  }
}
async function tryToCreateAssociatedWorkosTeam(ctx, deploymentName, teamId, deploymentType) {
  const result = await provisionWorkosTeamInteractive(
    ctx,
    deploymentName,
    teamId,
    deploymentType
  );
  if (!result.success) {
    const dashboardUrl = (0, import_dashboard.deploymentDashboardUrlPage)(
      deploymentName,
      `/settings/environment-variables?var=WORKOS_CLIENT_ID`
    );
    (0, import_log.logMessage)(
      `To provide your own WorkOS environment credentials instead, set environment variables manually on the dashboard:
  ${dashboardUrl}`
    );
    return "choseNotToAssociatedTeam";
  }
  (0, import_log.logFinishedStep)("WorkOS team created successfully");
  return "ready";
}
async function ensureAuthKitProvisionedBeforeBuild(ctx, deploymentName, deployment, deploymentType) {
  const { projectConfig } = await (0, import_config.readProjectConfig)(ctx);
  const authKitConfig = await (0, import_config.getAuthKitConfig)(ctx, projectConfig);
  if (!authKitConfig) {
    return;
  }
  const workosDeploymentType = deploymentType || "dev";
  const envConfig = authKitConfig[workosDeploymentType];
  if (!envConfig) {
    return;
  }
  const { clientId, apiKey, environmentId, deploymentEnvVars } = await resolveWorkOSCredentials(
    ctx,
    deployment,
    deploymentName,
    authKitConfig,
    workosDeploymentType
  );
  if (clientId && apiKey) {
    await ensureDeploymentHasWorkOSCredentials(
      ctx,
      deployment,
      { clientId, apiKey, environmentId },
      deploymentEnvVars
    );
  }
  if (envConfig.localEnvVars && process.stdin.isTTY && clientId && apiKey) {
    await updateEnvLocal(
      ctx,
      clientId,
      apiKey,
      environmentId || "",
      envConfig.localEnvVars
    );
  }
  if (envConfig.configure && apiKey) {
    const configValues = {
      apiKey
    };
    if (clientId) {
      configValues.clientId = clientId;
    }
    if (environmentId) {
      configValues.environmentId = environmentId;
    }
    await updateWorkosEnvironment(
      ctx,
      apiKey,
      envConfig.configure,
      configValues
    );
  }
}
async function syncAuthKitConfigAfterPush(ctx, projectConfig, deployment) {
  const authKitConfig = await (0, import_config.getAuthKitConfig)(ctx, projectConfig);
  if (!authKitConfig) {
    return false;
  }
  const devConfig = authKitConfig.dev;
  if (!devConfig) {
    return false;
  }
  const [clientId, apiKey, environmentId] = await Promise.all([
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_CLIENT_ID"),
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_API_KEY"),
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_ENVIRONMENT_ID")
  ]);
  if (!apiKey) {
    return false;
  }
  if (devConfig.configure !== void 0 && devConfig.configure !== false) {
    const provisionedValues = {
      apiKey
    };
    if (clientId) {
      provisionedValues.clientId = clientId;
    }
    if (environmentId) {
      provisionedValues.environmentId = environmentId;
    }
    await updateWorkosEnvironment(
      ctx,
      apiKey,
      devConfig.configure,
      provisionedValues
    );
  }
  return true;
}
async function updateWorkosEnvironment(ctx, workosApiKey, configureSettings, provisioned) {
  const isInteractive = process.stdin.isTTY;
  const skippedConfigs = [];
  const configItems = [];
  if (configureSettings.redirectUris?.length) {
    configItems.push(
      `${configureSettings.redirectUris.length} redirect URI(s)`
    );
  }
  if (configureSettings.appHomepageUrl) {
    configItems.push(`app homepage URL`);
  }
  if (configureSettings.corsOrigins?.length) {
    configItems.push(`${configureSettings.corsOrigins.length} CORS origin(s)`);
  }
  if (configItems.length > 0) {
    (0, import_log.logVerbose)(
      `Starting WorkOS AuthKit configuration: ${configItems.join(", ")}`
    );
  } else {
    (0, import_log.logVerbose)(`No WorkOS AuthKit configuration settings to apply`);
    return;
  }
  if (configureSettings.redirectUris) {
    for (const redirectUri of configureSettings.redirectUris) {
      try {
        const resolvedRedirectUri = resolveTemplate(redirectUri, provisioned);
        const { modified: redirectUriAdded } = await (0, import_environmentApi.createRedirectURI)(
          ctx,
          workosApiKey,
          resolvedRedirectUri
        );
        if (redirectUriAdded) {
          (0, import_log.changeSpinner)("Configuring AuthKit redirect URI...");
          (0, import_log.logMessage)(`AuthKit redirect URI added: ${resolvedRedirectUri}`);
        } else {
          (0, import_log.logVerbose)(
            `AuthKit redirect URI already configured: ${resolvedRedirectUri}`
          );
        }
      } catch (error) {
        if (isInteractive && error.message?.includes("Cannot resolve template")) {
          skippedConfigs.push(
            `Redirect URI: ${redirectUri} - ${error.message}`
          );
        } else {
          return await ctx.crash({
            exitCode: 1,
            errorType: "fatal",
            printedMessage: `Error configuring redirect URI: ${error.message}`
          });
        }
      }
    }
  }
  if (configureSettings.appHomepageUrl) {
    try {
      const resolvedAppHomepageUrl = resolveTemplate(
        configureSettings.appHomepageUrl,
        provisioned
      );
      const { modified: appHomepageUrlUpdated } = await (0, import_environmentApi.updateAppHomepageUrl)(
        ctx,
        workosApiKey,
        resolvedAppHomepageUrl
      );
      if (appHomepageUrlUpdated) {
        (0, import_log.changeSpinner)("Configuring AuthKit app homepage URL...");
        (0, import_log.logMessage)(
          `AuthKit app homepage URL updated: ${resolvedAppHomepageUrl}`
        );
      } else {
        (0, import_log.logVerbose)(
          `AuthKit app homepage URL was not updated (may be invalid for WorkOS or already set)`
        );
      }
    } catch (error) {
      if (isInteractive && error.message?.includes("Cannot resolve template")) {
        skippedConfigs.push(
          `App homepage URL: ${configureSettings.appHomepageUrl} - ${error.message}`
        );
      } else {
        return await ctx.crash({
          exitCode: 1,
          errorType: "fatal",
          printedMessage: `Error configuring app homepage URL: ${error.message}`
        });
      }
    }
  } else {
    (0, import_log.logVerbose)(`No app homepage URL configured`);
  }
  if (configureSettings.corsOrigins) {
    for (const corsOrigin of configureSettings.corsOrigins) {
      try {
        const resolvedCorsOrigin = resolveTemplate(corsOrigin, provisioned);
        const { modified: corsAdded } = await (0, import_environmentApi.createCORSOrigin)(
          ctx,
          workosApiKey,
          resolvedCorsOrigin
        );
        if (corsAdded) {
          (0, import_log.changeSpinner)("Configuring AuthKit CORS origin...");
          (0, import_log.logMessage)(`AuthKit CORS origin added: ${resolvedCorsOrigin}`);
        } else {
          (0, import_log.logVerbose)(
            `AuthKit CORS origin already configured: ${resolvedCorsOrigin}`
          );
        }
      } catch (error) {
        if (isInteractive && error.message?.includes("Cannot resolve template")) {
          skippedConfigs.push(`CORS origin: ${corsOrigin} - ${error.message}`);
        } else {
          return await ctx.crash({
            exitCode: 1,
            errorType: "fatal",
            printedMessage: `Error configuring CORS origin: ${error.message}`
          });
        }
      }
    }
  }
  (0, import_log.logVerbose)(`WorkOS AuthKit configuration completed`);
  if (skippedConfigs.length > 0) {
    (0, import_log.stopSpinner)();
    (0, import_log.logWarning)(
      `Skipped some AuthKit configurations due to missing environment variables:
` + skippedConfigs.map((s) => `  - ${s}`).join("\n")
    );
  }
}
function resolveTemplate(str, provisioned) {
  return str.replace(/\$\{([^}]+)\}/g, (match, expression) => {
    if (expression === "authEnv.WORKOS_CLIENT_ID") {
      if (!provisioned?.clientId) {
        throw new Error(
          `Cannot resolve template ${match}: WORKOS_CLIENT_ID not available. Ensure WorkOS environment is provisioned.`
        );
      }
      return provisioned.clientId;
    }
    if (expression === "authEnv.WORKOS_API_KEY") {
      if (!provisioned?.apiKey) {
        throw new Error(
          `Cannot resolve template ${match}: WORKOS_API_KEY not available. Ensure WorkOS environment is provisioned.`
        );
      }
      return provisioned.apiKey;
    }
    if (expression === "authEnv.WORKOS_ENVIRONMENT_ID") {
      if (!provisioned?.environmentId) {
        throw new Error(
          `Cannot resolve template ${match}: WORKOS_ENVIRONMENT_ID not available. Ensure WorkOS environment is provisioned.`
        );
      }
      return provisioned.environmentId;
    }
    if (expression.startsWith("buildEnv.")) {
      const varName = expression.substring("buildEnv.".length);
      const value = process.env[varName];
      if (!value) {
        throw new Error(
          `Cannot resolve template ${match}: Environment variable ${varName} is not set.`
        );
      }
      return value;
    }
    throw new Error(
      `Unknown template expression: ${match}. Use \${buildEnv.VAR_NAME} for environment variables or \${authEnv.WORKOS_CLIENT_ID/WORKOS_API_KEY} for provisioned values.`
    );
  });
}
async function updateEnvLocal(ctx, clientId, apiKey, environmentId, localEnvVarsConfig) {
  const envPath = ".env.local";
  let existingFileContent = ctx.fs.exists(envPath) ? ctx.fs.readUtf8File(envPath) : null;
  let suggestedChanges = {};
  const { detectedFramework } = await (0, import_envvars.suggestedEnvVarNames)(ctx);
  const existingEnvVars = existingFileContent ? dotenv.parse(existingFileContent) : {};
  for (const [envVarName, templateValue] of Object.entries(
    localEnvVarsConfig
  )) {
    if (existingEnvVars[envVarName]) {
      (0, import_log.logVerbose)(`Skipping ${envVarName} update - already in .env.local`);
      continue;
    }
    if (process.env[envVarName]) {
      (0, import_log.logVerbose)(
        `Skipping ${envVarName} update in .env.local - already set in environment`
      );
      continue;
    }
    const resolvedValue = resolveTemplate(templateValue, {
      clientId,
      apiKey,
      environmentId
    });
    if (Object.keys(suggestedChanges).length === 0 && (templateValue.includes("authEnv.WORKOS_CLIENT_ID") || templateValue === "${authEnv.WORKOS_CLIENT_ID}")) {
      suggestedChanges[envVarName] = {
        value: resolvedValue,
        commentOnPreviousLine: `# See this environment at ${workosUrl(environmentId, "/authentication")}`
      };
    } else {
      suggestedChanges[envVarName] = { value: resolvedValue };
    }
  }
  if ((detectedFramework === "Next.js" || detectedFramework === "TanStackStart") && !process.env["WORKOS_COOKIE_PASSWORD"] && // Don't override environment
  (!existingFileContent || !existingFileContent.includes("WORKOS_COOKIE_PASSWORD"))) {
    suggestedChanges["WORKOS_COOKIE_PASSWORD"] = {
      value: import_crypto.default.randomBytes(32).toString("base64url")
    };
  }
  for (const [
    envVarName,
    { value: envVarValue, commentOnPreviousLine, commentAfterValue }
  ] of Object.entries(suggestedChanges)) {
    existingFileContent = (0, import_envvars.changedEnvVarFile)({
      existingFileContent,
      envVarName,
      envVarValue,
      commentAfterValue: commentAfterValue ?? null,
      commentOnPreviousLine: commentOnPreviousLine ?? null
    }) || existingFileContent;
  }
  if (existingFileContent !== null && Object.keys(suggestedChanges).length > 0) {
    ctx.fs.writeUtf8File(envPath, existingFileContent);
    (0, import_log.logMessage)(
      `Updated .env.local with ${Object.keys(suggestedChanges).join(", ")}`
    );
  }
}
async function getExistingWorkosEnvVars(ctx, deployment) {
  const [clientId, environmentId, apiKey] = await Promise.all([
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_CLIENT_ID"),
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_ENVIRONMENT_ID"),
    (0, import_env.envGetInDeployment)(ctx, deployment, "WORKOS_API_KEY")
  ]);
  return { clientId, environmentId, apiKey };
}
async function setConvexEnvVars(ctx, deployment, workosClientId, workosEnvironmentId, workosEnvironmentApiKey) {
  await (0, import_env.callUpdateEnvironmentVariables)(ctx, deployment, [
    { name: "WORKOS_CLIENT_ID", value: workosClientId },
    { name: "WORKOS_ENVIRONMENT_ID", value: workosEnvironmentId },
    { name: "WORKOS_API_KEY", value: workosEnvironmentApiKey }
  ]);
}
function workosUrl(environmentId, subpath) {
  return `https://dashboard.workos.com/${environmentId}${subpath}`;
}
//# sourceMappingURL=workos.js.map
