import type { Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";

/// Reads the agent type of one agent element or lineup group payload. The
/// client stores the agent enum name under `type` (an element) or under
/// `agent.type` (a lineup group); anything else is not an agent.
function agentTypeOf(data: unknown): string | null {
  if (typeof data !== "object" || data === null) return null;
  const record = data as Record<string, unknown>;
  const direct = record.type;
  if (typeof direct === "string" && direct.length > 0) return direct;
  const agent = record.agent;
  if (typeof agent === "object" && agent !== null) {
    const nested = (agent as Record<string, unknown>).type;
    if (typeof nested === "string" && nested.length > 0) return nested;
  }
  return null;
}

/// Recomputes which agents a strategy uses, from its live agent elements and
/// lineup groups, and stores the answer in its own row. Content ops never
/// touch the strategy row itself; the summary is derived data that the
/// folder tree reads without scanning elements.
export async function refreshStrategyAgentSummary(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
): Promise<void> {
  const counts = new Map<string, number>();
  const bump = (type: string | null) => {
    if (type === null) return;
    counts.set(type, (counts.get(type) ?? 0) + 1);
  };
  const elements = await ctx.db
    .query("elements")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();
  for (const element of elements) {
    if (element.deleted || element.payload.kind !== "agent") continue;
    bump(agentTypeOf(element.payload.data));
  }
  const lineups = await ctx.db
    .query("lineups")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();
  for (const lineup of lineups) {
    if (lineup.deleted) continue;
    bump(agentTypeOf(lineup.payload.data));
  }
  const agentTypes = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([type]) => type);

  const existing = await ctx.db
    .query("strategyAgentSummaries")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .unique();
  const now = Date.now();
  if (existing === null) {
    if (agentTypes.length === 0) return;
    await ctx.db.insert("strategyAgentSummaries", {
      strategyId,
      agentTypes,
      updatedAt: now,
    });
    return;
  }
  const unchanged =
    existing.agentTypes.length === agentTypes.length &&
    existing.agentTypes.every((type, index) => type === agentTypes[index]);
  if (unchanged) return;
  await ctx.db.patch(existing._id, { agentTypes, updatedAt: now });
}

export async function deleteStrategyAgentSummary(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
): Promise<void> {
  const existing = await ctx.db
    .query("strategyAgentSummaries")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .unique();
  if (existing !== null) await ctx.db.delete(existing._id);
}

export async function readStrategyAgentTypes(
  ctx: QueryCtx | MutationCtx,
  strategyId: Id<"strategies">,
): Promise<string[]> {
  const summary = await ctx.db
    .query("strategyAgentSummaries")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .unique();
  return summary?.agentTypes ?? [];
}
