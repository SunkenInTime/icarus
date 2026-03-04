import { Context } from "../../../bundler/context.js";
import type { AuthKitConfig, ProjectConfig } from "../config.js";
/**
 * Ensure the current deployment has the three expected WorkOS environment
 * variables defined with values corresponding to a valid WorkOS deployment.
 *
 * This may involve provisioning a WorkOS deployment or even (in interactive
 * terminals only) prompting to provision a new WorkOS team to be associated
 * with this Convex team.
 */
export declare function ensureWorkosEnvironmentProvisioned(ctx: Context, deploymentName: string, deployment: {
    deploymentUrl: string;
    adminKey: string;
    deploymentNotice: string;
}, authKitConfig: AuthKitConfig | undefined, deploymentType: "dev" | "preview" | "prod"): Promise<"ready" | "choseNotToAssociatedTeam">;
/**
 * Interactive flow to provision a WorkOS team for a Convex team.
 * Handles ToS agreement, email selection, and retry logic.
 */
export declare function provisionWorkosTeamInteractive(ctx: Context, deploymentName: string, teamId: number, deploymentType: "dev" | "preview" | "prod", options?: {
    promptPrefix?: string;
    promptMessage?: string;
}): Promise<{
    success: true;
    workosTeamId: string;
    workosTeamName: string;
} | {
    success: false;
    reason: "cancelled";
}>;
export declare function tryToCreateAssociatedWorkosTeam(ctx: Context, deploymentName: string, teamId: number, deploymentType: "dev" | "preview" | "prod"): Promise<"ready" | "choseNotToAssociatedTeam">;
/**
 * Pre-flight check for AuthKit provisioning.
 * Called before building the client bundle to ensure .env.local has correct values.
 * This is the main provisioning path - the error path is kept for backwards compatibility.
 */
/**
 * Ensures WorkOS AuthKit environment is ready before building.
 *
 * Flow:
 * 1. Get authKit configuration for the deployment type
 * 2. Resolve credentials (build env → deployment env → provision via Big Brain)
 * 3. Ensure deployment has the correct credentials
 * 4. Update local .env.local if configured (interactive only)
 * 5. Configure WorkOS environment settings if needed
 */
export declare function ensureAuthKitProvisionedBeforeBuild(ctx: Context, deploymentName: string, deployment: {
    deploymentUrl: string;
    adminKey: string;
}, deploymentType?: "dev" | "preview" | "prod"): Promise<void>;
/**
 * Syncs WorkOS configuration and local env vars after a successful push.
 * This is called on every push in dev mode to keep WorkOS settings in sync
 * with changes to convex.json.
 *
 * @returns true if any updates were made, false if config unchanged
 */
export declare function syncAuthKitConfigAfterPush(ctx: Context, projectConfig: ProjectConfig, deployment: {
    deploymentUrl: string;
    adminKey: string;
}): Promise<boolean>;
export declare function resolveTemplate(str: string, provisioned?: {
    clientId?: string;
    apiKey?: string;
    environmentId?: string;
}): string;
//# sourceMappingURL=workos.d.ts.map