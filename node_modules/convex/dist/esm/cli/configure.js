"use strict";
import { chalkStderr } from "chalk";
import {
  logFailure,
  logFinishedStep,
  logMessage,
  logWarning,
  showSpinner
} from "../bundler/log.js";
import {
  fetchDeploymentCredentialsProvisioningDevOrProdMaybeThrows,
  createProject,
  loadSelectedDeploymentCredentials,
  checkAccessToSelectedProject,
  validateDeploymentSelectionForExistingDeployment
} from "./lib/api.js";
import { readProjectConfig, writeProjectConfig } from "./lib/config.js";
import {
  eraseDeploymentEnvVar,
  writeDeploymentEnvVar
} from "./lib/deployment.js";
import { finalizeConfiguration } from "./lib/init.js";
import {
  CONVEX_DEPLOYMENT_ENV_VAR_NAME,
  functionsDir,
  hasProjects,
  logAndHandleFetchError,
  selectDevDeploymentType,
  selectRegionOrUseDefault,
  validateOrSelectProject,
  validateOrSelectTeam
} from "./lib/utils/utils.js";
import { writeUrlsToEnvFile } from "./lib/envvars.js";
import path from "path";
import { projectDashboardUrl } from "./lib/dashboard.js";
import { doInitConvexFolder } from "./lib/codegen.js";
import { handleLocalDeployment } from "./lib/localDeployment/localDeployment.js";
import {
  promptOptions,
  promptString,
  promptYesNo
} from "./lib/utils/prompts.js";
import { readGlobalConfig } from "./lib/utils/globalConfig.js";
import {
  deploymentNameFromSelection,
  shouldAllowAnonymousDevelopment
} from "./lib/deploymentSelection.js";
import { ensureLoggedIn } from "./lib/login.js";
import { handleAnonymousDeployment } from "./lib/localDeployment/anonymous.js";
import { fetchDeploymentCanonicalSiteUrl } from "./lib/env.js";
export async function deploymentCredentialsOrConfigure(ctx, deploymentSelection, chosenConfiguration, cmdOptions) {
  const selectedDeployment = await _deploymentCredentialsOrConfigure(
    ctx,
    deploymentSelection,
    chosenConfiguration,
    cmdOptions
  );
  const siteUrl = await fetchDeploymentCanonicalSiteUrl(ctx, {
    adminKey: selectedDeployment.adminKey,
    deploymentUrl: selectedDeployment.url
  });
  if (selectedDeployment.deploymentFields !== null) {
    await updateEnvAndConfigForDeploymentSelection(
      ctx,
      {
        url: selectedDeployment.url,
        siteUrl,
        deploymentName: selectedDeployment.deploymentFields.deploymentName,
        teamSlug: selectedDeployment.deploymentFields.teamSlug,
        projectSlug: selectedDeployment.deploymentFields.projectSlug,
        deploymentType: selectedDeployment.deploymentFields.deploymentType
      },
      deploymentNameFromSelection(deploymentSelection)
    );
  } else {
    await handleManuallySetUrlAndAdminKey(ctx, {
      url: selectedDeployment.url,
      siteUrl,
      adminKey: selectedDeployment.adminKey
    });
  }
  return {
    url: selectedDeployment.url,
    adminKey: selectedDeployment.adminKey,
    deploymentFields: selectedDeployment.deploymentFields === null ? null : { ...selectedDeployment.deploymentFields, siteUrl }
  };
}
export async function _deploymentCredentialsOrConfigure(ctx, deploymentSelection, chosenConfiguration, cmdOptions) {
  const config = readGlobalConfig(ctx);
  const globallyForceCloud = !!config?.optOutOfLocalDevDeploymentsUntilBetaOver;
  if (globallyForceCloud && cmdOptions.local) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: "Can't specify --local when local deployments are disabled on this machine. Run `npx convex disable-local-deployments --undo-global` to allow use of --local."
    });
  }
  switch (deploymentSelection.kind) {
    case "existingDeployment":
      await validateDeploymentSelectionForExistingDeployment(
        ctx,
        cmdOptions.selectionWithinProject,
        deploymentSelection.deploymentToActOn.source
      );
      return {
        url: deploymentSelection.deploymentToActOn.url,
        adminKey: deploymentSelection.deploymentToActOn.adminKey,
        deploymentFields: deploymentSelection.deploymentToActOn.deploymentFields
      };
    case "chooseProject": {
      await ensureLoggedIn(ctx, {
        overrideAuthUrl: cmdOptions.overrideAuthUrl,
        overrideAuthClient: cmdOptions.overrideAuthClient,
        overrideAuthUsername: cmdOptions.overrideAuthUsername,
        overrideAuthPassword: cmdOptions.overrideAuthPassword
      });
      return await handleChooseProject(
        ctx,
        chosenConfiguration,
        {
          globallyForceCloud
        },
        cmdOptions
      );
    }
    case "preview":
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "Use `npx convex deploy` to use preview deployments."
      });
    case "deploymentWithinProject": {
      return await handleDeploymentWithinProject(ctx, {
        chosenConfiguration,
        targetProject: deploymentSelection.targetProject,
        cmdOptions,
        globallyForceCloud
      });
    }
    case "anonymous": {
      const hasAuth = ctx.bigBrainAuth() !== null;
      const isAgentMode = process.env.CONVEX_AGENT_MODE === "anonymous";
      if (!isAgentMode && hasAuth && deploymentSelection.deploymentName !== null) {
        const shouldConfigure = chosenConfiguration !== null || await promptYesNo(ctx, {
          message: `${CONVEX_DEPLOYMENT_ENV_VAR_NAME} is configured with deployment ${deploymentSelection.deploymentName}, which is not linked with your account. Would you like to link it now?`
        });
        if (!shouldConfigure) {
          return await ctx.crash({
            exitCode: 0,
            errorType: "fatal",
            printedMessage: `Run \`npx convex login --link-deployments\` first to link this deployment to your account, and then run \`npx convex dev\` again.`
          });
        }
        return await handleChooseProject(
          ctx,
          chosenConfiguration,
          {
            globallyForceCloud
          },
          cmdOptions
        );
      }
      const alreadyHasConfiguredAnonymousDeployment = deploymentSelection.deploymentName !== null && chosenConfiguration === null;
      if (isAgentMode) {
        logWarning(
          chalkStderr.yellow.bold(
            "CONVEX_AGENT_MODE=anonymous mode is in beta, functionality may change in the future."
          )
        );
      }
      const shouldPromptForLogin = isAgentMode ? "no" : alreadyHasConfiguredAnonymousDeployment ? "no" : await promptOptions(ctx, {
        message: "Welcome to Convex! Would you like to login to your account?",
        choices: [
          {
            name: "Start without an account (run Convex locally)",
            value: "no"
          },
          { name: "Login or create an account", value: "yes" }
        ],
        default: "no"
      });
      if (shouldPromptForLogin === "no") {
        const result = await handleAnonymousDeployment(ctx, {
          chosenConfiguration,
          deploymentName: deploymentSelection.deploymentName,
          ...cmdOptions.localOptions
        });
        return {
          adminKey: result.adminKey,
          url: result.deploymentUrl,
          deploymentFields: {
            deploymentName: result.deploymentName,
            deploymentType: "anonymous",
            projectSlug: null,
            teamSlug: null
          }
        };
      }
      return await handleChooseProject(
        ctx,
        chosenConfiguration,
        {
          globallyForceCloud
        },
        cmdOptions
      );
    }
  }
}
async function handleDeploymentWithinProject(ctx, {
  chosenConfiguration,
  targetProject,
  cmdOptions,
  globallyForceCloud
}) {
  const hasAuth = ctx.bigBrainAuth() !== null;
  const loginMessage = hasAuth && shouldAllowAnonymousDevelopment() ? void 0 : `Tip: You can try out Convex without creating an account by clearing the ${CONVEX_DEPLOYMENT_ENV_VAR_NAME} environment variable (often in .env.local).`;
  await ensureLoggedIn(ctx, {
    message: loginMessage,
    overrideAuthUrl: cmdOptions.overrideAuthUrl,
    overrideAuthClient: cmdOptions.overrideAuthClient,
    overrideAuthUsername: cmdOptions.overrideAuthUsername,
    overrideAuthPassword: cmdOptions.overrideAuthPassword
  });
  if (chosenConfiguration !== null) {
    const result = await handleChooseProject(
      ctx,
      chosenConfiguration,
      {
        globallyForceCloud
      },
      cmdOptions
    );
    return result;
  }
  const accessResult = await checkAccessToSelectedProject(ctx, targetProject);
  if (accessResult.kind === "noAccess") {
    logMessage("You don't have access to the selected project.");
    const result = await handleChooseProject(
      ctx,
      chosenConfiguration,
      {
        globallyForceCloud
      },
      cmdOptions
    );
    return result;
  }
  const selectedDeployment = await loadSelectedDeploymentCredentials(
    ctx,
    {
      kind: "deploymentWithinProject",
      targetProject
    },
    cmdOptions.selectionWithinProject,
    // We'll start running it below
    { ensureLocalRunning: false }
  );
  if (selectedDeployment.deploymentFields !== null && selectedDeployment.deploymentFields.deploymentType === "local") {
    await handleLocalDeployment(ctx, {
      teamSlug: selectedDeployment.deploymentFields.teamSlug,
      projectSlug: selectedDeployment.deploymentFields.projectSlug,
      forceUpgrade: cmdOptions.localOptions.forceUpgrade,
      ports: cmdOptions.localOptions.ports,
      backendVersion: cmdOptions.localOptions.backendVersion
    });
  }
  return {
    url: selectedDeployment.url,
    adminKey: selectedDeployment.adminKey,
    deploymentFields: selectedDeployment.deploymentFields
  };
}
async function handleChooseProject(ctx, chosenConfiguration, args, cmdOptions) {
  await ensureLoggedIn(ctx, {
    overrideAuthUrl: cmdOptions.overrideAuthUrl,
    overrideAuthClient: cmdOptions.overrideAuthClient,
    overrideAuthUsername: cmdOptions.overrideAuthUsername,
    overrideAuthPassword: cmdOptions.overrideAuthPassword
  });
  const project = await selectProject(ctx, chosenConfiguration, {
    team: cmdOptions.team,
    project: cmdOptions.project,
    devDeployment: cmdOptions.devDeployment,
    local: args.globallyForceCloud ? false : cmdOptions.local,
    cloud: args.globallyForceCloud ? true : cmdOptions.cloud
  });
  const deploymentOptions = cmdOptions.selectionWithinProject.kind === "prod" ? { kind: "prod" } : project.devDeployment === "local" ? { kind: "local", ...cmdOptions.localOptions } : { kind: "dev" };
  const {
    deploymentName,
    deploymentUrl: url,
    adminKey
  } = await ensureDeploymentProvisioned(ctx, {
    teamSlug: project.teamSlug,
    projectSlug: project.projectSlug,
    deploymentOptions
  });
  return {
    url,
    adminKey,
    deploymentFields: {
      deploymentName,
      deploymentType: deploymentOptions.kind,
      projectSlug: project.projectSlug,
      teamSlug: project.teamSlug
    }
  };
}
async function handleManuallySetUrlAndAdminKey(ctx, cmdOptions) {
  const { url, siteUrl, adminKey } = cmdOptions;
  const didErase = await eraseDeploymentEnvVar(ctx);
  if (didErase) {
    logMessage(
      chalkStderr.yellowBright(
        `Removed the CONVEX_DEPLOYMENT environment variable from .env.local`
      )
    );
  }
  const envFileConfig = await writeUrlsToEnvFile(ctx, {
    convexUrl: url,
    siteUrl
  });
  if (envFileConfig !== null && (envFileConfig.convexUrlEnvVar || envFileConfig.siteUrlEnvVar)) {
    const updatedVars = [
      envFileConfig.convexUrlEnvVar,
      envFileConfig.siteUrlEnvVar
    ].filter(Boolean).join(" and ");
    logMessage(
      chalkStderr.green(`Saved ${updatedVars} to ${envFileConfig.envFile}`)
    );
  }
  return { url, adminKey };
}
export async function selectProject(ctx, chosenConfiguration, cmdOptions) {
  const choice = chosenConfiguration !== "ask" && chosenConfiguration !== null ? chosenConfiguration : await askToConfigure(ctx);
  switch (choice) {
    case "new":
      return selectNewProject(ctx, chosenConfiguration, cmdOptions);
    case "existing":
      return selectExistingProject(ctx, chosenConfiguration, cmdOptions);
    default:
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "No project selected."
      });
  }
}
const cwd = path.basename(process.cwd());
async function selectNewProject(ctx, chosenConfiguration, config) {
  const { team: selectedTeam, chosen: didChooseBetweenTeams } = await validateOrSelectTeam(ctx, config.team, "Team:");
  let projectName = config.project || cwd;
  let choseProjectInteractively = false;
  if (!config.project) {
    projectName = await promptString(ctx, {
      message: "Project name:",
      default: config.defaultProjectName || cwd
    });
    choseProjectInteractively = true;
  }
  const { devDeployment } = await selectDevDeploymentType(ctx, {
    chosenConfiguration,
    newOrExisting: "new",
    teamSlug: selectedTeam.slug,
    userHasChosenSomethingInteractively: didChooseBetweenTeams || choseProjectInteractively,
    projectSlug: void 0,
    devDeploymentFromFlag: config.devDeployment,
    forceDevDeployment: config.local ? "local" : config.cloud ? "cloud" : void 0
  });
  const region = devDeployment === "cloud" ? await selectRegionOrUseDefault(ctx, selectedTeam) : null;
  showSpinner("Creating new Convex project...");
  const deploymentToProvision = devDeployment === "cloud" ? {
    deploymentType: "dev",
    region
  } : null;
  let projectSlug, teamSlug, projectsRemaining;
  try {
    ({ projectSlug, teamSlug, projectsRemaining } = await createProject(ctx, {
      teamSlug: selectedTeam.slug,
      projectName,
      deploymentToProvision
    }));
  } catch (err) {
    logFailure("Unable to create project.");
    return await logAndHandleFetchError(ctx, err);
  }
  const teamMessage = didChooseBetweenTeams ? " in team " + chalkStderr.bold(teamSlug) : "";
  logFinishedStep(
    `Created project ${chalkStderr.bold(
      projectSlug
    )}${teamMessage}, manage it at ${chalkStderr.bold(
      projectDashboardUrl(teamSlug, projectSlug)
    )}`
  );
  if (projectsRemaining <= 2) {
    logWarning(
      chalkStderr.yellow.bold(
        `Your account now has ${projectsRemaining} project${projectsRemaining === 1 ? "" : "s"} remaining.`
      )
    );
  }
  await doInitConvexFolder(ctx);
  return { teamSlug, projectSlug, devDeployment };
}
async function selectExistingProject(ctx, chosenConfiguration, config) {
  const {
    team: { slug: teamSlug },
    chosen
  } = await validateOrSelectTeam(ctx, config.team, "Team:");
  const projectSlug = await validateOrSelectProject(
    ctx,
    config.project,
    teamSlug,
    "Configure project",
    "Project:"
  );
  if (projectSlug === null) {
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: "Run the command again to create a new project instead."
    });
  }
  const { devDeployment } = await selectDevDeploymentType(ctx, {
    chosenConfiguration,
    newOrExisting: "existing",
    teamSlug,
    projectSlug,
    userHasChosenSomethingInteractively: chosen || !config.project,
    devDeploymentFromFlag: config.devDeployment,
    forceDevDeployment: config.local ? "local" : config.cloud ? "cloud" : void 0
  });
  logFinishedStep(`Reinitialized project ${chalkStderr.bold(projectSlug)}`);
  return { teamSlug, projectSlug, devDeployment };
}
async function askToConfigure(ctx) {
  if (!await hasProjects(ctx)) {
    return "new";
  }
  return await promptOptions(ctx, {
    message: "What would you like to configure?",
    default: "new",
    choices: [
      { name: "create a new project", value: "new" },
      { name: "choose an existing project", value: "existing" }
    ]
  });
}
async function ensureDeploymentProvisioned(ctx, options) {
  switch (options.deploymentOptions.kind) {
    case "dev":
    case "prod": {
      const credentials = await fetchDeploymentCredentialsProvisioningDevOrProdMaybeThrows(
        ctx,
        {
          kind: "teamAndProjectSlugs",
          teamSlug: options.teamSlug,
          projectSlug: options.projectSlug
        },
        options.deploymentOptions.kind
      );
      return {
        ...credentials,
        onActivity: null
      };
    }
    case "local": {
      const credentials = await handleLocalDeployment(ctx, {
        teamSlug: options.teamSlug,
        projectSlug: options.projectSlug,
        ...options.deploymentOptions
      });
      return credentials;
    }
    default:
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: `Invalid deployment type: ${options.deploymentOptions.kind}`,
        errForSentry: `Invalid deployment type: ${options.deploymentOptions.kind}`
      });
  }
}
export async function updateEnvAndConfigForDeploymentSelection(ctx, options, existingValue) {
  const { configPath, projectConfig } = await readProjectConfig(ctx);
  const { wroteToGitIgnore, changedDeploymentEnvVar } = await writeDeploymentEnvVar(
    ctx,
    options.deploymentType,
    {
      team: options.teamSlug,
      project: options.projectSlug,
      deploymentName: options.deploymentName
    },
    existingValue
  );
  await writeProjectConfig(ctx, projectConfig);
  await finalizeConfiguration(ctx, {
    deploymentType: options.deploymentType,
    deploymentName: options.deploymentName,
    url: options.url,
    siteUrl: options.siteUrl,
    wroteToGitIgnore,
    changedDeploymentEnvVar,
    functionsPath: functionsDir(configPath, projectConfig)
  });
}
//# sourceMappingURL=configure.js.map
