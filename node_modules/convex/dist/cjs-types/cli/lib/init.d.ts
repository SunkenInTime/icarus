import { Context } from "../../bundler/context.js";
import { DeploymentType } from "./api.js";
export declare function finalizeConfiguration(ctx: Context, options: {
    functionsPath: string;
    deploymentType: DeploymentType;
    deploymentName: string;
    url: string;
    siteUrl: string | null | undefined;
    wroteToGitIgnore: boolean;
    changedDeploymentEnvVar: boolean;
}): Promise<void>;
//# sourceMappingURL=init.d.ts.map