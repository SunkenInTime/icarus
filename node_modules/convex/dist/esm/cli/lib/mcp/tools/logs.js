"use strict";
import { z } from "zod";
import { loadSelectedDeploymentCredentials } from "../../api.js";
import { getDeploymentSelection } from "../../deploymentSelection.js";
import { deploymentFetch } from "../../utils/utils.js";
import { formatLogsAsText } from "../../logs.js";
const inputSchema = z.object({
  deploymentSelector: z.string().describe("Deployment selector (from the status tool) to read logs from."),
  status: z.enum(["all", "success", "failure"]).default("all").optional().describe(
    'Filter by execution outcome. "failure" returns only executions that threw an error. "success" returns only successful executions. Defaults to "all".'
  ),
  cursor: z.number().optional().describe(
    "Optional cursor (in ms) to start reading from. Use 0 to read from the beginning."
  ),
  entriesLimit: z.number().int().positive().max(1e3).optional().describe(
    "Maximum number of log entries to return (from the end). If omitted, returns all available in this chunk."
  ),
  tokensLimit: z.number().int().positive().default(2e4).optional().describe(
    "Approximate maximum number of tokens to return (applied to the JSON payload). Defaults to 20000."
  ),
  jsonl: z.boolean().default(false).optional().describe(
    "If true, return raw log entries as JSONL. If false (default), return formatted text logs."
  )
});
const outputSchema = z.object({
  entries: z.string(),
  newCursor: z.number()
});
const logsResponseSchema = z.object({
  entries: z.array(z.any()),
  newCursor: z.number()
});
const description = `
Fetch a chunk of recent log entries from your Convex deployment.

Returns a batch of UDF execution log entries and a new cursor you can use to
request the next batch. This tool does not tail; it performs a single fetch.

To see only errors and exceptions, set status to "failure". This filters to
executions where a function threw an error, which is useful for debugging
deployment issues. Each failed entry includes the error message and stack trace.
`.trim();
export const LogsTool = {
  name: "logs",
  description,
  inputSchema,
  outputSchema,
  handler: async (ctx, args) => {
    const { projectDir, deployment } = await ctx.decodeDeploymentSelectorReadOnly(args.deploymentSelector);
    process.chdir(projectDir);
    const deploymentSelection = await getDeploymentSelection(ctx, ctx.options);
    const credentials = await loadSelectedDeploymentCredentials(
      ctx,
      deploymentSelection,
      deployment
    );
    const fetch = deploymentFetch(ctx, {
      deploymentUrl: credentials.url,
      adminKey: credentials.adminKey
    });
    const cursor = args.cursor ?? 0;
    const response = await fetch(`/api/stream_function_logs?cursor=${cursor}`, {
      method: "GET"
    });
    if (!response.ok) {
      return await ctx.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: `HTTP error ${response.status}: ${await response.text()}`
      });
    }
    const { entries: allEntries, newCursor } = await response.json().then(logsResponseSchema.parse);
    const status = args.status ?? "all";
    const entries = status === "all" ? allEntries : allEntries.filter((entry) => {
      if (entry.kind !== "Completion") return false;
      const hasError = entry.error !== void 0 && entry.error !== null;
      return status === "failure" ? hasError : !hasError;
    });
    const limitedEntries = limitLogs({
      entries,
      tokensLimit: args.tokensLimit ?? 2e4,
      entriesLimit: args.entriesLimit ?? entries.length
    });
    if (args.jsonl) {
      return {
        entries: limitedEntries.map((entry) => JSON.stringify(entry)).join("\n"),
        newCursor
      };
    }
    return {
      entries: formatLogsAsText(limitedEntries),
      newCursor
    };
  }
};
export function limitLogs({
  entries,
  tokensLimit,
  entriesLimit
}) {
  const limitedByEntries = entries.slice(entries.length - entriesLimit);
  const limitedByTokens = limitEntriesByTokenBudget({
    entries: limitedByEntries,
    tokensLimit
  });
  return limitedByTokens;
}
function limitEntriesByTokenBudget({
  entries,
  tokensLimit
}) {
  const result = [];
  let tokens = 0;
  for (const entry of entries) {
    const entryString = JSON.stringify(entry);
    const entryTokens = estimateTokenCount(entryString);
    tokens += entryTokens;
    if (tokens > tokensLimit) break;
    result.push(entry);
  }
  return result;
}
function estimateTokenCount(entryString) {
  return entryString.length * 0.33;
}
//# sourceMappingURL=logs.js.map
