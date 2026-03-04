import { Context } from "../../../bundler/context.js";
import { components } from "../../generatedApi.js";
export type ProjectEnvironmentSummary = components["schemas"]["ProjectEnvironmentSummary"];
export type ProvisionProjectEnvironmentResponse = components["schemas"]["ProvisionProjectEnvironmentResponse"];
export type GetProjectEnvironmentResponse = components["schemas"]["GetProjectEnvironmentResponse"];
export type DeleteProjectEnvironmentResponse = components["schemas"]["DeleteProjectEnvironmentResponse"];
/**
 * Verified emails for a user that aren't known to be an admin email for
 * another WorkOS integration.
 */
export declare function getCandidateEmailsForWorkIntegration(ctx: Context): Promise<components["schemas"]["AvailableWorkOSTeamEmailsResponse"]>;
export declare function getInvitationEligibleEmails(ctx: Context, teamId: number): Promise<{
    eligibleEmails: string[];
    adminEmail?: string;
}>;
export declare function getDeploymentCanProvisionWorkOSEnvironments(ctx: Context, deploymentName: string): Promise<components["schemas"]["HasAssociatedWorkOSTeamResponse"]>;
export declare function createEnvironmentAndAPIKey(ctx: Context, deploymentName: string, environmentType?: "production" | "nonproduction"): Promise<{
    success: true;
    data: components["schemas"]["ProvisionEnvironmentResponse"];
} | {
    success: false;
    error: "team_not_provisioned";
    message: string;
}>;
export declare function createAssociatedWorkosTeam(ctx: Context, teamId: number, email: string): Promise<{
    result: "success";
    workosTeamId: string;
    workosTeamName: string;
} | {
    result: "emailAlreadyUsed";
    message: string;
}>;
/**
 * Check if the WorkOS team associated with a Convex team is still accessible.
 * Returns the team info if provisioned, or null if not provisioned.
 */
export declare function getWorkosTeamHealth(ctx: Context, teamId: number): Promise<components["schemas"]["WorkOSTeamInfo"] | null>;
/**
 * Check if the WorkOS environment associated with a deployment is still accessible.
 * Returns null if the environment is not provisioned or cannot be accessed.
 */
export declare function getWorkosEnvironmentHealth(ctx: Context, deploymentName: string): Promise<components["schemas"]["WorkOSEnvironmentHealthResponse"] | null>;
export declare function disconnectWorkOSTeam(ctx: Context, teamId: number): Promise<{
    success: true;
    workosTeamId: string;
    workosTeamName: string;
} | {
    success: false;
    error: "not_associated" | "other";
    message: string;
}>;
export declare function inviteToWorkosTeam(ctx: Context, teamId: number, email: string): Promise<{
    result: "success";
    email: string;
    roleSlug: string;
} | {
    result: "teamNotProvisioned";
    message: string;
} | {
    result: "alreadyInWorkspace";
    message: string;
}>;
export declare function listProjectWorkOSEnvironments(ctx: Context, projectId: number): Promise<ProjectEnvironmentSummary[]>;
export declare function createProjectWorkOSEnvironment(ctx: Context, projectId: number, environmentName: string, isProduction?: boolean): Promise<ProvisionProjectEnvironmentResponse>;
export declare function getProjectWorkOSEnvironment(ctx: Context, projectId: number, clientId: string): Promise<GetProjectEnvironmentResponse>;
export declare function deleteProjectWorkOSEnvironment(ctx: Context, projectId: number, clientId: string): Promise<DeleteProjectEnvironmentResponse>;
//# sourceMappingURL=platformApi.d.ts.map