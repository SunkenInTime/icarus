import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx } from "../_generated/server";
import { errorWithCode } from "./errors";

type LineupPayload = Doc<"lineups">["payload"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// The lineups and spots a lineup group row holds, each kind of id in its
/// own namespace (a landing may share its lineup's id).
export function lineupGroupItems(payload: LineupPayload): Set<string> {
  const items = new Set<string>();
  for (const [field, kind] of [
    ["origins", "origin"],
    ["landings", "landing"],
    ["links", "link"],
  ] as const) {
    const entries = payload.data[field];
    if (!Array.isArray(entries)) continue;
    for (const entry of entries) {
      if (isRecord(entry) && typeof entry.id === "string") {
        items.add(`${kind}:${entry.id}`);
      }
    }
  }
  return items;
}

/// Brings the lineupItems rows of one lineup group in step with it: one per
/// lineup and spot while the group is live, none otherwise. Call after every
/// write of a lineup row, with null once the row itself is gone.
export async function syncLineupItems(
  ctx: MutationCtx,
  lineupId: Id<"lineups">,
  lineup: Pick<Doc<"lineups">, "pageId" | "deleted" | "payload"> | null,
): Promise<void> {
  const existing = await ctx.db
    .query("lineupItems")
    .withIndex("by_lineupId", (q) => q.eq("lineupId", lineupId))
    .collect();
  const wanted =
    lineup === null || lineup.deleted
      ? new Set<string>()
      : lineupGroupItems(lineup.payload);
  for (const row of existing) {
    if (lineup !== null && wanted.delete(row.item)) {
      if (row.pageId !== lineup.pageId) {
        await ctx.db.patch(row._id, { pageId: lineup.pageId });
      }
      continue;
    }
    // An item the group no longer holds, a second row for one, or a row
    // that is gone.
    await ctx.db.delete(row._id);
  }
  if (lineup === null) return;
  for (const item of wanted) {
    await ctx.db.insert("lineupItems", {
      pageId: lineup.pageId,
      lineupId,
      item,
    });
  }
}

/// Refuses a lineup group row ([lineupId], or a row about to be inserted
/// when null) that would hold a lineup or spot another live row of its page
/// holds. Clients never write one: a lineup stays in its group, and a new
/// one is aimed at one existing spot at most. Two rows sharing one would
/// each carry their own copy of it, which can drift apart, so the write
/// fails loudly instead. Reads only the small lineupItems rows, never the
/// lineup rows, whose image lists can be large.
export async function assertLineupGroupAlone(
  ctx: MutationCtx,
  pageId: Id<"pages">,
  lineupId: Id<"lineups"> | null,
  payload: LineupPayload,
): Promise<void> {
  for (const item of lineupGroupItems(payload)) {
    const holders = await ctx.db
      .query("lineupItems")
      .withIndex("by_pageId_and_item", (q) =>
        q.eq("pageId", pageId).eq("item", item),
      )
      .take(2);
    if (holders.some((holder) => holder.lineupId !== lineupId)) {
      throw errorWithCode(
        "INVALID_LINEUP_PAYLOAD_DATA",
        "A lineup or spot in this group is already in another group",
      );
    }
  }
}
