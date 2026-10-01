import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";

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

/// Recomputes which agents a strategy uses, from its live agent elements and
/// the origins of its live lineups on pages not in the trash, and stores the
/// answer in its own row. Content ops never
/// touch the strategy row itself; the summary is derived data that the
/// folder tree reads without scanning elements.
export async function refreshStrategyAgentSummary(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
): Promise<void> {
  // Only agent elements and live lineups carry an agent; reading just those
  // keeps this cheap however large the strategy's other content is (it runs
  // after every batch of content ops). A lineup row holds its images' ids,
  // never their bytes.
  const agents = await ctx.db
    .query("elements")
    .withIndex("by_strategyId_and_elementType", (q) =>
      q.eq("strategyId", strategyId).eq("elementType", "agent"),
    )
    .collect();
  const lineups = await ctx.db
    .query("lineups")
    .withIndex("by_strategyId_and_deleted", (q) =>
      q.eq("strategyId", strategyId).eq("deleted", false),
    )
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
    agentTypesOf(agents.filter(onLivePage), lineups.filter(onLivePage)),
  );
}

/// The agents that live content uses, most used first. Takes any elements
/// and lineup rows; live agent elements count, and each origin of a live
/// lineup once per page, however many lineups share it.
export function agentTypesOf(
  elements: Pick<Doc<"elements">, "deleted" | "elementType" | "payload">[],
  lineups: Pick<Doc<"lineups">, "deleted" | "pageId" | "payload">[],
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
  for (const lineup of lineups) {
    if (lineup.deleted) continue;
    const origin = asRecord(lineup.payload.data.origin);
    const originKey = `${lineup.pageId}:${String(origin?.id)}`;
    if (origin === null || countedOrigins.has(originKey)) continue;
    countedOrigins.add(originKey);
    bump(agentTypeOf(origin.agent));
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
