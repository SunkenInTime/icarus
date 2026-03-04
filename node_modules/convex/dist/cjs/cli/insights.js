"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
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
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var insights_exports = {};
__export(insights_exports, {
  insights: () => insights
});
module.exports = __toCommonJS(insights_exports);
var import_extra_typings = require("@commander-js/extra-typings");
var import_chalk = __toESM(require("chalk"), 1);
var import_context = require("../bundler/context.js");
var import_log = require("../bundler/log.js");
var import_api = require("./lib/api.js");
var import_command = require("./lib/command.js");
var import_dashboard = require("./lib/dashboard.js");
var import_deploymentSelection = require("./lib/deploymentSelection.js");
var import_insights = require("./lib/insights.js");
function formatInsightKind(kind) {
  switch (kind) {
    case "occRetried":
      return "OCC Retried";
    case "occFailedPermanently":
      return "OCC Failed Permanently";
    case "bytesReadLimit":
      return "Bytes Read Limit Exceeded";
    case "bytesReadThreshold":
      return "Bytes Read Near Limit";
    case "documentsReadLimit":
      return "Documents Read Limit Exceeded";
    case "documentsReadThreshold":
      return "Documents Read Near Limit";
    default:
      return kind;
  }
}
function formatFunctionName(insight) {
  if (insight.componentPath) {
    return `${insight.componentPath}:${insight.functionId}`;
  }
  return insight.functionId;
}
function formatInsight(insight, details) {
  const severity = insight.severity === "error" ? import_chalk.default.red(`[ERROR]`) : import_chalk.default.yellow(`[WARNING]`);
  const kind = formatInsightKind(insight.kind);
  const fn = import_chalk.default.bold(formatFunctionName(insight));
  let detail;
  if ("occCalls" in insight) {
    const table = insight.occTableName ? ` on table ${import_chalk.default.cyan(insight.occTableName)}` : "";
    detail = `${insight.occCalls} OCC conflict${insight.occCalls !== 1 ? "s" : ""}${table}`;
  } else {
    detail = `${insight.count} occurrence${insight.count !== 1 ? "s" : ""}`;
  }
  let output = `${severity} ${kind}: ${fn} \u2014 ${detail}`;
  if (details && insight.recentEvents && insight.recentEvents.length > 0) {
    output += "\n";
    for (const event of insight.recentEvents) {
      const time = import_chalk.default.dim(new Date(event.timestamp).toLocaleString());
      const reqId = import_chalk.default.dim(`req:${event.request_id}`);
      if ("occ_retry_count" in event) {
        const docId = event.occ_document_id ? ` doc:${event.occ_document_id}` : "";
        const source = event.occ_write_source ? ` source:${event.occ_write_source}` : "";
        output += `    ${time}  ${reqId}  retries:${event.occ_retry_count}${docId}${source}
`;
      } else {
        const status = event.success ? import_chalk.default.green("ok") : import_chalk.default.red("fail");
        const calls = event.calls.map(
          (c) => `${c.table_name}(${c.documents_read} docs, ${c.bytes_read} bytes)`
        ).join(", ");
        output += `    ${time}  ${reqId}  ${status}  ${calls}
`;
      }
    }
  }
  return output;
}
const insights = new import_extra_typings.Command("insights").summary("Show health insights for your deployment").description(
  "Show health insights for a Convex deployment over the last 72 hours.\nDisplays OCC conflicts and resource limit issues that may indicate performance problems.\n\nOnly available for cloud deployments with user-level authentication."
).allowExcessArguments(false).option("--details", "Show recent events for each insight", false).addDeploymentSelectionOptions((0, import_command.actionDescription)("Show insights for")).showHelpAfterError().action(async (cmdOptions) => {
  const ctx = await (0, import_context.oneoffContext)(cmdOptions);
  const selectionWithinProject = (0, import_api.deploymentSelectionWithinProjectFromOptions)(cmdOptions);
  const deploymentSelection = await (0, import_deploymentSelection.getDeploymentSelection)(ctx, cmdOptions);
  const credentials = await (0, import_api.loadSelectedDeploymentCredentials)(
    ctx,
    deploymentSelection,
    selectionWithinProject
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
  const insightsList = await (0, import_insights.fetchInsights)(ctx, deploymentName, {
    includeRecentEvents: cmdOptions.details
  });
  const dashboardUrl = (0, import_dashboard.deploymentDashboardUrlPage)(
    deploymentName,
    "/insights"
  );
  if (insightsList.length === 0) {
    (0, import_log.logOutput)(
      import_chalk.default.green(
        "No issues found. The deployment is healthy over the last 72 hours."
      )
    );
  } else {
    const errorCount = insightsList.filter(
      (i) => i.severity === "error"
    ).length;
    const warningCount = insightsList.filter(
      (i) => i.severity === "warning"
    ).length;
    const parts = [];
    if (errorCount > 0)
      parts.push(
        import_chalk.default.red(`${errorCount} error${errorCount > 1 ? "s" : ""}`)
      );
    if (warningCount > 0)
      parts.push(
        import_chalk.default.yellow(`${warningCount} warning${warningCount > 1 ? "s" : ""}`)
      );
    (0, import_log.logOutput)(`Found ${parts.join(" and ")} in the last 72 hours:
`);
    for (const insight of insightsList) {
      (0, import_log.logOutput)(formatInsight(insight, cmdOptions.details));
    }
  }
  (0, import_log.logOutput)(`
Dashboard: ${import_chalk.default.cyan(dashboardUrl)}`);
});
//# sourceMappingURL=insights.js.map
