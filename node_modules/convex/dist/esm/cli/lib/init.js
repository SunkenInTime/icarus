"use strict";
import { chalkStderr } from "chalk";
import { logFinishedStep, logMessage } from "../../bundler/log.js";
import { writeUrlsToEnvFile } from "./envvars.js";
import { getDashboardUrl } from "./dashboard.js";
export async function finalizeConfiguration(ctx, options) {
  const envFileConfig = await writeUrlsToEnvFile(ctx, {
    convexUrl: options.url,
    siteUrl: options.siteUrl
  });
  const isEnvFileConfigChanged = envFileConfig !== null && (envFileConfig.convexUrlEnvVar || envFileConfig.siteUrlEnvVar);
  if (isEnvFileConfigChanged) {
    const urlUpdateMessages = [];
    if (envFileConfig.convexUrlEnvVar) {
      urlUpdateMessages.push(
        `    client URL as ${envFileConfig.convexUrlEnvVar}
`
      );
    }
    if (envFileConfig.siteUrlEnvVar) {
      urlUpdateMessages.push(
        `    HTTP actions URL as ${envFileConfig.siteUrlEnvVar}
`
      );
    }
    logFinishedStep(
      `${messageForDeploymentType(options.deploymentType, options.url)} and saved its:
    name as CONVEX_DEPLOYMENT
` + urlUpdateMessages.join("") + ` to ${envFileConfig.envFile}`
    );
  } else if (options.changedDeploymentEnvVar) {
    logFinishedStep(
      `${messageForDeploymentType(options.deploymentType, options.url)} and saved its name as CONVEX_DEPLOYMENT to .env.local`
    );
  }
  if (options.wroteToGitIgnore) {
    logMessage(chalkStderr.gray(`  Added ".env.local" to .gitignore`));
  }
  if (options.deploymentType === "anonymous") {
    logMessage(
      `Run \`npx convex login\` at any time to create an account and link this deployment.`
    );
  }
  const anyChanges = options.wroteToGitIgnore || options.changedDeploymentEnvVar || isEnvFileConfigChanged;
  if (anyChanges) {
    const dashboardUrl = await getDashboardUrl(ctx, {
      deploymentName: options.deploymentName,
      deploymentType: options.deploymentType
    });
    logMessage(
      `
Write your Convex functions in ${chalkStderr.bold(options.functionsPath)}
Give us feedback at https://convex.dev/community or support@convex.dev
View the Convex dashboard at ${dashboardUrl}
`
    );
  }
}
function messageForDeploymentType(deploymentType, url) {
  switch (deploymentType) {
    case "anonymous":
      return `Started running a deployment locally at ${url}`;
    case "local":
      return `Started running a deployment locally at ${url}`;
    case "dev":
    case "prod":
    case "preview":
    case "custom":
      return `Provisioned a ${deploymentType} deployment`;
    default: {
      deploymentType;
      return `Provisioned a ${deploymentType} deployment`;
    }
  }
}
//# sourceMappingURL=init.js.map
