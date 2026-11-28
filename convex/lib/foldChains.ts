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

async function scheduleNextFold(
  ctx: MutationCtx,
  chain: FoldChain,
  delayMs: number,
): Promise<void> {
  const next = await ctx.scheduler.runAfter(
    delayMs,
    scheduledFolds[chain],
    {},
  );
  const recorded = await ctx.db
    .query("foldChainRuns")
    .withIndex("by_chain", (q) => q.eq("chain", chain))
    .unique();
  if (recorded === null) {
    await ctx.db.insert("foldChainRuns", { chain, next });
  } else {
    await ctx.db.patch(recorded._id, { next });
  }
}

async function nextFoldIsComing(
  ctx: MutationCtx,
  chain: FoldChain,
): Promise<boolean> {
  const recorded = await ctx.db
    .query("foldChainRuns")
    .withIndex("by_chain", (q) => q.eq("chain", chain))
    .unique();
  if (recorded === null) return false;
  const next = await ctx.db.system.get(recorded.next);
  return next?.state.kind === "pending" || next?.state.kind === "inProgress";
}

export async function startFolding(
  ctx: MutationCtx,
  chain: FoldChain,
): Promise<void> {
  if ((await runningChain(ctx, chain)) !== null) return;
  await ctx.db.insert("foldChains", { chain });
  await scheduleNextFold(ctx, chain, FOLD_EVERY_MS[chain]);
}

export async function continueFolding(
  ctx: MutationCtx,
  chain: FoldChain,
  left: FoldLeft,
): Promise<void> {
  if (left === "fullBatch") {
    await scheduleNextFold(ctx, chain, 0);
  } else if (left === "rowsWaiting") {
    await scheduleNextFold(ctx, chain, FOLD_EVERY_MS[chain]);
  } else {
    const running = await runningChain(ctx, chain);
    if (running === null) {
      throw new Error(`The ${chain} fold ran with no chain row`);
    }
    await ctx.db.delete(running._id);
  }
}

export async function sweepFolding(
  ctx: MutationCtx,
  chain: FoldChain,
  left: FoldLeft,
): Promise<void> {
  const running = await runningChain(ctx, chain);
  if (running !== null && (await nextFoldIsComing(ctx, chain))) return;
  if (left === "nothing") {
    if (running !== null) await ctx.db.delete(running._id);
    return;
  }
  if (running === null) await ctx.db.insert("foldChains", { chain });
  await scheduleNextFold(ctx, chain, 0);
}
