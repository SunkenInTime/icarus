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

export type TestLineup = {
  originId?: string;
  landingId?: string;
  agentType?: string;
  originPosition?: { dx: number; dy: number };
  landingPosition?: { dx: number; dy: number };
  name?: string;
  youtubeLink?: string;
  notes?: string;
  images?: Array<{ id: string; fileExtension?: string }>;
};

/// A lineup row's payload as a client writes it: the lineup's details and
/// whole copies of its origin (the agent) and landing (the ability), each
/// marker's `lineUpID` naming its end. Lineups that share a spot pass the
/// same originId or landingId. The row's key is [id].
export function lineupPayload(id: string, lineup: TestLineup = {}) {
  const originId = lineup.originId ?? `${id}-origin`;
  const landingId = lineup.landingId ?? `${id}-landing`;
  return {
    kind: "lineup" as const,
    payloadVersion: 1,
    data: {
      id,
      name: lineup.name ?? "",
      youtubeLink: lineup.youtubeLink ?? "",
      notes: lineup.notes ?? "",
      images: lineup.images ?? [],
      origin: {
        id: originId,
        agent: {
          id: `agent-${originId}`,
          type: lineup.agentType ?? "sova",
          position: lineup.originPosition ?? { dx: 0, dy: 0 },
          lineUpID: originId,
        },
      },
      landing: {
        id: landingId,
        ability: {
          id: `ability-${landingId}`,
          position: lineup.landingPosition ?? { dx: 0, dy: 0 },
          lineUpID: landingId,
        },
      },
    },
  };
}
