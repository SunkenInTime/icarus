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
import { syncLineupAgents } from "./lib/strategyAgentSummary";

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
  await syncLineupAgents(ctx, id, lineup);
  return id;
}

type Position = { dx: number; dy: number };

export type TestOrigin = {
  id: string;
  agentType?: string;
  position?: Position;
};

export type TestLanding = { id: string; position?: Position };

export type TestLink = {
  id: string;
  originId: string;
  landingId: string;
  name?: string;
  youtubeLink?: string;
  notes?: string;
  images?: Array<{ id: string; fileExtension?: string }>;
};

export type TestLineupGroup = {
  origins: TestOrigin[];
  landings: TestLanding[];
  links: TestLink[];
};

/// A lineup group row's payload as a client writes it: the group's id (the
/// row's key), its origins (each placing an agent), landings (each placing
/// an ability) and links, each in the shape of the Dart model's toJson()
/// (LineUpOrigin, LineUpLanding, LineUpLink), each marker's `lineUpID`
/// naming its spot.
export function lineupsPayload(id: string, group: TestLineupGroup) {
  return {
    kind: "lineups" as const,
    payloadVersion: 1,
    data: {
      id,
      origins: group.origins.map((origin) => ({
        id: origin.id,
        agent: {
          id: `agent-${origin.id}`,
          type: origin.agentType ?? "sova",
          position: origin.position ?? { dx: 0, dy: 0 },
          lineUpID: origin.id,
        },
      })),
      landings: group.landings.map((landing) => ({
        id: landing.id,
        ability: {
          id: `ability-${landing.id}`,
          position: landing.position ?? { dx: 0, dy: 0 },
          lineUpID: landing.id,
        },
      })),
      links: group.links.map((link) => ({
        id: link.id,
        originId: link.originId,
        landingId: link.landingId,
        name: link.name ?? "",
        youtubeLink: link.youtubeLink ?? "",
        notes: link.notes ?? "",
        images: link.images ?? [],
      })),
    },
  };
}

export type TestLineup = {
  originId?: string;
  landingId?: string;
  agentType?: string;
  originPosition?: Position;
  landingPosition?: Position;
  name?: string;
  youtubeLink?: string;
  notes?: string;
  images?: Array<{ id: string; fileExtension?: string }>;
};

/// A group row holding one lineup: one origin, one landing and the link
/// between them. The group and its link take [id]; the spots default to
/// `<id>-origin` and `<id>-landing`.
export function oneLineupPayload(id: string, lineup: TestLineup = {}) {
  const originId = lineup.originId ?? `${id}-origin`;
  const landingId = lineup.landingId ?? `${id}-landing`;
  return lineupsPayload(id, {
    origins: [
      {
        id: originId,
        agentType: lineup.agentType,
        position: lineup.originPosition,
      },
    ],
    landings: [{ id: landingId, position: lineup.landingPosition }],
    links: [
      {
        id,
        originId,
        landingId,
        name: lineup.name,
        youtubeLink: lineup.youtubeLink,
        notes: lineup.notes,
        images: lineup.images,
      },
    ],
  });
}
