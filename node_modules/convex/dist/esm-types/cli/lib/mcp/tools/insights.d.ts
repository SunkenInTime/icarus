import { z } from "zod";
import { ConvexTool } from "./index.js";
declare const inputSchema: z.ZodObject<{
    deploymentSelector: z.ZodString;
}, "strip", z.ZodTypeAny, {
    deploymentSelector: string;
}, {
    deploymentSelector: string;
}>;
declare const outputSchema: z.ZodObject<{
    insights: z.ZodArray<z.ZodDiscriminatedUnion<"kind", [z.ZodObject<{
        kind: z.ZodLiteral<"occRetried">;
        severity: z.ZodLiteral<"warning">;
        functionId: z.ZodString;
        componentPath: z.ZodNullable<z.ZodString>;
        occCalls: z.ZodNumber;
        occTableName: z.ZodOptional<z.ZodString>;
        recentEvents: z.ZodArray<z.ZodObject<{
            timestamp: z.ZodString;
            id: z.ZodString;
            request_id: z.ZodString;
            occ_document_id: z.ZodOptional<z.ZodString>;
            occ_write_source: z.ZodOptional<z.ZodString>;
            occ_retry_count: z.ZodNumber;
        }, "strip", z.ZodTypeAny, {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }, {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }>, "many">;
    }, "strip", z.ZodTypeAny, {
        kind: "occRetried";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "warning";
        occTableName?: string | undefined;
    }, {
        kind: "occRetried";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "warning";
        occTableName?: string | undefined;
    }>, z.ZodObject<{
        kind: z.ZodLiteral<"occFailedPermanently">;
        severity: z.ZodLiteral<"error">;
        functionId: z.ZodString;
        componentPath: z.ZodNullable<z.ZodString>;
        occCalls: z.ZodNumber;
        occTableName: z.ZodOptional<z.ZodString>;
        recentEvents: z.ZodArray<z.ZodObject<{
            timestamp: z.ZodString;
            id: z.ZodString;
            request_id: z.ZodString;
            occ_document_id: z.ZodOptional<z.ZodString>;
            occ_write_source: z.ZodOptional<z.ZodString>;
            occ_retry_count: z.ZodNumber;
        }, "strip", z.ZodTypeAny, {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }, {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }>, "many">;
    }, "strip", z.ZodTypeAny, {
        kind: "occFailedPermanently";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "error";
        occTableName?: string | undefined;
    }, {
        kind: "occFailedPermanently";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "error";
        occTableName?: string | undefined;
    }>, z.ZodObject<{
        kind: z.ZodLiteral<"bytesReadLimit">;
        severity: z.ZodLiteral<"error">;
        functionId: z.ZodString;
        componentPath: z.ZodNullable<z.ZodString>;
        count: z.ZodNumber;
        recentEvents: z.ZodArray<z.ZodObject<{
            timestamp: z.ZodString;
            id: z.ZodString;
            request_id: z.ZodString;
            calls: z.ZodArray<z.ZodObject<{
                table_name: z.ZodString;
                bytes_read: z.ZodNumber;
                documents_read: z.ZodNumber;
            }, "strip", z.ZodTypeAny, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }>, "many">;
            success: z.ZodBoolean;
        }, "strip", z.ZodTypeAny, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }>, "many">;
    }, "strip", z.ZodTypeAny, {
        kind: "bytesReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    }, {
        kind: "bytesReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    }>, z.ZodObject<{
        kind: z.ZodLiteral<"bytesReadThreshold">;
        severity: z.ZodLiteral<"warning">;
        functionId: z.ZodString;
        componentPath: z.ZodNullable<z.ZodString>;
        count: z.ZodNumber;
        recentEvents: z.ZodArray<z.ZodObject<{
            timestamp: z.ZodString;
            id: z.ZodString;
            request_id: z.ZodString;
            calls: z.ZodArray<z.ZodObject<{
                table_name: z.ZodString;
                bytes_read: z.ZodNumber;
                documents_read: z.ZodNumber;
            }, "strip", z.ZodTypeAny, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }>, "many">;
            success: z.ZodBoolean;
        }, "strip", z.ZodTypeAny, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }>, "many">;
    }, "strip", z.ZodTypeAny, {
        kind: "bytesReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    }, {
        kind: "bytesReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    }>, z.ZodObject<{
        kind: z.ZodLiteral<"documentsReadLimit">;
        severity: z.ZodLiteral<"error">;
        functionId: z.ZodString;
        componentPath: z.ZodNullable<z.ZodString>;
        count: z.ZodNumber;
        recentEvents: z.ZodArray<z.ZodObject<{
            timestamp: z.ZodString;
            id: z.ZodString;
            request_id: z.ZodString;
            calls: z.ZodArray<z.ZodObject<{
                table_name: z.ZodString;
                bytes_read: z.ZodNumber;
                documents_read: z.ZodNumber;
            }, "strip", z.ZodTypeAny, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }>, "many">;
            success: z.ZodBoolean;
        }, "strip", z.ZodTypeAny, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }>, "many">;
    }, "strip", z.ZodTypeAny, {
        kind: "documentsReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    }, {
        kind: "documentsReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    }>, z.ZodObject<{
        kind: z.ZodLiteral<"documentsReadThreshold">;
        severity: z.ZodLiteral<"warning">;
        functionId: z.ZodString;
        componentPath: z.ZodNullable<z.ZodString>;
        count: z.ZodNumber;
        recentEvents: z.ZodArray<z.ZodObject<{
            timestamp: z.ZodString;
            id: z.ZodString;
            request_id: z.ZodString;
            calls: z.ZodArray<z.ZodObject<{
                table_name: z.ZodString;
                bytes_read: z.ZodNumber;
                documents_read: z.ZodNumber;
            }, "strip", z.ZodTypeAny, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }, {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }>, "many">;
            success: z.ZodBoolean;
        }, "strip", z.ZodTypeAny, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }, {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }>, "many">;
    }, "strip", z.ZodTypeAny, {
        kind: "documentsReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    }, {
        kind: "documentsReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    }>]>, "many">;
    summary: z.ZodString;
    dashboardUrl: z.ZodString;
}, "strip", z.ZodTypeAny, {
    summary: string;
    dashboardUrl: string;
    insights: ({
        kind: "occRetried";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "warning";
        occTableName?: string | undefined;
    } | {
        kind: "occFailedPermanently";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "error";
        occTableName?: string | undefined;
    } | {
        kind: "bytesReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    } | {
        kind: "bytesReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    } | {
        kind: "documentsReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    } | {
        kind: "documentsReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    })[];
}, {
    summary: string;
    dashboardUrl: string;
    insights: ({
        kind: "occRetried";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "warning";
        occTableName?: string | undefined;
    } | {
        kind: "occFailedPermanently";
        componentPath: string | null;
        occCalls: number;
        recentEvents: {
            id: string;
            timestamp: string;
            occ_retry_count: number;
            request_id: string;
            occ_document_id?: string | undefined;
            occ_write_source?: string | undefined;
        }[];
        functionId: string;
        severity: "error";
        occTableName?: string | undefined;
    } | {
        kind: "bytesReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    } | {
        kind: "bytesReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    } | {
        kind: "documentsReadLimit";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "error";
    } | {
        kind: "documentsReadThreshold";
        componentPath: string | null;
        count: number;
        recentEvents: {
            id: string;
            success: boolean;
            timestamp: string;
            request_id: string;
            calls: {
                table_name: string;
                bytes_read: number;
                documents_read: number;
            }[];
        }[];
        functionId: string;
        severity: "warning";
    })[];
}>;
export declare const InsightsTool: ConvexTool<typeof inputSchema, typeof outputSchema>;
export {};
//# sourceMappingURL=insights.d.ts.map