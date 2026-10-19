import { query, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { assertStrategyReadable } from "./lib/auth";
import { getPageByPublicId, getStrategyByPublicId } from "./lib/entities";
import { errorWithCode, internalError } from "./lib/errors";
import {
  collectReferencedAssetIds,
  getViewerAssetForStrategy,
  pictureAliases,
  serializeAssetForViewer,
  withPictureAliases,
} from "./lib/imageAssets";
import {
  serializeElement,
  serializeLineup,
  serializePageContent,
  serializePageDescriptor,
} from "./lib/snapshotSerialization";
import {
  pageElementSliceValidator,
  pageFrameValidator,
  pageSnapshotValidator,
} from "./lib/publicValidators";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";

const pageArgs = {
  ...cloudProtocolArgs,
  strategyPublicId: v.string(),
  pagePublicId: v.string(),
  shareToken: v.optional(v.string()),
  // Set by clients that keep an image's picture id (assetId, see
  // collectAssetIdFromElementPayload). Older clients get image payloads
  // without it, as they would write them, and find pictures under each
  // image's own id (withPictureAliases).
  acceptsPictureIds: v.optional(v.boolean()),
};

/// The page [args] names, once the caller may read its strategy.
async function readablePage(
  ctx: QueryCtx,
  args: {
    clientProtocolVersion: number;
    strategyPublicId: string;
    pagePublicId: string;
    shareToken?: string;
  },
) {
  assertSupportedCloudProtocol(args.clientProtocolVersion);
  const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
  await assertStrategyReadable(ctx, strategy, args.shareToken);
  const page = await getPageByPublicId(ctx, args.pagePublicId);
  if (page.strategyId !== strategy._id) {
    throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
  }
  return { strategy, page };
}

async function pageContentOf(ctx: QueryCtx, page: Doc<"pages">) {
  const pageContents = await ctx.db
    .query("pageContents")
    .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
    .take(2);
  if (pageContents.length !== 1) {
    throw internalError("Each page must have exactly one page content row.");
  }
  return pageContents[0]!;
}

/// The images [elements] and [lineups] show, as a viewer of [strategy] gets
/// them.
async function viewerAssets(
  ctx: QueryCtx,
  strategy: Doc<"strategies">,
  elements: Doc<"elements">[],
  lineups: Doc<"lineups">[],
) {
  const assets = await Promise.all(
    [...collectReferencedAssetIds(elements, lineups)].map((assetPublicId) =>
      getViewerAssetForStrategy(ctx, strategy._id, assetPublicId),
    ),
  );
  return await Promise.all(
    assets
      .filter((asset): asset is Doc<"imageAssets"> => asset !== null)
      .map((asset) => serializeAssetForViewer(ctx, asset)),
  );
}

export const getSnapshot = query({
  args: pageArgs,
  returns: pageSnapshotValidator,
  handler: async (ctx, args) => {
    const { strategy, page } = await readablePage(ctx, args);
    const [content, elements, lineups] = await Promise.all([
      pageContentOf(ctx, page),
      ctx.db
        .query("elements")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
      ctx.db
        .query("lineups")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
    ]);

    return {
      page: serializePageDescriptor(strategy.publicId, page),
      content: serializePageContent(content),
      elements: elements
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((element) =>
          serializeElement(
            strategy.publicId,
            page.publicId,
            element,
            args.acceptsPictureIds === true,
          ),
        ),
      lineups: lineups
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((lineup) =>
          serializeLineup(strategy.publicId, page.publicId, lineup),
        ),
      assets: withPictureAliases(
        await viewerAssets(ctx, strategy, elements, lineups),
        elements,
      ).sort((left, right) => left.publicId.localeCompare(right.publicId)),
    };
  },
});

// A live page read in parts. Convex re-runs a live query in full whenever a
// row it read is written, so one query over the whole page re-reads every
// row after every edit. Read as a frame plus element slices, an edit
// re-runs only the slice holding the row it touched. Each part is complete
// for what it covers, so a row that moves, goes or comes back simply leaves
// or enters its slice.

/// The page without its elements: the page, its settings, its lineups and
/// the images they show.
export const getFrame = query({
  args: pageArgs,
  returns: pageFrameValidator,
  handler: async (ctx, args) => {
    const { strategy, page } = await readablePage(ctx, args);
    const [content, lineups] = await Promise.all([
      pageContentOf(ctx, page),
      ctx.db
        .query("lineups")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
    ]);
    return {
      page: serializePageDescriptor(strategy.publicId, page),
      content: serializePageContent(content),
      lineups: lineups.map((lineup) =>
        serializeLineup(strategy.publicId, page.publicId, lineup),
      ),
      assets: await viewerAssets(ctx, strategy, [], lineups),
    };
  },
});

/// The page's elements whose public id is at least [fromPublicId] and, when
/// given, below [toPublicId], with the images they show. Slices whose ranges
/// cover every id hold every element of the page; ids sort as strings.
export const getElementSlice = query({
  args: {
    ...pageArgs,
    fromPublicId: v.string(),
    toPublicId: v.optional(v.string()),
  },
  returns: pageElementSliceValidator,
  handler: async (ctx, args) => {
    const { strategy, page } = await readablePage(ctx, args);
    const { fromPublicId, toPublicId } = args;
    const elements = await ctx.db
      .query("elements")
      .withIndex("by_pageId_and_publicId", (q) => {
        const from = q.eq("pageId", page._id).gte("publicId", fromPublicId);
        return toPublicId === undefined ? from : from.lt("publicId", toPublicId);
      })
      .collect();
    const assets = await viewerAssets(ctx, strategy, elements, []);
    return {
      elements: elements.map((element) =>
        serializeElement(
          strategy.publicId,
          page.publicId,
          element,
          args.acceptsPictureIds === true,
        ),
      ),
      assets,
      aliases: pictureAliases(assets, elements),
    };
  },
});
