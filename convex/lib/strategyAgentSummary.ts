import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { WithoutSystemFields } from "convex/server";

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : null;
}

/// Reads the agent type the client stores as the enum name under `type`, as
/// an agent element's data and a lineup origin's agent both do.
function agentTypeOf(data: unknown): string | null {
  const type = asRecord(data)?.type;
  return typeof type === "string" && type.length > 0 ? type : null;
}

/// The agents a lineup group starts from: each origin's id and agent type,
/// skipping an origin whose agent names no type.
export function lineupAgentsOf(
  payload: Doc<"lineups">["payload"],
): { originId: string; agentType: string }[] {
  const origins = payload.data.origins;
  if (!Array.isArray(origins)) return [];
  const agents: { originId: string; agentType: string }[] = [];
  for (const origin of origins) {
    const record = asRecord(origin);
    const agentType = agentTypeOf(record?.agent);
    if (record === null || typeof record.id !== "string" || agentType === null) {
      continue;
    }
    agents.push({ originId: record.id, agentType });
  }
  return agents;
}

type LineupAgent = Pick<
  Doc<"lineupAgents">,
  "pageId" | "originId" | "agentType"
>;

/// Brings the lineupAgents rows of one lineup group in step with it: one
/// row per origin while the group is live, none otherwise. Call after every
/// write of a lineup row, with null once the row itself is gone.
export async function syncLineupAgents(
  ctx: MutationCtx,
  lineupId: Id<"lineups">,
  lineup: Pick<
    Doc<"lineups">,
    "strategyId" | "pageId" | "deleted" | "payload"
  > | null,
): Promise<void> {
  const existing = await ctx.db
    .query("lineupAgents")
    .withIndex("by_lineupId", (q) => q.eq("lineupId", lineupId))
    .collect();
  // Keyed by origin id, which is unique within a group.
  const wanted = new Map<string, WithoutSystemFields<Doc<"lineupAgents">>>();
  if (lineup !== null && !lineup.deleted) {
    for (const agent of lineupAgentsOf(lineup.payload)) {
      wanted.set(agent.originId, {
        strategyId: lineup.strategyId,
        pageId: lineup.pageId,
        lineupId,
        ...agent,
      });
    }
  }
  for (const row of existing) {
    const want = wanted.get(row.originId);
    if (want === undefined) {
      // An origin the group no longer holds, or a second row for one.
      await ctx.db.delete(row._id);
      continue;
    }
    wanted.delete(row.originId);
    if (
      row.strategyId !== want.strategyId ||
      row.pageId !== want.pageId ||
      row.agentType !== want.agentType
    ) {
      await ctx.db.patch(row._id, want);
    }
  }
  for (const row of wanted.values()) {
    await ctx.db.insert("lineupAgents", row);
  }
}

/// Recomputes which agents a strategy uses, from its live agent elements and
/// the origins of its live lineups on pages not in the trash, and stores the
/// answer in its own row. Content ops never touch the strategy row itself;
/// the summary is derived data that the folder tree reads without scanning
/// elements.
export async function refreshStrategyAgentSummary(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
): Promise<void> {
  // Agent elements are small. Lineups are read through their lineupAgents
  // rows, never the lineup rows themselves: those carry image lists and
  // could take a strategy's reads past a transaction's limits.
  const agents = await ctx.db
    .query("elements")
    .withIndex("by_strategyId_and_elementType", (q) =>
      q.eq("strategyId", strategyId).eq("elementType", "agent"),
    )
    .collect();
  const lineupAgents = await ctx.db
    .query("lineupAgents")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();
  const trashedPageIds = new Set(
    (
      await ctx.db
        .query("pages")
        .withIndex("by_strategyId_and_deletedAt", (q) =>
          q.eq("strategyId", strategyId).gt("deletedAt", undefined),
        )
        .collect()
    ).map((page) => page._id),
  );
  const onLivePage = (row: { pageId: Id<"pages"> }) =>
    !trashedPageIds.has(row.pageId);
  await storeStrategyAgentSummary(
    ctx,
    strategyId,
    agentTypesOf(agents.filter(onLivePage), lineupAgents.filter(onLivePage)),
  );
}

/// The agents that live content uses, most used first. Takes any elements
/// and the agents of live lineup groups; live agent elements count, and
/// each lineup origin once per page, however many lineups share it.
export function agentTypesOf(
  elements: Pick<Doc<"elements">, "deleted" | "elementType" | "payload">[],
  lineupAgents: LineupAgent[],
): string[] {
  const counts = new Map<string, number>();
  const bump = (type: string | null) => {
    if (type === null) return;
    counts.set(type, (counts.get(type) ?? 0) + 1);
  };
  for (const element of elements) {
    if (element.deleted || element.elementType !== "agent") continue;
    bump(agentTypeOf(element.payload.data));
  }
  const countedOrigins = new Set<string>();
  for (const { pageId, originId, agentType } of lineupAgents) {
    const originKey = `${pageId}:${originId}`;
    if (countedOrigins.has(originKey)) continue;
    countedOrigins.add(originKey);
    bump(agentType);
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([type]) => type);
}

/// Stores [agentTypes] as the strategy's summary, writing only on change.
export async function storeStrategyAgentSummary(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  agentTypes: string[],
): Promise<void> {
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
