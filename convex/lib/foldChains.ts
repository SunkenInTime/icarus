import { makeFunctionReference } from "convex/server";
import type { MutationCtx } from "../_generated/server";

export type FoldChain = "contentChanges" | "communityCounts";

export type FoldLeft = "fullBatch" | "rowsWaiting" | "nothing";

const scheduledFolds = {
  contentChanges: makeFunctionReference<"mutation">(
    "maintenance:scheduledContentFold",
  ),
  communityCounts: makeFunctionReference<"mutation">(
    "community:scheduledCountFold",
  ),
};

export const FOLD_EVERY_MS: Record<FoldChain, number> = {
  contentChanges: 2 * 60 * 1000,
  communityCounts: 5 * 60 * 1000,
};

async function runningChain(ctx: MutationCtx, chain: FoldChain) {
  return await ctx.db
    .query("foldChains")
    .withIndex("by_chain", (q) => q.eq("chain", chain))
    .unique();
}

export async function startFolding(
  ctx: MutationCtx,
  chain: FoldChain,
): Promise<void> {
  if ((await runningChain(ctx, chain)) !== null) return;
  await ctx.db.insert("foldChains", { chain });
  await ctx.scheduler.runAfter(FOLD_EVERY_MS[chain], scheduledFolds[chain], {});
}

export async function continueFolding(
  ctx: MutationCtx,
  chain: FoldChain,
  left: FoldLeft,
): Promise<void> {
  if (left === "fullBatch") {
    await ctx.scheduler.runAfter(0, scheduledFolds[chain], {});
  } else if (left === "rowsWaiting") {
    await ctx.scheduler.runAfter(FOLD_EVERY_MS[chain], scheduledFolds[chain], {});
  } else {
    const running = await runningChain(ctx, chain);
    if (running === null) {
      throw new Error(`The ${chain} fold ran with no chain row`);
    }
    await ctx.db.delete(running._id);
  }
}
