import { Context } from "../../../bundler/context.js";
/**
 * Ensure the `.convex/.gitignore` file exists with the right content.
 * This prevents local deployment state from being committed to git.
 */
export declare function ensureDotConvexGitignore(ctx: Context, projectDir?: string): void;
export type LocalDeploymentKind = "local" | "anonymous";
export declare function rootDeploymentStateDir(kind: LocalDeploymentKind): string;
/**
 * Get the project-local state directory for a deployment.
 * Always returns `.convex/local/default/` - one deployment per project.
 */
export declare function projectLocalStateDir(projectDir?: string): string;
/**
 * Get the legacy home directory state path for a deployment.
 */
export declare function legacyDeploymentStateDir(deploymentKind: LocalDeploymentKind, deploymentName: string): string;
/**
 * Get the state directory for a deployment.
 *
 * Priority order:
 * 1. Project-local directory if it has data (config.json exists)
 * 2. Legacy home directory if it exists (backward compatibility)
 * 3. Project-local directory for new deployments
 *
 * This ensures that when project-local storage is in use, it takes precedence
 * over any legacy directories that might exist with the same deployment name.
 */
export declare function deploymentStateDir(ctx: Context, deploymentKind: LocalDeploymentKind, deploymentName: string, projectDir?: string): string;
/**
 * Get the state directory for a deployment without checking for legacy data.
 * This always returns the project-local path.
 */
export declare function deploymentStateDirUnchecked(projectDir?: string): string;
export type LocalDeploymentConfig = {
    ports: {
        cloud: number;
        site: number;
    };
    backendVersion: string;
    adminKey: string;
    instanceSecret?: string;
    deploymentName?: string;
};
/**
 * Load deployment config from a specific directory.
 * This is used when we already know the directory path.
 */
export declare function loadDeploymentConfigFromDir(ctx: Context, dir: string): LocalDeploymentConfig | null;
/**
 * Load the project-local deployment config.
 * This returns the config from `.convex/local/default/` if it exists.
 * Returns both the config and the deployment name stored in it.
 */
export declare function loadProjectLocalConfig(ctx: Context, projectDir?: string): {
    deploymentName: string;
    config: LocalDeploymentConfig;
} | null;
/**
 * Load deployment config for a deployment.
 *
 * Priority order (matching deploymentStateDir):
 * 1. Project-local directory if it has a matching config
 * 2. Legacy home directory
 */
export declare function loadDeploymentConfig(ctx: Context, deploymentKind: LocalDeploymentKind, deploymentName: string, projectDir?: string): LocalDeploymentConfig | null;
/**
 * Save deployment config.
 *
 * If data already exists in the legacy home directory, continue using that
 * location. Otherwise, use the project-local directory. The deployment name
 * is always stored in the config for project-local storage.
 */
export declare function saveDeploymentConfig(ctx: Context, deploymentKind: LocalDeploymentKind, deploymentName: string, config: LocalDeploymentConfig, projectDir?: string): void;
export declare function binariesDir(): string;
export declare function dashboardZip(): string;
export declare function versionedBinaryDir(version: string): string;
export declare function executablePath(version: string): string;
export declare function executableName(): string;
export declare function dashboardDir(): string;
export declare function resetDashboardDir(ctx: Context): Promise<void>;
export declare function dashboardOutDir(): string;
export type DashboardConfig = {
    port: number;
    apiPort: number;
    version: string;
};
export declare function loadDashboardConfig(ctx: Context): any;
export declare function saveDashboardConfig(ctx: Context, config: DashboardConfig): void;
export declare function loadUuidForAnonymousUser(ctx: Context): any;
export declare function ensureUuidForAnonymousUser(ctx: Context): any;
//# sourceMappingURL=filePaths.d.ts.map