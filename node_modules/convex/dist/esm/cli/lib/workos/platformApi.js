"use strict";
import {
  bigBrainAPI,
  bigBrainAPIMaybeThrows,
  logAndHandleFetchError,
  ThrowingFetchError
} from "../utils/utils.js";
export async function getCandidateEmailsForWorkIntegration(ctx) {
  return bigBrainAPI({
    ctx,
    method: "GET",
    url: "workos/available_workos_team_emails"
  });
}
export async function getInvitationEligibleEmails(ctx, teamId) {
  return bigBrainAPI({
    ctx,
    method: "GET",
    url: `teams/${teamId}/workos_invitation_eligible_emails`
  });
}
export async function getDeploymentCanProvisionWorkOSEnvironments(ctx, deploymentName) {
  const request = {
    deploymentName
  };
  return bigBrainAPI({
    ctx,
    method: "POST",
    url: "workos/has_associated_workos_team",
    data: request
  });
}
export async function createEnvironmentAndAPIKey(ctx, deploymentName, environmentType) {
  try {
    const data = await bigBrainAPI({
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
export async function createAssociatedWorkosTeam(ctx, teamId, email) {
  try {
    const request = {
      teamId,
      email
    };
    const result = await bigBrainAPIMaybeThrows({
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
    const data = error instanceof ThrowingFetchError ? error.serverErrorData : void 0;
    if (data?.code === "WorkosAccountAlreadyExistsWithThisEmail") {
      return {
        result: "emailAlreadyUsed",
        message: data?.message || "WorkOS account with this email already exists"
      };
    }
    return await logAndHandleFetchError(ctx, error);
  }
}
export async function getWorkosTeamHealth(ctx, teamId) {
  const response = await bigBrainAPI({
    ctx,
    method: "GET",
    url: `teams/${teamId}/workos_team_health`
  });
  return response.teamProvisioned ? response.teamInfo ?? null : null;
}
export async function getWorkosEnvironmentHealth(ctx, deploymentName) {
  try {
    return await bigBrainAPIMaybeThrows({
      ctx,
      method: "GET",
      url: `deployments/${deploymentName}/workos_environment_health`
    });
  } catch (error) {
    if (error?.serverErrorData?.code === "WorkOSEnvironmentNotProvisioned") {
      return null;
    }
    return await logAndHandleFetchError(ctx, error);
  }
}
export async function disconnectWorkOSTeam(ctx, teamId) {
  try {
    const request = {
      teamId
    };
    const result = await bigBrainAPIMaybeThrows({
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
    const data = error instanceof ThrowingFetchError ? error.serverErrorData : void 0;
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
export async function inviteToWorkosTeam(ctx, teamId, email) {
  try {
    const result = await bigBrainAPIMaybeThrows({
      ctx,
      method: "POST",
      url: "workos/invite_team_member",
      data: JSON.stringify({ teamId, email })
    });
    return { result: "success", ...result };
  } catch (error) {
    const data = error instanceof ThrowingFetchError ? error.serverErrorData : void 0;
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
    return await logAndHandleFetchError(ctx, error);
  }
}
export async function listProjectWorkOSEnvironments(ctx, projectId) {
  const response = await bigBrainAPI({
    ctx,
    method: "GET",
    url: `projects/${projectId}/workos_environments`
  });
  return response.environments;
}
export async function createProjectWorkOSEnvironment(ctx, projectId, environmentName, isProduction) {
  return bigBrainAPI({
    ctx,
    method: "POST",
    url: `projects/${projectId}/workos_environments`,
    data: { environmentName, isProduction }
  });
}
export async function getProjectWorkOSEnvironment(ctx, projectId, clientId) {
  return bigBrainAPI({
    ctx,
    method: "GET",
    url: `projects/${projectId}/workos_environments/${clientId}`
  });
}
export async function deleteProjectWorkOSEnvironment(ctx, projectId, clientId) {
  return bigBrainAPI({
    ctx,
    method: "POST",
    url: "workos/delete_project_environment",
    data: { projectId, clientId }
  });
}
//# sourceMappingURL=platformApi.js.map
