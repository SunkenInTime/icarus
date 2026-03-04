import { Context } from "../../bundler/context.js";
import { TypescriptCompiler } from "./typecheck.js";
import { Bundle, BundleHash } from "../../bundler/index.js";
import { NodeDependency } from "./deployApi/modules.js";
import { ComponentDefinitionPath } from "./components/definition/directoryStructure.js";
import { DeploymentType } from "./api.js";
export { productionProvisionHost, provisionHost } from "./utils/utils.js";
/** Type representing WorkOS AuthKit integration configuration. */
export interface AuthKitConfigureSettings {
    redirectUris?: string[];
    appHomepageUrl?: string;
    corsOrigins?: string[];
}
export interface AuthKitEnvironmentConfig {
    environmentType?: "development" | "staging" | "production";
    configure?: false | AuthKitConfigureSettings;
    localEnvVars?: false | Record<string, string>;
}
export interface AuthKitConfig {
    dev?: AuthKitEnvironmentConfig;
    preview?: AuthKitEnvironmentConfig;
    prod?: AuthKitEnvironmentConfig;
}
/**
 * convex.json file parsing notes
 *
 * - Unknown fields at the top level and in node and codegen are preserved
 *   so that older CLI versions can deploy new projects (this functionality
 *   will be removed in the future).
 * - convex.json does not allow comments, but this could change in the future.
 *   Previously it contained automatically set values like productionUrl
 *   but it's more like a config file now.
 */
/** Type representing Convex project configuration. */
export interface ProjectConfig {
    functions: string;
    node: {
        externalPackages: string[];
        nodeVersion?: string | undefined;
    };
    generateCommonJSApi: boolean;
    codegen: {
        staticApi: boolean;
        staticDataModel: boolean;
        legacyComponentApi?: boolean;
        fileType?: "ts" | "js/dts";
    };
    bundler?: {
        includeSourcesContent?: boolean;
    };
    typescriptCompiler?: TypescriptCompiler;
    authKit?: AuthKitConfig | undefined;
}
export interface Config {
    projectConfig: ProjectConfig;
    modules: Bundle[];
    nodeDependencies: NodeDependency[];
    schemaId?: string;
    udfServerVersion?: string;
    nodeVersion?: string | undefined;
}
export interface ConfigWithModuleHashes {
    projectConfig: ProjectConfig;
    moduleHashes: BundleHash[];
    nodeDependencies: NodeDependency[];
    schemaId?: string;
    udfServerVersion?: string;
}
/** Whether .ts file extensions should be used for generated code (default is false). */
export declare function usesTypeScriptCodegen(projectConfig: ProjectConfig): boolean;
/** Whether the new component API import style should be used (default is false) */
export declare function usesComponentApiImports(projectConfig: ProjectConfig): boolean;
/**
 * Get the authKit configuration from convex.json.
 */
export declare function getAuthKitConfig(ctx: Context, projectConfig: ProjectConfig): Promise<AuthKitConfig | undefined>;
export declare function getAuthKitEnvironmentConfig(ctx: Context, projectConfig: ProjectConfig, deploymentType: "dev" | "preview" | "prod"): Promise<AuthKitEnvironmentConfig | undefined>;
export declare function resetUnknownKeyWarnings(): void;
/** Parse object to ProjectConfig. */
export declare function parseProjectConfig(ctx: Context, obj: any): Promise<ProjectConfig>;
export declare function configName(): string;
export declare function configFilepath(ctx: Context): Promise<string>;
export declare function getFunctionsDirectoryPath(ctx: Context): Promise<string>;
/** Read configuration from a local `convex.json` file. */
export declare function readProjectConfig(ctx: Context): Promise<{
    projectConfig: ProjectConfig;
    configPath: string;
}>;
/**
 * Given a {@link ProjectConfig}, add in the bundled modules to produce the
 * complete config.
 */
export declare function configFromProjectConfig(ctx: Context, projectConfig: ProjectConfig, configPath: string, verbose: boolean): Promise<{
    config: Config;
    bundledModuleInfos: BundledModuleInfo[];
}>;
/**
 * Bundle modules one by one for good bundler errors.
 */
export declare function debugIsolateEndpointBundles(ctx: Context, projectConfig: ProjectConfig, configPath: string): Promise<void>;
/**
 * Read the config from `convex.json` and bundle all the modules.
 */
export declare function readConfig(ctx: Context, verbose: boolean): Promise<{
    config: Config;
    configPath: string;
    bundledModuleInfos: BundledModuleInfo[];
}>;
/**
 * Ensure the functions directory exists.
 *
 * Note: This function no longer writes to or deletes `convex.json`. The config
 * file is now treated as user-owned and is not modified by the CLI. This allows
 * users to maintain their preferred formatting and any comments they may add
 * (if we later support JSONC parsing).
 */
export declare function writeProjectConfig(ctx: Context, projectConfig: ProjectConfig): Promise<void>;
export declare function removedExistingConfig(ctx: Context, configPath: string, options: {
    allowExistingConfig?: boolean;
}): boolean;
/** Pull configuration for the root app component from the given remote origin. */
export declare function pullConfig(ctx: Context, project: string | undefined, team: string | undefined, origin: string, adminKey: string): Promise<ConfigWithModuleHashes>;
interface BundledModuleInfo {
    name: string;
    platform: "node" | "convex";
}
/**
 * A component definition spec contains enough information to create bundles
 * of code that must be analyzed in order to construct a ComponentDefinition.
 *
 * Most paths are relative to the directory of the definitionPath.
 */
export type ComponentDefinitionSpec = {
    /** This path is relative to the app (root component) directory. */
    definitionPath: ComponentDefinitionPath;
    /** Dependencies are paths to the directory of the dependency component definition from the app (root component) directory */
    dependencies: ComponentDefinitionPath[];
    definition: Bundle;
    schema: Bundle;
    functions: Bundle[];
};
export type AppDefinitionSpec = Omit<ComponentDefinitionSpec, "definitionPath"> & {
    auth: Bundle | null;
};
export type ComponentDefinitionSpecWithoutImpls = Omit<ComponentDefinitionSpec, "schema" | "functions">;
export type AppDefinitionSpecWithoutImpls = Omit<AppDefinitionSpec, "schema" | "functions" | "auth">;
/** Generate a human-readable diff between the two configs. */
export declare function diffConfig(oldConfig: ConfigWithModuleHashes, newConfig: Config): {
    diffString: string;
};
/** Handle an error from
 * legacy push path:
 * - /api/push_config
 * modern push paths:
 * - /api/deploy2/evaluate_push
 * - /api/deploy2/start_push
 * - /api/deploy2/finish_push
 *
 * finish_push errors are different from start_push errors and in theory could
 * be handled differently, but starting over works for all of them.
 */
export declare function handlePushConfigError(ctx: Context, error: unknown, defaultMessage: string, deploymentName: string | null, deployment: {
    deploymentUrl: string;
    adminKey: string;
    deploymentNotice: string;
} | undefined, _deploymentType: DeploymentType | undefined): Promise<never>;
//# sourceMappingURL=config.d.ts.map