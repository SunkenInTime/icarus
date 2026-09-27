// Test helpers. The second dot in the file name keeps Convex from bundling
// it into deployments.
// Inserts content rows the way every server writer does: together with the
// image reference rows media cleanup reads (see lib/assetReferences.ts).
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import type { WithoutSystemFields } from "convex/server";
import {
  syncElementAssetReferences,
  syncLineupAssetReferences,
} from "./lib/assetReferences";

export async function insertElement(
  ctx: MutationCtx,
  element: WithoutSystemFields<Doc<"elements">>,
): Promise<Id<"elements">> {
  const id = await ctx.db.insert("elements", element);
  await syncElementAssetReferences(ctx, id, element);
  return id;
}

export async function insertLineup(
  ctx: MutationCtx,
  lineup: WithoutSystemFields<Doc<"lineups">>,
): Promise<Id<"lineups">> {
  const id = await ctx.db.insert("lineups", lineup);
  await syncLineupAssetReferences(ctx, id, lineup);
  return id;
}
