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
var platformApi_exports = {};
__export(platformApi_exports, {
  createAssociatedWorkosTeam: () => createAssociatedWorkosTeam,
  createEnvironmentAndAPIKey: () => createEnvironmentAndAPIKey,
  createProjectWorkOSEnvironment: () => createProjectWorkOSEnvironment,
  deleteProjectWorkOSEnvironment: () => deleteProjectWorkOSEnvironment,
  disconnectWorkOSTeam: () => disconnectWorkOSTeam,
  getCandidateEmailsForWorkIntegration: () => getCandidateEmailsForWorkIntegration,
  getDeploymentCanProvisionWorkOSEnvironments: () => getDeploymentCanProvisionWorkOSEnvironments,
  getInvitationEligibleEmails: () => getInvitationEligibleEmails,
  getProjectWorkOSEnvironment: () => getProjectWorkOSEnvironment,
  getWorkosEnvironmentHealth: () => getWorkosEnvironmentHealth,
  getWorkosTeamHealth: () => getWorkosTeamHealth,
  inviteToWorkosTeam: () => inviteToWorkosTeam,
  listProjectWorkOSEnvironments: () => listProjectWorkOSEnvironments
});
module.exports = __toCommonJS(platformApi_exports);
var import_utils = require("../utils/utils.js");
async function getCandidateEmailsForWorkIntegration(ctx) {
  return (0, import_utils.bigBrainAPI)({
    ctx,
    method: "GET",
    url: "workos/available_workos_team_emails"
  });
}
async function getInvitationEligibleEmails(ctx, teamId) {
  return (0, import_utils.bigBrainAPI)({
    ctx,
    method: "GET",
    url: `teams/${teamId}/workos_invitation_eligible_emails`
  });
}
async function getDeploymentCanProvisionWorkOSEnvironments(ctx, deploymentName) {
  const request = {
    deploymentName
  };
  return (0, import_utils.bigBrainAPI)({
    ctx,
    method: "POST",
    url: "workos/has_associated_workos_team",
    data: request
  });
}
async function createEnvironmentAndAPIKey(ctx, deploymentName, environmentType) {
  try {
    const data = await (0, import_utils.bigBrainAPI)({
      ctx,
      method: "POST",
      url: "workos/get_or_provision_workos_environment",
      data: {
        deploymentName,
        environmentType
      }
    });
    return {
      success: true,
      data
    };
  } catch (error) {
    if (error?.message?.includes("WorkOSTeamNotProvisioned")) {
      return {
        success: false,
        error: "team_not_provisioned",
        message: error.message
      };
    }
    return await ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Error provisioning WorkOS environment: ${error}`
    });
  }
}
async function createAssociatedWorkosTeam(ctx, teamId, email) {
  try {
    const request = {
      teamId,
      email
    };
    const result = await (0, import_utils.bigBrainAPIMaybeThrows)({
      ctx,
      method: "POST",
      url: "workos/provision_associated_workos_team",
      data: JSON.stringify(request)
    });
    return {
      result: "success",
      ...result
    };
  } catch (error) {
    const data = error instanceof import_utils.ThrowingFetchError ? error.serverErrorData : void 0;
    if (data?.code === "WorkosAccountAlreadyExistsWithThisEmail") {
      return {
        result: "emailAlreadyUsed",
        message: data?.message || "WorkOS account with this email already exists"
      };
    }
    return await (0, import_utils.logAndHandleFetchError)(ctx, error);
  }
}
async function getWorkosTeamHealth(ctx, teamId) {
  const response = await (0, import_utils.bigBrainAPI)({
    ctx,
    method: "GET",
    url: `teams/${teamId}/workos_team_health`
  });
  return response.teamProvisioned ? response.teamInfo ?? null : null;
}
async function getWorkosEnvironmentHealth(ctx, deploymentName) {
  try {
    return await (0, import_utils.bigBrainAPIMaybeThrows)({
      ctx,
      method: "GET",
      url: `deployments/${deploymentName}/workos_environment_health`
    });
  } catch (error) {
    if (error?.serverErrorData?.code === "WorkOSEnvironmentNotProvisioned") {
      return null;
    }
    return await (0, import_utils.logAndHandleFetchError)(ctx, error);
  }
}
async function disconnectWorkOSTeam(ctx, teamId) {
  try {
    const request = {
      teamId
    };
    const result = await (0, import_utils.bigBrainAPIMaybeThrows)({
      ctx,
      method: "POST",
      url: "workos/disconnect_workos_team",
      data: JSON.stringify(request)
    });
    return {
      success: true,
      ...result
    };
  } catch (error) {
    const data = error instanceof import_utils.ThrowingFetchError ? error.serverErrorData : void 0;
    if (data?.code === "WorkOSTeamNotAssociated") {
      return {
        success: false,
        error: "not_associated",
        message: data?.message || "No WorkOS team is associated"
      };
    }
    return {
      success: false,
      error: "other",
      message: data?.message || (error instanceof Error ? error.message : String(error))
    };
  }
}
async function inviteToWorkosTeam(ctx, teamId, email) {
  try {
    const result = await (0, import_utils.bigBrainAPIMaybeThrows)({
      ctx,
      method: "POST",
      url: "workos/invite_team_member",
      data: JSON.stringify({ teamId, email })
    });
    return { result: "success", ...result };
  } catch (error) {
    const data = error instanceof import_utils.ThrowingFetchError ? error.serverErrorData : void 0;
    if (data?.code === "WorkOSTeamNotProvisioned") {
      return {
        result: "teamNotProvisioned",
        message: data?.message || "This team doesn't have a WorkOS team yet"
      };
    }
    if (data?.code === "WorkosUserAlreadyInWorkspace") {
      return {
        result: "alreadyInWorkspace",
        message: data?.message || "This email is already a member of another WorkOS workspace"
      };
    }
    if (data?.code === "WorkosUserAlreadyInvited") {
      return {
        result: "alreadyInWorkspace",
        // Reuse same result type for UI consistency
        message: data?.message || "This email has already been invited to the WorkOS team"
      };
    }
    if (data?.code === "WorkosUserAlreadyInThisTeam") {
      return {
        result: "alreadyInWorkspace",
        message: data?.message || "This email is already a member of this WorkOS team"
      };
    }
    return await (0, import_utils.logAndHandleFetchError)(ctx, error);
  }
}
async function listProjectWorkOSEnvironments(ctx, projectId) {
  const response = await (0, import_utils.bigBrainAPI)({
    ctx,
    method: "GET",
    url: `projects/${projectId}/workos_environments`
  });
  return response.environments;
}
async function createProjectWorkOSEnvironment(ctx, projectId, environmentName, isProduction) {
  return (0, import_utils.bigBrainAPI)({
    ctx,
    method: "POST",
    url: `projects/${projectId}/workos_environments`,
    data: { environmentName, isProduction }
  });
}
async function getProjectWorkOSEnvironment(ctx, projectId, clientId) {
  return (0, import_utils.bigBrainAPI)({
    ctx,
    method: "GET",
    url: `projects/${projectId}/workos_environments/${clientId}`
  });
}
async function deleteProjectWorkOSEnvironment(ctx, projectId, clientId) {
  return (0, import_utils.bigBrainAPI)({
    ctx,
    method: "POST",
    url: "workos/delete_project_environment",
    data: { projectId, clientId }
  });
}
//# sourceMappingURL=platformApi.js.map
