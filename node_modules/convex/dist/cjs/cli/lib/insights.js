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
  INSIGHTS_QUERY_ID: () => INSIGHTS_QUERY_ID,
  ROOT_COMPONENT_PATH: () => ROOT_COMPONENT_PATH,
  fetchInsights: () => fetchInsights,
  fetchRawInsightsData: () => fetchRawInsightsData,
  orderForKind: () => orderForKind,
  severityForKind: () => severityForKind
});
module.exports = __toCommonJS(insights_exports);
var import_api = require("./api.js");
var import_utils = require("./utils/utils.js");
const ROOT_COMPONENT_PATH = "-root-component-";
const INSIGHTS_QUERY_ID = "9ab3b74e-a725-480b-88a6-43e6bd70bd82";
const insightKinds = [
  { kind: "documentsReadLimit", severity: "error" },
  { kind: "bytesReadLimit", severity: "error" },
  { kind: "occFailedPermanently", severity: "error" },
  { kind: "documentsReadThreshold", severity: "warning" },
  { kind: "bytesReadThreshold", severity: "warning" },
  { kind: "occRetried", severity: "warning" }
];
const insightKindMap = new Map(
  insightKinds.map((ik, i) => [ik.kind, { severity: ik.severity, order: i }])
);
function orderForKind(kind) {
  return insightKindMap.get(kind)?.order ?? insightKinds.length;
}
function severityForKind(kind) {
  return insightKindMap.get(kind)?.severity;
}
const MAX_RECENT_EVENTS = 5;
function parseRow(row, includeRecentEvents) {
  const kind = row[0];
  const functionId = row[1];
  const componentPath = row[2] === ROOT_COMPONENT_PATH ? null : row[2];
  const details = JSON.parse(row[3]);
  const common = { functionId, componentPath };
  const recentEvents = includeRecentEvents ? details.recentEvents.slice(0, MAX_RECENT_EVENTS) : void 0;
  switch (kind) {
    case "occRetried":
      return {
        kind,
        severity: "warning",
        ...common,
        occCalls: details.occCalls,
        occTableName: details.occTableName,
        recentEvents
      };
    case "occFailedPermanently":
      return {
        kind,
        severity: "error",
        ...common,
        occCalls: details.occCalls,
        occTableName: details.occTableName,
        recentEvents
      };
    case "bytesReadLimit":
      return {
        kind,
        severity: "error",
        ...common,
        count: details.count,
        recentEvents
      };
    case "bytesReadThreshold":
      return {
        kind,
        severity: "warning",
        ...common,
        count: details.count,
        recentEvents
      };
    case "documentsReadLimit":
      return {
        kind,
        severity: "error",
        ...common,
        count: details.count,
        recentEvents
      };
    case "documentsReadThreshold":
      return {
        kind,
        severity: "warning",
        ...common,
        count: details.count,
        recentEvents
      };
    default:
      return null;
  }
}
async function fetchRawInsightsData(ctx, deploymentName) {
  const { teamId } = await (0, import_api.fetchTeamAndProject)(ctx, deploymentName);
  const now = /* @__PURE__ */ new Date();
  const hoursAgo72 = new Date(now.getTime() - 72 * 60 * 60 * 1e3);
  const fromDate = hoursAgo72.toISOString().split("T")[0];
  const toDate = now.toISOString().split("T")[0];
  const queryParams = new URLSearchParams({
    queryId: INSIGHTS_QUERY_ID,
    deploymentName,
    from: fromDate,
    to: toDate
  });
  const bbFetch = await (0, import_utils.bigBrainFetch)(ctx);
  const res = await bbFetch(
    `dashboard/teams/${teamId}/usage/query?${queryParams.toString()}`,
    {
      method: "GET",
      headers: { Origin: import_utils.provisionHost }
    }
  );
  return await res.json();
}
async function fetchInsights(ctx, deploymentName, options) {
  const rawData = await fetchRawInsightsData(ctx, deploymentName);
  const includeRecentEvents = options?.includeRecentEvents ?? false;
  const insights = rawData.flatMap((row) => {
    const parsed = parseRow(row, includeRecentEvents);
    return parsed ? [parsed] : [];
  });
  insights.sort((a, b) => orderForKind(a.kind) - orderForKind(b.kind));
  return insights;
}
//# sourceMappingURL=insights.js.map
