"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
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
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var integration_exports = {};
__export(integration_exports, {
  integration: () => integration
});
module.exports = __toCommonJS(integration_exports);
var import_extra_typings = require("@commander-js/extra-typings");
var import_context = require("../bundler/context.js");
var import_chalk = require("chalk");
var import_api = require("./lib/api.js");
var import_command = require("./lib/command.js");
var import_utils = require("./lib/utils/utils.js");
var import_deploymentSelection = require("./lib/deploymentSelection.js");
var import_workos = require("./lib/workos/workos.js");
var import_platformApi = require("./lib/workos/platformApi.js");
var import_log = require("../bundler/log.js");
var import_config = require("./lib/config.js");
var import_prompts = require("./lib/utils/prompts.js");
async function selectEnvDeployment(options) {
  const ctx = await (0, import_context.oneoffContext)(options);
  const deploymentSelection = await (0, import_deploymentSelection.getDeploymentSelection)(ctx, options);
  const selectionWithinProject = (0, import_api.deploymentSelectionWithinProjectFromOptions)(options);
  const {
    adminKey,
    url: deploymentUrl,
    deploymentFields
  } = await (0, import_api.loadSelectedDeploymentCredentials)(
    ctx,
    deploymentSelection,
    selectionWithinProject
  );
  if (!deploymentFields) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: "WorkOS integration requires a configured deployment"
    });
  }
  const deploymentNotice = ` (on ${import_chalk.chalkStderr.bold(deploymentFields.deploymentType)} deployment ${import_chalk.chalkStderr.bold(deploymentFields.deploymentName)})`;
  const deploymentType = deploymentFields.deploymentType;
  if (deploymentType === "custom") {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `The WorkOS integration is not available for custom deployments yet.`
    });
  }
  if (deploymentType !== "dev" && deploymentType !== "preview" && deploymentType !== "prod") {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `The WorkOS integration is only available for cloud deployments (dev, preview, prod), not ${deploymentType}`
    });
  }
  return {
    ctx,
    deployment: {
      deploymentName: deploymentFields.deploymentName,
      deploymentType,
      deploymentUrl,
      adminKey,
      deploymentNotice
    }
  };
}
const workosTeamStatus = new import_extra_typings.Command("status").summary("Status of associated WorkOS team and environment").addDeploymentSelectionOptions((0, import_command.actionDescription)("Check WorkOS status for")).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const { ctx, deployment } = await selectEnvDeployment(options);
  const info = await (0, import_api.fetchTeamAndProject)(ctx, deployment.deploymentName);
  const teamHealth = await (0, import_platformApi.getWorkosTeamHealth)(ctx, info.teamId);
  if (!teamHealth) {
    (0, import_log.logMessage)(`WorkOS team: Not provisioned`);
    const { availableEmails } = await (0, import_platformApi.getCandidateEmailsForWorkIntegration)(ctx);
    if (availableEmails.length > 0) {
      (0, import_log.logMessage)(
        `  Verified emails that can provision: ${availableEmails.join(", ")}`
      );
    }
  } else if (teamHealth.productionState === "inactive") {
    (0, import_log.logMessage)(
      `WorkOS team: ${teamHealth.name} (no credit card added on workos.com, so production auth environments cannot be created)`
    );
  } else {
    (0, import_log.logMessage)(`WorkOS team: ${teamHealth.name}`);
  }
  const envHealth = await (0, import_platformApi.getWorkosEnvironmentHealth)(
    ctx,
    deployment.deploymentName
  );
  if (!envHealth) {
    (0, import_log.logMessage)(`WorkOS environment: Not provisioned`);
  } else {
    (0, import_log.logMessage)(`WorkOS environment: ${envHealth.name}`);
    const workosUrl = `https://dashboard.workos.com/${envHealth.id}/authentication`;
    (0, import_log.logMessage)(`${workosUrl}`);
  }
  try {
    const { projectConfig } = await (0, import_config.readProjectConfig)(ctx);
    const authKitConfig = await (0, import_config.getAuthKitConfig)(ctx, projectConfig);
    if (!authKitConfig) {
      (0, import_log.logMessage)(
        `AuthKit config: ${import_chalk.chalkStderr.dim("Not configured in convex.json")}`
      );
    } else {
      (0, import_log.logMessage)(`AuthKit config:`);
      for (const deploymentType of ["dev", "preview", "prod"]) {
        const envConfig = authKitConfig[deploymentType];
        if (!envConfig) {
          (0, import_log.logMessage)(
            `  ${deploymentType}: ${import_chalk.chalkStderr.dim("not configured")}`
          );
          continue;
        }
        let description = "";
        if (deploymentType === "prod" && envConfig.environmentType) {
          description = `environment type: ${envConfig.environmentType}`;
        }
        const configureStatus = envConfig.configure === false ? ", configure: disabled" : envConfig.configure ? ", will configure WorkOS" : "";
        const localEnvVarsStatus = envConfig.localEnvVars === false ? "" : envConfig.localEnvVars ? `, ${Object.keys(envConfig.localEnvVars).length} local env vars` : "";
        const configInfo = [description, configureStatus, localEnvVarsStatus].filter((s) => s).join("");
        (0, import_log.logMessage)(`  ${deploymentType}: ${configInfo || "configured"}`);
      }
    }
  } catch (error) {
    (0, import_log.logMessage)(
      `AuthKit config: ${import_chalk.chalkStderr.yellow(`Error reading config: ${String(error)}`)}`
    );
  }
});
const workosProvisionEnvironment = new import_extra_typings.Command("provision-environment").summary("Provision a WorkOS environment").description(
  "Create or get the WorkOS environment and API key for this deployment"
).configureHelp({ showGlobalOptions: true }).allowExcessArguments(false).addDeploymentSelectionOptions(
  (0, import_command.actionDescription)("Provision WorkOS environment for")
).option(
  "--name <name>",
  "Custom name for the WorkOS environment (if not provided, uses deployment name)"
).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const { ctx, deployment } = await selectEnvDeployment(options);
  await (0, import_utils.ensureHasConvexDependency)(
    ctx,
    "integration workos provision-environment"
  );
  try {
    const { projectConfig } = await (0, import_config.readProjectConfig)(ctx);
    const authKitConfig = await (0, import_config.getAuthKitConfig)(ctx, projectConfig);
    const config = authKitConfig || { dev: {} };
    if (!authKitConfig) {
      (0, import_log.logWarning)(
        "Consider using the 'authKit' config in convex.json for automatic provisioning."
      );
      (0, import_log.logMessage)(
        "Learn more at https://docs.convex.dev/auth/authkit/auto-provision"
      );
      (0, import_log.logMessage)("");
    }
    await (0, import_workos.ensureWorkosEnvironmentProvisioned)(
      ctx,
      deployment.deploymentName,
      deployment,
      config,
      deployment.deploymentType
    );
  } catch (error) {
    await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      errForSentry: error,
      printedMessage: `Failed to provision WorkOS environment: ${String(error)}`
    });
  }
});
const workosProvisionTeam = new import_extra_typings.Command("provision-team").summary("Provision a WorkOS team for this Convex team").description(
  "Create a WorkOS team and associate it with this Convex team. This enables automatic provisioning of WorkOS environments for deployments on this team."
).configureHelp({ showGlobalOptions: true }).allowExcessArguments(false).addDeploymentSelectionOptions((0, import_command.actionDescription)("Provision WorkOS team for")).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const { ctx, deployment } = await selectEnvDeployment(options);
  const { hasAssociatedWorkosTeam, teamId } = await (0, import_platformApi.getDeploymentCanProvisionWorkOSEnvironments)(
    ctx,
    deployment.deploymentName
  );
  if (hasAssociatedWorkosTeam) {
    (0, import_log.logMessage)(
      import_chalk.chalkStderr.yellow(
        "This Convex team already has an associated WorkOS team."
      )
    );
    (0, import_log.logMessage)(
      import_chalk.chalkStderr.dim(
        "Use 'npx convex integration workos status' to view details."
      )
    );
    return;
  }
  const result = await (0, import_workos.provisionWorkosTeamInteractive)(
    ctx,
    deployment.deploymentName,
    teamId,
    deployment.deploymentType
  );
  if (!result.success) {
    (0, import_log.logMessage)(import_chalk.chalkStderr.gray("Cancelled."));
    return;
  }
  (0, import_log.logMessage)(
    import_chalk.chalkStderr.green(
      `
\u2713 Successfully created WorkOS team "${result.workosTeamName}" (${result.workosTeamId})`
    )
  );
  (0, import_log.logMessage)(
    import_chalk.chalkStderr.dim(
      "You can now provision WorkOS environments for deployments on this team."
    )
  );
});
const workosDisconnectTeam = new import_extra_typings.Command("disconnect-team").summary("Disconnect WorkOS team from Convex team").description(
  "Remove the associated WorkOS team from this Convex team. This is a destructive action that will prevent new WorkOS environments from being provisioned. Existing environments will continue to work with their current API keys."
).configureHelp({ showGlobalOptions: true }).allowExcessArguments(false).addDeploymentSelectionOptions(
  (0, import_command.actionDescription)("Disconnect WorkOS team for")
).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const { ctx, deployment } = await selectEnvDeployment(options);
  const { hasAssociatedWorkosTeam, teamId } = await (0, import_platformApi.getDeploymentCanProvisionWorkOSEnvironments)(
    ctx,
    deployment.deploymentName
  );
  if (!hasAssociatedWorkosTeam) {
    (0, import_log.logMessage)(
      import_chalk.chalkStderr.yellow(
        "This Convex team does not have an associated WorkOS team."
      )
    );
    return;
  }
  const info = await (0, import_api.getTeamAndProjectSlugForDeployment)(ctx, {
    deploymentName: deployment.deploymentName
  });
  (0, import_log.logMessage)(
    import_chalk.chalkStderr.yellow(
      `Warning: This will disconnect the WorkOS team from Convex team "${info?.teamSlug}".`
    )
  );
  (0, import_log.logMessage)(
    "AuthKit environments provisioned for Convex deployments on this team will no longer use this WorkOS team to provision environments."
  );
  (0, import_log.logMessage)(
    import_chalk.chalkStderr.dim(
      "Existing WorkOS environments will continue to work with their current API keys."
    )
  );
  const confirmed = await (0, import_prompts.promptYesNo)(ctx, {
    message: "Are you sure you want to disconnect this WorkOS team?",
    default: false
  });
  if (!confirmed) {
    (0, import_log.logMessage)(import_chalk.chalkStderr.gray("Cancelled."));
    return;
  }
  const result = await (0, import_platformApi.disconnectWorkOSTeam)(ctx, teamId);
  if (!result.success) {
    if (result.error === "not_associated") {
      (0, import_log.logMessage)(
        import_chalk.chalkStderr.yellow(
          "This Convex team does not have an associated WorkOS team."
        )
      );
      return;
    }
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Failed to disconnect WorkOS team: ${result.message}`
    });
  }
  (0, import_log.logFinishedStep)(
    `Successfully disconnected WorkOS team "${result.workosTeamName}" (${result.workosTeamId})`
  );
});
const workosInvite = new import_extra_typings.Command("invite").summary("Invite yourself to the WorkOS team").description(
  "Send an invitation to join the WorkOS team associated with your Convex team"
).option("--email <email>", "Email address to invite (skips validation)").configureHelp({ showGlobalOptions: true }).allowExcessArguments(false).addDeploymentSelectionOptions(
  (0, import_command.actionDescription)("Invite yourself to WorkOS team for")
).action(async (options, cmd) => {
  const allOptions = cmd.optsWithGlobals();
  const { ctx, deployment } = await selectEnvDeployment(allOptions);
  const info = await (0, import_api.fetchTeamAndProject)(ctx, deployment.deploymentName);
  let emailToInvite;
  if (options.email) {
    emailToInvite = options.email;
  } else {
    const { eligibleEmails, adminEmail } = await (0, import_platformApi.getInvitationEligibleEmails)(
      ctx,
      info.teamId
    );
    const allInvitableEmails = [...eligibleEmails];
    if (adminEmail && !allInvitableEmails.includes(adminEmail)) {
      allInvitableEmails.push(adminEmail);
    }
    if (allInvitableEmails.length === 0) {
      (0, import_log.logMessage)(
        "You don't have any verified emails available for invitation."
      );
      (0, import_log.logMessage)(
        "This could be because all your verified emails are already admin of other WorkOS teams."
      );
      return;
    }
    emailToInvite = await (0, import_prompts.promptOptions)(ctx, {
      message: "Which email would you like to invite to the WorkOS team?",
      choices: allInvitableEmails.map((email) => ({
        name: email + (email === adminEmail ? " (admin email)" : ""),
        value: email
      })),
      default: allInvitableEmails[0]
    });
    const confirmed = await (0, import_prompts.promptYesNo)(ctx, {
      message: `Send invitation to ${emailToInvite}?`,
      default: true
    });
    if (!confirmed) {
      (0, import_log.logMessage)("Invitation cancelled.");
      return;
    }
  }
  (0, import_log.logMessage)(`Sending invitation to ${emailToInvite}...`);
  const result = await (0, import_platformApi.inviteToWorkosTeam)(ctx, info.teamId, emailToInvite);
  if (result.result === "success") {
    (0, import_log.logMessage)(
      `\u2713 Successfully sent invitation to ${result.email} with role ${result.roleSlug}`
    );
    (0, import_log.logMessage)(
      "Check your email for the invitation link to join the WorkOS team."
    );
  } else if (result.result === "teamNotProvisioned") {
    (0, import_log.logMessage)(
      `\u2717 ${result.message}. Run 'npx convex integration workos provision-environment' first.`
    );
  } else if (result.result === "alreadyInWorkspace") {
    (0, import_log.logMessage)(
      `\u2717 ${result.message}. This usually means the email is already used in another WorkOS workspace.`
    );
  }
});
const workosProjectEnvList = new import_extra_typings.Command("list-project-environments").summary("List WorkOS environments for current project").description(
  "List all WorkOS AuthKit environments created for the current project.\nThese environments can be used across multiple deployments."
).addDeploymentSelectionOptions(
  (0, import_command.actionDescription)("List project environments for")
).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const { ctx, deployment } = await selectEnvDeployment(options);
  const info = await (0, import_api.fetchTeamAndProject)(ctx, deployment.deploymentName);
  (0, import_log.logMessage)("Fetching project WorkOS environments...");
  try {
    const environments = await (0, import_platformApi.listProjectWorkOSEnvironments)(
      ctx,
      info.projectId
    );
    if (environments.length === 0) {
      (0, import_log.logMessage)("No WorkOS environments found for this project.");
      (0, import_log.logMessage)(
        import_chalk.chalkStderr.gray(
          "Create one with: npx convex integration workos create-project-environment --name <name>"
        )
      );
    } else {
      (0, import_log.logMessage)(import_chalk.chalkStderr.bold("WorkOS Project Environments:"));
      for (const env of environments) {
        const prodLabel = env.isProduction ? import_chalk.chalkStderr.yellow(" (production)") : "";
        (0, import_log.logMessage)(
          `  ${import_chalk.chalkStderr.green(env.userEnvironmentName)}${prodLabel} - Client ID: ${env.workosClientId}`
        );
      }
    }
  } catch (error) {
    (0, import_log.logMessage)(
      import_chalk.chalkStderr.red(`Failed to list environments: ${String(error)}`)
    );
  }
});
const workosProjectEnvCreate = new import_extra_typings.Command("create-project-environment").summary("Create a new WorkOS environment for the project").description(
  "Create a new WorkOS AuthKit environment for this project.\nThe environment can be used across multiple deployments."
).requiredOption("--name <name>", "Name for the new environment").option("--production", "Mark this environment as a production environment").addDeploymentSelectionOptions(
  (0, import_command.actionDescription)("Create project environment for")
).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const environmentName = options.name;
  const isProduction = options.production;
  const { ctx, deployment } = await selectEnvDeployment(options);
  const info = await (0, import_api.fetchTeamAndProject)(ctx, deployment.deploymentName);
  (0, import_log.showSpinner)(
    `Creating project-level WorkOS environment '${environmentName}'...`
  );
  try {
    const response = await (0, import_platformApi.createProjectWorkOSEnvironment)(
      ctx,
      info.projectId,
      environmentName,
      isProduction
    );
    (0, import_log.stopSpinner)();
    (0, import_log.logFinishedStep)(`Created WorkOS environment '${environmentName}'`);
    (0, import_log.logMessage)("");
    (0, import_log.logMessage)(import_chalk.chalkStderr.bold("Environment Details:"));
    (0, import_log.logMessage)(`  Name: ${response.userEnvironmentName}`);
    (0, import_log.logMessage)(`  Client ID: ${response.workosClientId}`);
    (0, import_log.logMessage)(`  API Key: ${response.workosApiKey}`);
  } catch (error) {
    (0, import_log.stopSpinner)();
    if (error?.message?.includes("NoWorkOSTeam")) {
      (0, import_log.logMessage)(
        import_chalk.chalkStderr.red(
          "Your team doesn't have a WorkOS integration configured yet."
        )
      );
      (0, import_log.logMessage)(
        "Please run 'npx convex integration workos provision-team' first."
      );
    } else if (error?.message?.includes("duplicate")) {
      (0, import_log.logMessage)(
        import_chalk.chalkStderr.red(
          `An environment named '${environmentName}' already exists for this project.`
        )
      );
    } else if (error?.message?.includes("TooManyEnvironments")) {
      (0, import_log.logMessage)(
        import_chalk.chalkStderr.red(
          "You've reached the limit of 10 WorkOS environments per project. If you need more, please contact support."
        )
      );
    } else {
      (0, import_log.logMessage)(import_chalk.chalkStderr.red(`Failed to create environment: ${error}`));
    }
  }
});
const workosProjectEnvDelete = new import_extra_typings.Command("delete-project-environment").summary("Delete a WorkOS environment from the project").description(
  "Delete a WorkOS environment from this project.\nThis will permanently remove the environment and its credentials.\nUse the client ID shown in list-project-environments output."
).requiredOption(
  "--client-id <clientId>",
  "WorkOS client ID of the environment to delete (shown in list output)"
).addDeploymentSelectionOptions(
  (0, import_command.actionDescription)("Delete project environment for")
).action(async (_options, cmd) => {
  const options = cmd.optsWithGlobals();
  const clientId = options.clientId;
  const { ctx, deployment } = await selectEnvDeployment(options);
  const info = await (0, import_api.fetchTeamAndProject)(ctx, deployment.deploymentName);
  const confirmed = await (0, import_prompts.promptYesNo)(ctx, {
    message: `Are you sure you want to delete environment with client ID '${clientId}'?`,
    default: false
  });
  if (!confirmed) {
    (0, import_log.logMessage)("Deletion cancelled.");
    return;
  }
  (0, import_log.showSpinner)(
    `Deleting project WorkOS environment (this can take a while)...`
  );
  try {
    await (0, import_platformApi.deleteProjectWorkOSEnvironment)(ctx, info.projectId, clientId);
    (0, import_log.stopSpinner)();
    (0, import_log.logFinishedStep)(`Deleted environment with client ID '${clientId}'`);
  } catch (error) {
    (0, import_log.stopSpinner)();
    if (error?.message?.includes("not found")) {
      (0, import_log.logMessage)(
        import_chalk.chalkStderr.red(
          `Environment with client ID '${clientId}' not found.`
        )
      );
    } else {
      (0, import_log.logMessage)(import_chalk.chalkStderr.red(`Failed to delete environment: ${error}`));
    }
  }
});
const workos = new import_extra_typings.Command("workos").summary("WorkOS integration commands").description("Manage WorkOS team provisioning and environment setup").addCommand(workosProvisionEnvironment).addCommand(workosTeamStatus).addCommand(workosProvisionTeam).addCommand(workosDisconnectTeam).addCommand(workosInvite).addCommand(workosProjectEnvList).addCommand(workosProjectEnvCreate).addCommand(workosProjectEnvDelete);
const integration = new import_extra_typings.Command("integration").summary("Integration commands").description("Commands for managing third-party integrations").addCommand(workos);
//# sourceMappingURL=integration.js.map
