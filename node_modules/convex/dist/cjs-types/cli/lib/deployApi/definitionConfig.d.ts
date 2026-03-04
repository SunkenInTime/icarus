import { z } from "zod";
export declare const appDefinitionConfig: z.ZodObject<{
    definition: z.ZodNullable<z.ZodObject<{
        path: z.ZodString;
        source: z.ZodString;
        sourceMap: z.ZodOptional<z.ZodString>;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
    }, "passthrough", z.ZodTypeAny, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }>>;
    dependencies: z.ZodArray<z.ZodString, "many">;
    schema: z.ZodNullable<z.ZodObject<{
        path: z.ZodString;
        source: z.ZodString;
        sourceMap: z.ZodOptional<z.ZodString>;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
    }, "passthrough", z.ZodTypeAny, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }>>;
    changedModules: z.ZodArray<z.ZodObject<{
        path: z.ZodString;
        source: z.ZodString;
        sourceMap: z.ZodOptional<z.ZodString>;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
    }, "passthrough", z.ZodTypeAny, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }>, "many">;
    unchangedModuleHashes: z.ZodArray<z.ZodObject<{
        path: z.ZodString;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
        sha256: z.ZodString;
    }, "passthrough", z.ZodTypeAny, {
        sha256: string;
        path: string;
        environment: "node" | "isolate";
    }, {
        sha256: string;
        path: string;
        environment: "node" | "isolate";
    }>, "many">;
    udfServerVersion: z.ZodString;
}, "passthrough", z.ZodTypeAny, {
    definition: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    } | null;
    dependencies: string[];
    schema: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    } | null;
    changedModules: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }[];
    unchangedModuleHashes: {
        sha256: string;
        path: string;
        environment: "node" | "isolate";
    }[];
    udfServerVersion: string;
}, {
    definition: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    } | null;
    dependencies: string[];
    schema: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    } | null;
    changedModules: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }[];
    unchangedModuleHashes: {
        sha256: string;
        path: string;
        environment: "node" | "isolate";
    }[];
    udfServerVersion: string;
}>;
export type AppDefinitionConfig = z.infer<typeof appDefinitionConfig>;
export declare const componentDefinitionConfig: z.ZodObject<{
    definitionPath: z.ZodString;
    definition: z.ZodObject<{
        path: z.ZodString;
        source: z.ZodString;
        sourceMap: z.ZodOptional<z.ZodString>;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
    }, "passthrough", z.ZodTypeAny, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }>;
    dependencies: z.ZodArray<z.ZodString, "many">;
    schema: z.ZodNullable<z.ZodObject<{
        path: z.ZodString;
        source: z.ZodString;
        sourceMap: z.ZodOptional<z.ZodString>;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
    }, "passthrough", z.ZodTypeAny, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }>>;
    functions: z.ZodArray<z.ZodObject<{
        path: z.ZodString;
        source: z.ZodString;
        sourceMap: z.ZodOptional<z.ZodString>;
        environment: z.ZodUnion<[z.ZodLiteral<"isolate">, z.ZodLiteral<"node">]>;
    }, "passthrough", z.ZodTypeAny, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }, {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }>, "many">;
    udfServerVersion: z.ZodString;
}, "passthrough", z.ZodTypeAny, {
    definition: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    };
    dependencies: string[];
    schema: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    } | null;
    functions: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }[];
    definitionPath: string;
    udfServerVersion: string;
}, {
    definition: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    };
    dependencies: string[];
    schema: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    } | null;
    functions: {
        path: string;
        source: string;
        environment: "node" | "isolate";
        sourceMap?: string | undefined;
    }[];
    definitionPath: string;
    udfServerVersion: string;
}>;
export type ComponentDefinitionConfig = z.infer<typeof componentDefinitionConfig>;
//# sourceMappingURL=definitionConfig.d.ts.map