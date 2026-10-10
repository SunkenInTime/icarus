import { getConvexSize, type Value } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx } from "../_generated/server";
import {
  assetIdsOfRow,
  insertAssetReferences,
  type ReferencingElement,
} from "./assetReferences";
import { conflictError } from "./errors";
import {
  collectAssetIdFromElementPayload,
  collectAssetIdsFromLineupPayload,
  copyActiveAssetToStrategy,
} from "./imageAssets";
import { lineupGroupItems } from "./lineupItems";
import { pageCopyId } from "./pageCopyId";
import { lineupAgentsOf } from "./strategyAgentSummary";

export function createPublicId(): string {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (char) => {
    const random = Math.floor(Math.random() * 16);
    const value = char === "x" ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}

// A copy is one transaction, and Convex refuses a transaction past 16 MiB
// read or written, 4,096 index reads, or too many documents written. A copy
// reads its source once and writes it once, so its budget is what it reads:
//  - bytes: each content row's stored size (deleted rows included, as
//    read), and for each placed image the most its asset copy can read
//    (imageCopyReadBytes), and each page and its settings. 12 MiB leaves
//    4 MiB of headroom. Measured on a local backend with 700 KiB rows: 23
//    rows (15.7 MiB) copied, 24 (16.4 MiB) failed on the read limit.
//  - documents: pages (three each: read, and the page and settings rows
//    written), content rows read, and the reference, lineup agent and
//    lineup item rows written. This keeps writes far under the document
//    limit, and caps the per-page settings reads.
// Index reads stay under Convex's 4,096: at most ~1,333 page settings
// reads, and the byte charge caps images near 550 at three reads each.
const copyMaxBytes = 12 * 1024 * 1024;
const copyMaxDocuments = 4000;
// An image's asset copy reads at most 22 asset rows (one active row, up to
// 20 legacy rows, one upload placeholder), each well under 1 KiB.
const imageCopyReadBytes = 22 * 1024;

/// Counts a copy's reads and writes against its budget, and refuses the
/// copy with [tooLarge] as soon as the budget is spent, before Convex's own
/// limits are.
export class CopyBudget {
  private bytes = copyMaxBytes;
  private documents = copyMaxDocuments;

  constructor(private readonly tooLarge: () => Error) {}

  spend(cost: { bytes?: number; documents?: number }): void {
    this.bytes -= cost.bytes ?? 0;
    this.documents -= cost.documents ?? 0;
    if (this.bytes < 0 || this.documents < 0) throw this.tooLarge();
  }

  /// Reads a query's rows, each charged its stored size. A spent budget
  /// reads nothing: copies sharing a transaction stop at the first one past
  /// it, so the reads past the budget are at most the row that spent it.
  async read<T extends Value>(rows: AsyncIterable<T>): Promise<T[]> {
    this.spend({});
    const result: T[] = [];
    for await (const row of rows) {
      this.spend({ bytes: getConvexSize(row), documents: 1 });
      result.push(row);
    }
    return result;
  }
}

/// A page's live elements and lineups, read to be copied.
export type PageToCopy = {
  elements: Doc<"elements">[];
  lineups: Doc<"lineups">[];
};

type CopiedLineupAgent = Pick<
  Doc<"lineupAgents">,
  "pageId" | "originId" | "agentType"
>;

/// Copies pages' live elements and lineups onto other pages, under copy ids
/// that keep their roots (see pageCopyId.ts), so a copied item glides from
/// its page to the copy. Reading a page charges the budget for everything
/// its copy will read and write, so a copy too large is refused before any
/// of it is written.
///
/// A copy shows the same pictures as its source: a copied placed image
/// names its source's picture (`assetId`, see
/// collectAssetIdFromElementPayload), and lineup images keep their ids.
/// Picture ids are scoped to a strategy, so within one strategy nothing
/// more is needed, however far the picture's upload has got; a copy into
/// another strategy gives it each picture once, under the same id, sharing
/// the stored bytes.
export class ContentCopy {
  /// The elements copied, and the agents of the lineups copied, for the
  /// target strategy's agent summary.
  readonly elements: ReferencingElement[] = [];
  readonly lineupAgents: CopiedLineupAgent[] = [];
  private readonly newLineupId = lineupIdMap();
  // Pictures the budget has been charged for, and those copied: pictures
  // shown on several pages are copied once.
  private readonly chargedPictureIds = new Set<string>();
  private readonly copiedPictureIds = new Set<string>();

  constructor(
    private readonly ctx: MutationCtx,
    private readonly args: {
      sourceStrategyId: Id<"strategies">;
      targetStrategyId: Id<"strategies">;
      userId: Id<"users">;
      now: number;
      budget: CopyBudget;
    },
  ) {}

  private get acrossStrategies(): boolean {
    return this.args.sourceStrategyId !== this.args.targetStrategyId;
  }

  async read(pageId: Id<"pages">): Promise<PageToCopy> {
    const { budget } = this.args;
    const elements = (
      await budget.read(
        this.ctx.db
          .query("elements")
          .withIndex("by_pageId", (q) => q.eq("pageId", pageId)),
      )
    ).filter((element) => !element.deleted);
    const lineups = (
      await budget.read(
        this.ctx.db
          .query("lineups")
          .withIndex("by_pageId", (q) => q.eq("pageId", pageId)),
      )
    ).filter((lineup) => !lineup.deleted);
    const chargePictures = (pictureIds: Iterable<string>) => {
      if (!this.acrossStrategies) return;
      for (const pictureId of pictureIds) {
        if (this.chargedPictureIds.has(pictureId)) continue;
        this.chargedPictureIds.add(pictureId);
        budget.spend({ bytes: imageCopyReadBytes });
      }
    };
    for (const element of elements) {
      const pictures = assetIdsOfRow(element);
      budget.spend({ documents: pictures.size });
      chargePictures(pictures);
    }
    for (const lineup of lineups) {
      const pictures = assetIdsOfRow(lineup);
      budget.spend({
        documents:
          pictures.size +
          lineupAgentsOf(lineup.payload).length +
          lineupGroupItems(lineup.payload).size,
      });
      chargePictures(pictures);
    }
    return { elements, lineups };
  }

  /// Writes [page]'s copy onto [pageId].
  async write(page: PageToCopy, pageId: Id<"pages">): Promise<void> {
    const { ctx } = this;
    const { targetStrategyId: strategyId, now } = this.args;
    for (const element of page.elements) {
      const publicId = pageCopyId(element.publicId, createPublicId);
      const pictureId =
        element.elementType === "image"
          ? collectAssetIdFromElementPayload(element.payload)
          : null;
      if (pictureId !== null) await this.bringPicture(pictureId);
      const copiedElement = {
        publicId,
        strategyId,
        pageId,
        elementType: element.elementType,
        payloadKind: element.payloadKind,
        payloadVersion: element.payloadVersion,
        payload: {
          ...element.payload,
          data: {
            ...element.payload.data,
            id: publicId,
            ...(pictureId === null ? {} : { assetId: pictureId }),
          },
        },
        sortIndex: element.sortIndex,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      };
      const elementId = await ctx.db.insert("elements", copiedElement);
      await insertAssetReferences(ctx, { elementId }, copiedElement);
      this.elements.push(copiedElement);
    }

    for (const lineup of page.lineups) {
      for (const pictureId of collectAssetIdsFromLineupPayload(
        lineup.payload,
      )) {
        await this.bringPicture(pictureId);
      }
      const copy = copiedLineupRow(lineup.payload, this.newLineupId);
      const copiedLineup = {
        publicId: copy.publicId,
        strategyId,
        pageId,
        payloadKind: lineup.payloadKind,
        payloadVersion: lineup.payloadVersion,
        payload: copy.payload,
        sortIndex: lineup.sortIndex,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      };
      const lineupId = await ctx.db.insert("lineups", copiedLineup);
      await insertAssetReferences(ctx, { lineupId }, copiedLineup);
      for (const agent of lineupAgentsOf(copiedLineup.payload)) {
        await ctx.db.insert("lineupAgents", {
          strategyId,
          pageId,
          lineupId,
          ...agent,
        });
        this.lineupAgents.push({ pageId, ...agent });
      }
      for (const item of lineupGroupItems(copiedLineup.payload)) {
        await ctx.db.insert("lineupItems", { pageId, lineupId, item });
      }
    }
  }

  /// Gives a copy into another strategy picture [pictureId], once. A copy
  /// within the strategy already has it.
  private async bringPicture(pictureId: string): Promise<void> {
    if (!this.acrossStrategies || this.copiedPictureIds.has(pictureId)) return;
    this.copiedPictureIds.add(pictureId);
    const copied = await copyActiveAssetToStrategy(this.ctx, {
      sourceStrategyId: this.args.sourceStrategyId,
      sourceAssetPublicId: pictureId,
      targetStrategyId: this.args.targetStrategyId,
      targetAssetPublicId: pictureId,
      userId: this.args.userId,
      now: this.args.now,
    });
    if (copied === "uploading") {
      // Throwing discards the whole copy. A retry once the upload lands
      // copies the picture instead of leaving the copy without it for good.
      throw conflictError(
        "An image in this strategy is still uploading. Try again once it finishes.",
      );
    }
  }
}

type LineupPayload = Doc<"lineups">["payload"];
type LineupData = LineupPayload["data"];

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// New ids for a copy's lineups: one map shared by every row and every id
/// in it, so one source id always becomes one copy id. Ids the source
/// repeats within a group (a landing may take its lineup's id, a link names
/// its origin and landing) repeat in the copy the same way. Each keeps its
/// root (see pageCopyId.ts), so lineups copied between the source's pages
/// are still copies of each other in the copy.
function lineupIdMap() {
  const ids = new Map<string, string>();
  return (id: string): string => {
    let next = ids.get(id);
    if (next === undefined) {
      ids.set(id, (next = pageCopyId(id, createPublicId)));
    }
    return next;
  };
}

/// A lineup group row as the copy stores it: the group, its origins,
/// landings and links under new ids, each link naming its ends' new ids and
/// each marker's `lineUpID` following its spot. Everything else is kept as
/// it is.
function copiedLineupRow(
  payload: LineupPayload,
  newId: (id: string) => string,
): { publicId: string; payload: LineupPayload } {
  const data = payload.data;
  const idOf = (value: unknown) => (typeof value === "string" ? value : "");
  const entries = (value: unknown): unknown[] =>
    Array.isArray(value) ? value : [];
  const copiedSpot = (spot: unknown, markerKey: "agent" | "ability") => {
    if (!isJsonObject(spot)) return spot;
    const id = newId(idOf(spot.id));
    const marker = spot[markerKey];
    return {
      ...spot,
      id,
      ...(isJsonObject(marker)
        ? { [markerKey]: { ...marker, lineUpID: id } }
        : {}),
    };
  };
  const copiedLink = (link: unknown) =>
    isJsonObject(link)
      ? {
          ...link,
          id: newId(idOf(link.id)),
          originId: newId(idOf(link.originId)),
          landingId: newId(idOf(link.landingId)),
        }
      : link;
  const id = newId(idOf(data.id));
  return {
    publicId: id,
    payload: {
      ...payload,
      data: {
        ...data,
        id,
        origins: entries(data.origins).map((origin) =>
          copiedSpot(origin, "agent"),
        ),
        landings: entries(data.landings).map((landing) =>
          copiedSpot(landing, "ability"),
        ),
        links: entries(data.links).map(copiedLink),
      } as LineupData,
    },
  };
}
