"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var insights_exports = {};
__export(insights_exports, {
  InsightsTool: () => InsightsTool
});
module.exports = __toCommonJS(insights_exports);
var import_zod = require("zod");
var import_api = require("../../api.js");
var import_deploymentSelection = require("../../deploymentSelection.js");
var import_dashboard = require("../../../lib/dashboard.js");
var import_insights = require("../../insights.js");
const inputSchema = import_zod.z.object({
  deploymentSelector: import_zod.z.string().describe(
    "Deployment selector (from the status tool) to fetch insights for."
  )
});
const occRecentEventSchema = import_zod.z.object({
  timestamp: import_zod.z.string(),
  id: import_zod.z.string(),
  request_id: import_zod.z.string(),
  occ_document_id: import_zod.z.string().optional(),
  occ_write_source: import_zod.z.string().optional(),
  occ_retry_count: import_zod.z.number()
});
const resourceRecentEventSchema = import_zod.z.object({
  timestamp: import_zod.z.string(),
  id: import_zod.z.string(),
  request_id: import_zod.z.string(),
  calls: import_zod.z.array(
    import_zod.z.object({
      table_name: import_zod.z.string(),
      bytes_read: import_zod.z.number(),
      documents_read: import_zod.z.number()
    })
  ),
  success: import_zod.z.boolean()
});
const insightSchema = import_zod.z.discriminatedUnion("kind", [
  import_zod.z.object({
    kind: import_zod.z.literal("occRetried"),
    severity: import_zod.z.literal("warning"),
    functionId: import_zod.z.string(),
    componentPath: import_zod.z.string().nullable(),
    occCalls: import_zod.z.number(),
    occTableName: import_zod.z.string().optional(),
    recentEvents: import_zod.z.array(occRecentEventSchema)
  }),
  import_zod.z.object({
    kind: import_zod.z.literal("occFailedPermanently"),
    severity: import_zod.z.literal("error"),
    functionId: import_zod.z.string(),
    componentPath: import_zod.z.string().nullable(),
    occCalls: import_zod.z.number(),
    occTableName: import_zod.z.string().optional(),
    recentEvents: import_zod.z.array(occRecentEventSchema)
  }),
  import_zod.z.object({
    kind: import_zod.z.literal("bytesReadLimit"),
    severity: import_zod.z.literal("error"),
    functionId: import_zod.z.string(),
    componentPath: import_zod.z.string().nullable(),
    count: import_zod.z.number(),
    recentEvents: import_zod.z.array(resourceRecentEventSchema)
  }),
  import_zod.z.object({
    kind: import_zod.z.literal("bytesReadThreshold"),
    severity: import_zod.z.literal("warning"),
    functionId: import_zod.z.string(),
    componentPath: import_zod.z.string().nullable(),
    count: import_zod.z.number(),
    recentEvents: import_zod.z.array(resourceRecentEventSchema)
  }),
  import_zod.z.object({
    kind: import_zod.z.literal("documentsReadLimit"),
    severity: import_zod.z.literal("error"),
    functionId: import_zod.z.string(),
    componentPath: import_zod.z.string().nullable(),
    count: import_zod.z.number(),
    recentEvents: import_zod.z.array(resourceRecentEventSchema)
  }),
  import_zod.z.object({
    kind: import_zod.z.literal("documentsReadThreshold"),
    severity: import_zod.z.literal("warning"),
    functionId: import_zod.z.string(),
    componentPath: import_zod.z.string().nullable(),
    count: import_zod.z.number(),
    recentEvents: import_zod.z.array(resourceRecentEventSchema)
  })
]);
const outputSchema = import_zod.z.object({
  insights: import_zod.z.array(insightSchema),
  summary: import_zod.z.string(),
  dashboardUrl: import_zod.z.string()
});
const description = `
Fetch health insights for a Convex deployment over the last 72 hours.

Returns OCC (Optimistic Concurrency Control) conflicts and resource limit issues
that may indicate performance problems or failing functions.

**OCC insights** (occRetried, occFailedPermanently):
  Mutations that conflict on the same document. To fix: restructure mutations to
  touch fewer shared documents, split hot documents, or reduce transaction scope.

**Resource limit insights** (bytesReadLimit, documentsReadLimit, bytesReadThreshold, documentsReadThreshold):
  Functions reading too much data. To fix: add indexes to avoid full table scans,
  use pagination, or filter data more precisely in queries.

Severity levels:
  - "error": Function executions are failing (permanent OCC failures or hard limits hit)
  - "warning": Function executions succeed but are at risk (retried OCCs or approaching limits)

Use the logs tool with status "failure" to see individual error messages and stack traces.

Only available for cloud deployments with user-level authentication.
`.trim();
const InsightsTool = {
  name: "insights",
  description,
  inputSchema,
  outputSchema,
  handler: async (ctx, args) => {
    const { projectDir, deployment } = ctx.decodeDeploymentSelectorUnchecked(
      args.deploymentSelector
    );
    process.chdir(projectDir);
    const deploymentSelection = await (0, import_deploymentSelection.getDeploymentSelection)(
      ctx,
      ctx.options
    );
    const credentials = await (0, import_api.loadSelectedDeploymentCredentials)(
      ctx,
      deploymentSelection,
      deployment
    );
    const deploymentName = credentials.deploymentFields?.deploymentName ?? null;
    if (deploymentName === null) {
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "Insights are only available for cloud deployments. Local deployments do not have insights data."
      });
    }
    const auth = ctx.bigBrainAuth();
    if (auth === null || auth.kind === "deploymentKey" || auth.kind === "projectKey") {
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "Insights require user-level authentication. Deploy keys and project keys cannot access team usage data."
      });
    }
    const insights = await (0, import_insights.fetchInsights)(ctx, deploymentName, {
      includeRecentEvents: true
    });
    const errorCount = insights.filter((i) => i.severity === "error").length;
    const warningCount = insights.filter(
      (i) => i.severity === "warning"
    ).length;
    let summary;
    if (insights.length === 0) {
      summary = "No issues found. The deployment is healthy over the last 72 hours.";
    } else {
      const parts = [];
      if (errorCount > 0)
        parts.push(`${errorCount} error${errorCount > 1 ? "s" : ""}`);
      if (warningCount > 0)
        parts.push(`${warningCount} warning${warningCount > 1 ? "s" : ""}`);
      summary = `Found ${parts.join(" and ")} in the last 72 hours.`;
    }
    const dashboardUrl = (0, import_dashboard.deploymentDashboardUrlPage)(
      deploymentName,
      "/insights"
    );
    return {
      insights,
      summary,
      dashboardUrl
    };
  }
};
//# sourceMappingURL=insights.js.map
