"use strict";
import { chalkStderr } from "chalk";
import { deploymentDashboardUrlPage } from "./dashboard.js";
export function addProgressLinkIfSlow(msg, deploymentName, start) {
  if (Date.now() - start > 1e4) {
    const dashboardUrl = deploymentDashboardUrlPage(
      deploymentName,
      `/data?showSchema=true`
    );
    msg = msg.concat(`
See progress here: ${dashboardUrl}`);
  }
  return msg;
}
export function formatIndex(index) {
  const [tableName, indexName] = index.name.split(".");
  return `${tableName}.${chalkStderr.bold(indexName)} ${chalkStderr.gray(formatIndexFields(index))}${index.staged ? chalkStderr.blue("  (staged)") : ""}`;
}
function formatIndexFields(index) {
  switch (index.type) {
    case "database":
      return "  " + index.fields.map((f) => chalkStderr.underline(f)).join(", ");
    case "search":
      return `${chalkStderr.cyan("(text)")}   ${chalkStderr.underline(index.searchField)}${formatFilterFields(index.filterFields)}`;
    case "vector":
      return `${chalkStderr.cyan("(vector)")}   ${chalkStderr.underline(index.vectorField)} (${index.dimensions} dimensions)${formatFilterFields(index.filterFields)}`;
    default:
      index;
      return "";
  }
}
function formatFilterFields(filterFields) {
  if (filterFields.length === 0) {
    return "";
  }
  return `, filter${filterFields.length === 1 ? "" : "s"} on ${filterFields.map((f) => chalkStderr.underline(f)).join(", ")}`;
}
//# sourceMappingURL=indexes.js.map
