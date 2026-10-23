import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";

/// How many transactions have written the strategy's content (its pages,
/// page contents, elements, lineups and image assets; see lib/functions.ts).
/// It only goes up, so a copy read at one version is current exactly while
/// the version stays the same.
export async function readContentVersion(
  ctx: QueryCtx,
  strategyId: Id<"strategies">,
): Promise<number> {
  const folded = await ctx.db
    .query("strategyContentVersions")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .unique();
  const unfolded = await ctx.db
    .query("strategyContentChanges")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();
  return (folded?.version ?? 0) + unfolded.length;
}

/// Change rows at least this old are folded: every transaction that could
/// still be writing one is younger, so folding never collides with an edit.
export const FOLD_AFTER_MS = 60 * 1000;

/// Folds up to [limit] of the oldest change rows into their strategies'
/// counts, leaving every version as it was. The rows of a deleted strategy
/// go with its count. Returns how many rows it read.
export async function foldOldContentChanges(
  ctx: MutationCtx,
  limit: number,
): Promise<number> {
  const changes = await ctx.db
    .query("strategyContentChanges")
    .withIndex("by_creation_time", (q) =>
      q.lt("_creationTime", Date.now() - FOLD_AFTER_MS),
    )
    .take(limit);
  const byStrategy = new Map<
    Id<"strategies">,
    Id<"strategyContentChanges">[]
  >();
  for (const change of changes) {
    const ids = byStrategy.get(change.strategyId) ?? [];
    ids.push(change._id);
    byStrategy.set(change.strategyId, ids);
  }
  for (const [strategyId, ids] of byStrategy) {
    const folded = await ctx.db
      .query("strategyContentVersions")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
      .unique();
    if ((await ctx.db.get(strategyId)) === null) {
      if (folded !== null) await ctx.db.delete(folded._id);
    } else if (folded === null) {
      await ctx.db.insert("strategyContentVersions", {
        strategyId,
        version: ids.length,
      });
    } else {
      await ctx.db.patch(folded._id, { version: folded.version + ids.length });
    }
    for (const id of ids) await ctx.db.delete(id);
  }
  return changes.length;
}
