import { z } from "zod";
import { ConvexTool } from "./index.js";
declare const inputSchema: z.ZodObject<{
    projectDir: z.ZodOptional<z.ZodString>;
}, "strip", z.ZodTypeAny, {
    projectDir?: string | undefined;
}, {
    projectDir?: string | undefined;
}>;
declare const outputSchema: z.ZodObject<{
    availableDeployments: z.ZodArray<z.ZodObject<{
        kind: z.ZodString;
        deploymentSelector: z.ZodString;
        url: z.ZodString;
        dashboardUrl: z.ZodOptional<z.ZodString>;
        readOnly: z.ZodOptional<z.ZodBoolean>;
    }, "strip", z.ZodTypeAny, {
        kind: string;
        url: string;
        deploymentSelector: string;
        readOnly?: boolean | undefined;
        dashboardUrl?: string | undefined;
    }, {
        kind: string;
        url: string;
        deploymentSelector: string;
        readOnly?: boolean | undefined;
        dashboardUrl?: string | undefined;
    }>, "many">;
}, "strip", z.ZodTypeAny, {
    availableDeployments: {
        kind: string;
        url: string;
        deploymentSelector: string;
        readOnly?: boolean | undefined;
        dashboardUrl?: string | undefined;
    }[];
}, {
    availableDeployments: {
        kind: string;
        url: string;
        deploymentSelector: string;
        readOnly?: boolean | undefined;
        dashboardUrl?: string | undefined;
    }[];
}>;
export declare const StatusTool: ConvexTool<typeof inputSchema, typeof outputSchema>;
export {};
//# sourceMappingURL=status.d.ts.map