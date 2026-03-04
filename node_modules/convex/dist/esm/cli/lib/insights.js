"use strict";
import { fetchTeamAndProject } from "./api.js";
import { bigBrainFetch, provisionHost } from "./utils/utils.js";
export const ROOT_COMPONENT_PATH = "-root-component-";
export const INSIGHTS_QUERY_ID = "9ab3b74e-a725-480b-88a6-43e6bd70bd82";
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
export function orderForKind(kind) {
  return insightKindMap.get(kind)?.order ?? insightKinds.length;
}
export function severityForKind(kind) {
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
export async function fetchRawInsightsData(ctx, deploymentName) {
  const { teamId } = await fetchTeamAndProject(ctx, deploymentName);
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
  const bbFetch = await bigBrainFetch(ctx);
  const res = await bbFetch(
    `dashboard/teams/${teamId}/usage/query?${queryParams.toString()}`,
    {
      method: "GET",
      headers: { Origin: provisionHost }
    }
  );
  return await res.json();
}
export async function fetchInsights(ctx, deploymentName, options) {
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
