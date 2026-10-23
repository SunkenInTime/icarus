import { query, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import {
  assertStrategyReadable,
  getEffectiveStrategyRoleForUser,
  requireCurrentUser,
} from "./lib/auth";
import {
  clientUpgradeRequiredError,
  invalidPayloadError,
} from "./lib/errors";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import {
  elementsOnPages,
  hasTrashedPages,
  getStrategyByPublicId,
  lineupsOnPages,
  listLivePages,
  sortByNumberField,
} from "./lib/entities";
import {
  collectReferencedAssetIds,
  getViewerAssetForStrategy,
  serializeAssetForViewer,
  withPictureAliases,
} from "./lib/imageAssets";
import {
  serializeElement,
  serializeLineup,
  serializePageContent,
  serializePageDescriptor,
  serializeStrategyHeader,
} from "./lib/snapshotSerialization";
import { internalError } from "./lib/errors";
import {
  fullStrategySnapshotValidator,
  strategyHeaderValidator,
  strategyShellValidator,
} from "./lib/publicValidators";

async function getPageContent(
  ctx: QueryCtx,
  pageId: Id<"pages">,
): Promise<Doc<"pageContents">> {
  const rows = await ctx.db
    .query("pageContents")
    .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
    .take(2);
  if (rows.length !== 1) {
    throw internalError("Each page must have exactly one page content row.");
  }
  return rows[0]!;
}

export const getShell = query({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    // A share link the reader holds (see assertStrategyReadable): lets
    // someone without an account view a strategy shared with them.
    shareToken: v.optional(v.string()),
  },
  returns: strategyShellValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const role = await assertStrategyReadable(ctx, strategy, args.shareToken);
    const pages = await listLivePages(ctx, strategy._id);

    return {
      header: serializeStrategyHeader(strategy, role),
      pages: sortByNumberField(pages, "sortIndex").map((page) =>
        serializePageDescriptor(strategy.publicId, page),
      ),
    };
  },
});

export const getFullSnapshot = query({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    shareToken: v.optional(v.string()),
    // Set by clients that ask images:listReferencedAssetIds, not this
    // snapshot, whether an upload is still wanted: a snapshot that leaves
    // the trash's pages out cannot make them drop one. Older clients are
    // refused while the strategy holds trashed pages (see below).
    acceptsTrashedPagesLeftOut: v.optional(v.boolean()),
    // Set by clients that keep an image's picture id (assetId, see
    // collectAssetIdFromElementPayload). Older clients get image payloads
    // without it, as they would write them, and find pictures under each
    // image's own id (withPictureAliases).
    acceptsPictureIds: v.optional(v.boolean()),
    // Set by clients that keep an offline copy: the answer then carries the
    // strategy's content version, to compare with listContentVersions.
    includeContentVersion: v.optional(v.boolean()),
  },
  returns: fullStrategySnapshotValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const role = await assertStrategyReadable(ctx, strategy, args.shareToken);
    // An older client decides from this snapshot whether an upload is still
    // wanted. Without the trash's pages it would drop the bytes of an image
    // on a page that can be restored, so it is told to upgrade instead; its
    // upload check keeps the bytes when the read fails. A reload of the web
    // app is the upgrade.
    if (
      args.acceptsTrashedPagesLeftOut !== true &&
      (await hasTrashedPages(ctx, strategy._id))
    ) {
      throw clientUpgradeRequiredError();
    }
    // Content on a page in the trash is left out with its page.
    const pages = await listLivePages(ctx, strategy._id);
    const [elements, lineups] = await Promise.all([
      elementsOnPages(ctx, pages),
      lineupsOnPages(ctx, pages),
    ]);
    const orderedPages = sortByNumberField(pages, "sortIndex");
    const pagePublicIds = new Map(
      orderedPages.map((page) => [page._id, page.publicId]),
    );
    const pageContents = await Promise.all(
      orderedPages.map((page) => getPageContent(ctx, page._id)),
    );
    const visibleElements = elements.filter((element) =>
      pagePublicIds.has(element.pageId),
    );
    const visibleLineups = lineups.filter((lineup) =>
      pagePublicIds.has(lineup.pageId),
    );
    const referencedAssetIds = collectReferencedAssetIds(
      visibleElements,
      visibleLineups,
    );
    const assets = await Promise.all(
      [...referencedAssetIds].map((assetPublicId) =>
        getViewerAssetForStrategy(ctx, strategy._id, assetPublicId),
      ),
    );

    return {
      header: serializeStrategyHeader(strategy, role),
      pages: orderedPages.map((page, index) => {
        const content = serializePageContent(pageContents[index]!);
        return {
          ...serializePageDescriptor(strategy.publicId, page),
          settings: content.settings,
          contentRevision: content.revision,
          contentCreatedAt: content.createdAt,
          contentUpdatedAt: content.updatedAt,
        };
      }),
      elements: visibleElements
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((element) =>
          serializeElement(
            strategy.publicId,
            pagePublicIds.get(element.pageId)!,
            element,
            args.acceptsPictureIds === true,
          ),
        ),
      lineups: visibleLineups
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((lineup) =>
          serializeLineup(
            strategy.publicId,
            pagePublicIds.get(lineup.pageId)!,
            lineup,
          ),
        ),
      assets: withPictureAliases(
        await Promise.all(
          assets
            .filter((asset): asset is Doc<"imageAssets"> => asset !== null)
            .map((asset) => serializeAssetForViewer(ctx, strategy, asset)),
        ),
        visibleElements,
      ).sort((left, right) => left.publicId.localeCompare(right.publicId)),
      ...(args.includeContentVersion === true
        ? { contentVersion: await readContentVersion(ctx, strategy._id) }
        : {}),
    };
  },
});

export const MAX_CONTENT_VERSIONS_PER_QUERY = 100;

/// Whether a device's offline copies are still current, without reading
/// the strategies whole. A copy of a full read (getFullSnapshot with
/// includeContentVersion) is current while its header and content version
/// both equal the ones here: the header carries the strategy row and the
/// caller's role, and the content version goes up with every write to the
/// strategy's pages, contents, elements, lineups and images (see
/// lib/functions.ts). "gone" when the strategy is deleted or the caller can
/// no longer read it.
export const listContentVersions = query({
  args: {
    ...cloudProtocolArgs,
    strategyPublicIds: v.array(v.string()),
  },
  returns: v.array(
    v.union(
      v.object({
        strategyPublicId: v.string(),
        status: v.literal("found"),
        header: strategyHeaderValidator,
        contentVersion: v.number(),
      }),
      v.object({
        strategyPublicId: v.string(),
        status: v.literal("gone"),
      }),
    ),
  ),
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    if (args.strategyPublicIds.length > MAX_CONTENT_VERSIONS_PER_QUERY) {
      throw invalidPayloadError(
        `Ask about at most ${MAX_CONTENT_VERSIONS_PER_QUERY} strategies at once.`,
      );
    }
    const user = await requireCurrentUser(ctx);
    return await Promise.all(
      args.strategyPublicIds.map(async (strategyPublicId) => {
        const strategy = await ctx.db
          .query("strategies")
          .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
          .first();
        const role =
          strategy === null
            ? null
            : await getEffectiveStrategyRoleForUser(ctx, strategy, user._id);
        if (strategy === null || role === null) {
          return { strategyPublicId, status: "gone" as const };
        }
        return {
          strategyPublicId,
          status: "found" as const,
          header: serializeStrategyHeader(strategy, role),
          contentVersion: await readContentVersion(ctx, strategy._id),
        };
      }),
    );
  },
});

async function readContentVersion(
  ctx: QueryCtx,
  strategyId: Id<"strategies">,
): Promise<number> {
  const counted = await ctx.db
    .query("strategyContentVersions")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .unique();
  return counted?.version ?? 0;
}
