import { Context } from "../../bundler/context.js";
export declare const ROOT_COMPONENT_PATH = "-root-component-";
export declare const INSIGHTS_QUERY_ID = "9ab3b74e-a725-480b-88a6-43e6bd70bd82";
export type OccRecentEvent = {
    timestamp: string;
    id: string;
    request_id: string;
    occ_document_id?: string;
    occ_write_source?: string;
    occ_retry_count: number;
};
export type ResourceRecentEvent = {
    timestamp: string;
    id: string;
    request_id: string;
    calls: {
        table_name: string;
        bytes_read: number;
        documents_read: number;
    }[];
    success: boolean;
};
export type OccInsight = {
    kind: "occRetried" | "occFailedPermanently";
    severity: "error" | "warning";
    functionId: string;
    componentPath: string | null;
    occCalls: number;
    occTableName?: string | undefined;
    recentEvents?: OccRecentEvent[] | undefined;
};
export type ResourceInsight = {
    kind: "bytesReadLimit" | "bytesReadThreshold" | "documentsReadLimit" | "documentsReadThreshold";
    severity: "error" | "warning";
    functionId: string;
    componentPath: string | null;
    count: number;
    recentEvents?: ResourceRecentEvent[] | undefined;
};
export type Insight = OccInsight | ResourceInsight;
export declare function orderForKind(kind: string): number;
export declare function severityForKind(kind: string): "error" | "warning" | undefined;
/**
 * Fetch raw insight rows from the Big Brain usage API.
 * Returns the raw string[][] from the API response.
 */
export declare function fetchRawInsightsData(ctx: Context, deploymentName: string): Promise<string[][]>;
/**
 * Fetch and parse insights from the Big Brain usage API for a deployment.
 * Returns insights sorted by severity (errors first).
 *
 * Pass `includeRecentEvents: true` to include up to 5 recent events per insight.
 */
export declare function fetchInsights(ctx: Context, deploymentName: string, options?: {
    includeRecentEvents?: boolean;
}): Promise<Insight[]>;
//# sourceMappingURL=insights.d.ts.map