import { Context } from "../../bundler/context.js";
declare const _FRAMEWORKS: readonly ["create-react-app", "Next.js", "Vite", "Remix", "SvelteKit", "Expo", "TanStackStart"];
type Framework = (typeof _FRAMEWORKS)[number];
/**
 * A configuration for writing the actual (framework specific) `CONVEX_URL`
 * and `CONVEX_SITE_URL` environment variables to a ".env" type file.
 *
 * May be `null` if there was an error determining any of the field values.
 */
type EnvFileUrlConfig = {
    /** The name of the file - typically `.env.local` */
    envFile: string;
    /**
     * The framework specific `CONVEX_URL`
     *
     * If `null`, ignore and don't update that environment variable.
     */
    convexUrlEnvVar: string | null;
    /**
     * The framework specific `CONVEX_SITE_URL`
     *
     * If `null`, ignore and don't update that environment variable.
     */
    siteUrlEnvVar: string | null;
    /** Existing content loaded from the `envFile`, if it exists */
    existingFileContent: string | null;
} | null;
export declare function writeUrlsToEnvFile(ctx: Context, options: {
    convexUrl: string;
    siteUrl?: string | null | undefined;
}): Promise<EnvFileUrlConfig>;
export declare function changedEnvVarFile({ existingFileContent, envVarName, envVarValue, commentAfterValue, commentOnPreviousLine, }: {
    existingFileContent: string | null;
    envVarName: string;
    envVarValue: string;
    commentAfterValue: string | null;
    commentOnPreviousLine: string | null;
}): string | null;
export declare function getEnvVarRegex(envVarName: string): RegExp;
export declare function suggestedEnvVarNames(ctx: Context): Promise<{
    detectedFramework?: Framework;
    convexUrlEnvVar: ConvexUrlEnvVar;
    convexSiteEnvVar: ConvexSiteUrlEnvVar;
    frontendDevUrl?: string;
    publicPrefix?: string;
}>;
declare const EXPECTED_CONVEX_URL_NAMES: Set<"CONVEX_URL" | "PUBLIC_CONVEX_URL" | "NEXT_PUBLIC_CONVEX_URL" | "VITE_CONVEX_URL" | "REACT_APP_CONVEX_URL" | "EXPO_PUBLIC_CONVEX_URL">;
type ConvexUrlEnvVar = typeof EXPECTED_CONVEX_URL_NAMES extends Set<infer T> ? T : never;
declare const EXPECTED_SITE_URL_NAMES: Set<"CONVEX_SITE_URL" | "PUBLIC_CONVEX_SITE_URL" | "NEXT_PUBLIC_CONVEX_SITE_URL" | "VITE_CONVEX_SITE_URL" | "REACT_APP_CONVEX_SITE_URL" | "EXPO_PUBLIC_CONVEX_SITE_URL">;
type ConvexSiteUrlEnvVar = typeof EXPECTED_SITE_URL_NAMES extends Set<infer T> ? T : never;
export declare function detectSuspiciousEnvironmentVariables(ctx: Context, ignoreSuspiciousEnvVars?: boolean): Promise<undefined>;
export declare function getBuildEnvironment(): string | false;
export declare function gitBranchFromEnvironment(): string | null;
export declare function isNonProdBuildEnvironment(): boolean;
export {};
//# sourceMappingURL=envvars.d.ts.map