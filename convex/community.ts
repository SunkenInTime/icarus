import { makeFunctionReference } from "convex/server";
import { v } from "convex/values";
import { internalAction, query } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { internalMutation, mutation } from "./lib/functions";
import { assertStrategyRole, requireCurrentUser } from "./lib/auth";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import {
  authorOf,
  COMMUNITY_TOKEN_PREFIX,
  communityOwnerId,
  COPIES_PER_HOUR,
  currentUserOrNull,
  DAY_MS,
  FEED_PAGE_ROWS,
  getPostByPublicId,
  HOUR_MS,
  isBanned,
  isReviewer,
  MAX_LIVE_POSTS_PER_AUTHOR,
  MAX_REPORT_NOTE_LENGTH,
  normalizedTitle,
  POSTS_PER_HOUR,
  postCard,
  postCardValidator,
  postSideValidator,
  postStatusValidator,
  REPORTS_PER_DAY,
  REPORTS_TO_HIDE,
  reportReasonValidator,
  searchTextOf,
  sideOf,
  TRENDING_WINDOW_MS,
} from "./lib/community";
import { createPublicId } from "./lib/contentCopy";
import { readContentVersion } from "./lib/contentVersions";
import {
  assertMoveFinished,
  getStrategyByPublicId,
  livePagesQuery,
} from "./lib/entities";
import {
  conflictError,
  errorWithCode,
  forbiddenError,
  invalidPayloadError,
  notFoundError,
  rateLimitedError,
} from "./lib/errors";
import { assertSafeFileNameId } from "./lib/fileNameIds";
import { assertKnownMapChange } from "./lib/maps";
import { createResultValidator, okResultValidator } from "./lib/publicValidators";
import { readStrategyAgentTypes } from "./lib/strategyAgentSummary";
import { copyStrategy, deleteStrategyRecord } from "./lib/strategyCopy";
import {
  continueFolding,
  startFolding,
  sweepFolding,
  type FoldLeft,
} from "./lib/foldChains";

export const foldCountChangesRef = makeFunctionReference<"mutation">(
  "community:foldCountChanges",
);
export const refreshTrendingRef = makeFunctionReference<"mutation">(
  "community:refreshTrending",
);
const notifyReviewersRef = makeFunctionReference<"action">(
  "community:notifyReviewers",
);

/// Where a post opens on the web, for the reviewers' message.
const POST_LINK_ORIGIN = "https://icarusstrats.com";

const tooLargeToPost = () =>
  errorWithCode(
    "STRATEGY_TOO_LARGE_TO_DUPLICATE",
    "This strategy is too large to post.",
  );

/**
 * One page of the feed. Reads only post rows and never the caller, so every
 * reader asking for the same page shares one cached result, and a star
 * changes nothing here until the counts are folded in.
 *
 * Map and sort pick an index; side and agents are applied to the rows read,
 * so a page can hold fewer than it read. Pass [nextCursor] back for the next
 * page; null means the feed has no more.
 */
export const listPosts = query({
  args: {
    sort: v.union(v.literal("trending"), v.literal("new"), v.literal("top")),
    mapData: v.optional(v.string()),
    side: v.optional(v.union(v.literal("attack"), v.literal("defense"))),
    agentTypes: v.optional(v.array(v.string())),
    text: v.optional(v.string()),
    cursor: v.optional(v.string()),
  },
  returns: v.object({
    posts: v.array(postCardValidator),
    nextCursor: v.union(v.string(), v.null()),
  }),
  handler: async (ctx, args) => {
    const agents = args.agentTypes ?? [];
    if (agents.length > 6) {
      throw invalidPayloadError("Filter by at most six agents.");
    }
    const text = args.text?.trim().toLowerCase() ?? "";
    if (text.length > 80) {
      throw invalidPayloadError("Search for at most 80 characters.");
    }
    const map = args.mapData;
    const posts = ctx.db.query("communityPosts");
    const source =
      text.length > 0
        ? posts.withSearchIndex("search_text", (q) => {
            const listed = q.search("searchText", text).eq("status", "listed");
            return map === undefined ? listed : listed.eq("mapData", map);
          })
        : map === undefined
          ? args.sort === "new"
            ? posts
                .withIndex("by_status_and_publishedAt", (q) =>
                  q.eq("status", "listed"),
                )
                .order("desc")
            : args.sort === "top"
              ? posts
                  .withIndex("by_status_and_starCount_and_publishedAt", (q) =>
                    q.eq("status", "listed"),
                  )
                  .order("desc")
              : posts
                  .withIndex("by_status_and_trendScore_and_publishedAt", (q) =>
                    q.eq("status", "listed"),
                  )
                  .order("desc")
          : args.sort === "new"
            ? posts
                .withIndex("by_status_and_mapData_and_publishedAt", (q) =>
                  q.eq("status", "listed").eq("mapData", map),
                )
                .order("desc")
            : args.sort === "top"
              ? posts
                  .withIndex(
                    "by_status_and_mapData_and_starCount_and_publishedAt",
                    (q) => q.eq("status", "listed").eq("mapData", map),
                  )
                  .order("desc")
              : posts
                  .withIndex(
                    "by_status_and_mapData_and_trendScore_and_publishedAt",
                    (q) => q.eq("status", "listed").eq("mapData", map),
                  )
                  .order("desc");
    const page = await source.paginate({
      numItems: FEED_PAGE_ROWS,
      cursor: args.cursor ?? null,
    });
    const matches = page.page.filter(
      (post) =>
        (args.side === undefined ||
          post.side === args.side ||
          post.side === "mixed") &&
        agents.every((agent) => post.agentTypes.includes(agent)),
    );
    return {
      posts: matches.map(postCard),
      nextCursor: page.isDone ? null : page.continueCursor,
    };
  },
});

/// One post, for a link to it or to refresh one on screen. Null when no
/// post has [postPublicId].
export const getPost = query({
  args: { postPublicId: v.string() },
  returns: v.union(
    v.null(),
    v.object({ post: postCardValidator, status: postStatusValidator }),
  ),
  handler: async (ctx, args) => {
    const post = await ctx.db
      .query("communityPosts")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.postPublicId))
      .unique();
    if (post === null) return null;
    if (post.status === "hidden") {
      // Out of sight until a reviewer decides, link included: reviewers
      // read it through the link only they are given.
      if (post.reviewToken === undefined || !(await isReviewer(ctx))) {
        return null;
      }
      return {
        post: { ...postCard(post), shareToken: post.reviewToken },
        status: post.status,
      };
    }
    return { post: postCard(post), status: post.status };
  },
});

/// The posts the caller starred, newest first. Empty when signed out.
export const listMyStars = query({
  args: {},
  returns: v.array(v.string()),
  handler: async (ctx) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) return [];
    const stars = await ctx.db
      .query("communityStars")
      .withIndex("by_userId", (q) => q.eq("userId", user._id))
      .order("desc")
      .take(2000);
    return stars.map((star) => star.postPublicId);
  },
});

/// The caller's copies of posts that are still in their library, newest
/// first: which post each came from. Read once per sign-in; the app adds
/// the copies it makes after.
export const listMyCopies = query({
  args: {},
  returns: v.array(
    v.object({ strategyPublicId: v.string(), postPublicId: v.string() }),
  ),
  handler: async (ctx) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) return [];
    const copies = await ctx.db
      .query("communityCopies")
      .withIndex("by_userId_and_createdAt", (q) => q.eq("userId", user._id))
      .order("desc")
      .take(500);
    const kept: { strategyPublicId: string; postPublicId: string }[] = [];
    for (const copy of copies) {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) =>
          q.eq("publicId", copy.strategyPublicId),
        )
        .first();
      if (strategy !== null && strategy.ownerId === user._id) {
        kept.push({
          strategyPublicId: copy.strategyPublicId,
          postPublicId: copy.postPublicId,
        });
      }
    }
    return kept;
  },
});

/// The posts the caller starred that are still up, most recently starred
/// first, narrowed like the feed. A page at a time.
export const listStarred = query({
  args: {
    mapData: v.optional(v.string()),
    side: v.optional(v.union(v.literal("attack"), v.literal("defense"))),
    agentTypes: v.optional(v.array(v.string())),
    text: v.optional(v.string()),
    cursor: v.optional(v.string()),
  },
  returns: v.object({
    posts: v.array(postCardValidator),
    nextCursor: v.union(v.string(), v.null()),
  }),
  handler: async (ctx, args) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) return { posts: [], nextCursor: null };
    const agents = args.agentTypes ?? [];
    if (agents.length > 6) {
      throw invalidPayloadError("Filter by at most six agents.");
    }
    const text = args.text?.trim().toLowerCase() ?? "";
    if (text.length > 80) {
      throw invalidPayloadError("Search for at most 80 characters.");
    }
    const page = await ctx.db
      .query("communityStars")
      .withIndex("by_userId", (q) => q.eq("userId", user._id))
      .order("desc")
      .paginate({ numItems: FEED_PAGE_ROWS, cursor: args.cursor ?? null });
    const posts: Doc<"communityPosts">[] = [];
    for (const star of page.page) {
      const post = await ctx.db.get(star.postId);
      if (
        post !== null &&
        post.status === "listed" &&
        (args.mapData === undefined || post.mapData === args.mapData) &&
        (args.side === undefined ||
          post.side === args.side ||
          post.side === "mixed") &&
        agents.every((agent) => post.agentTypes.includes(agent)) &&
        (text.length === 0 || post.searchText.includes(text))
      ) {
        posts.push(post);
      }
    }
    return {
      posts: posts.map(postCard),
      nextCursor: page.isDone ? null : page.continueCursor,
    };
  },
});

/// The caller's own posts that are not taken down, newest first, for the
/// Posted badge in their library and the post's dialog.
export const listMine = query({
  args: {},
  returns: v.array(
    v.object({
      post: postCardValidator,
      status: postStatusValidator,
      sourceStrategyPublicId: v.string(),
      copyCount: v.number(),
      updatedAt: v.number(),
    }),
  ),
  handler: async (ctx) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) return [];
    const posts = await livePostsBy(ctx, user._id);
    return posts
      .sort((a, b) => b._creationTime - a._creationTime)
      .map((post) => ({
        post: postCard(post),
        status: post.status,
        sourceStrategyPublicId: post.sourceStrategyPublicId,
        copyCount: post.copyCount,
        updatedAt: post.updatedAt,
      }));
  },
});

/// Whether the strategy a post was copied from has changed its content, map
/// or theme since the post was last updated. Its author only; read once when
/// they open the post's dialog, since it reads the strategy's content version.
export const getSourceChanged = query({
  args: { postPublicId: v.string() },
  returns: v.object({ sourceExists: v.boolean(), changed: v.boolean() }),
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const post = await getPostByPublicId(ctx, args.postPublicId);
    if (post.authorId !== user._id) throw forbiddenError();
    const source = await ctx.db.get(post.sourceStrategyId);
    if (source === null) return { sourceExists: false, changed: false };
    const version = await readContentVersion(ctx, source._id);
    const snapshot =
      post.snapshotStrategyId === undefined
        ? null
        : await ctx.db.get(post.snapshotStrategyId);
    return {
      sourceExists: true,
      changed:
        version !== post.sourceContentVersion ||
        (snapshot !== null && !sameMapAndTheme(source, snapshot)),
    };
  },
});

function sameMapAndTheme(a: Doc<"strategies">, b: Doc<"strategies">) {
  const paletteA = a.themeOverridePalette;
  const paletteB = b.themeOverridePalette;
  return (
    a.mapData === b.mapData &&
    a.themeProfileId === b.themeProfileId &&
    paletteA?.base === paletteB?.base &&
    paletteA?.detail === paletteB?.detail &&
    paletteA?.highlight === paletteB?.highlight
  );
}

/// The caller's own strategies, most recently changed first, to pick one
/// to post. Read once when the picker opens.
export const listPostable = query({
  args: {},
  returns: v.array(
    v.object({
      strategyPublicId: v.string(),
      name: v.string(),
      mapData: v.string(),
      updatedAt: v.number(),
      postPublicId: v.union(v.string(), v.null()),
    }),
  ),
  handler: async (ctx) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) return [];
    const strategies = (
      await ctx.db
        .query("strategies")
        .withIndex("by_ownerId_and_folderId_and_unfinishedMove", (q) =>
          q.eq("ownerId", user._id),
        )
        .take(2000)
    ).filter((strategy) => strategy.unfinishedMove === undefined);
    const posts = await livePostsBy(ctx, user._id);
    const postBySource = new Map<string, string>();
    for (const post of posts) {
      postBySource.set(post.sourceStrategyId, post.publicId);
    }
    return strategies
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .slice(0, 200)
      .map((strategy) => ({
        strategyPublicId: strategy.publicId,
        name: strategy.name,
        mapData: strategy.mapData,
        updatedAt: strategy.updatedAt,
        postPublicId: postBySource.get(strategy._id) ?? null,
      }));
  },
});

/// What a post of the caller's strategy [strategyPublicId] would show on
/// its card, for the posting dialog's preview. Read once as it opens.
export const getPostPreview = query({
  args: { strategyPublicId: v.string() },
  returns: v.object({
    name: v.string(),
    mapData: v.string(),
    side: postSideValidator,
    agentTypes: v.array(v.string()),
  }),
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "owner");
    const [pages, agentTypes] = await Promise.all([
      livePagesQuery(ctx, strategy._id).take(100),
      readStrategyAgentTypes(ctx, strategy._id),
    ]);
    return {
      name: strategy.name,
      mapData: strategy.mapData,
      side: sideOf(pages.map((page) => page.isAttack)),
      agentTypes,
    };
  },
});

export const getViewer = query({
  args: {},
  returns: v.object({
    isReviewer: v.boolean(),
    canPost: v.boolean(),
    // The name a post of theirs would show, so they see it before posting.
    authorName: v.union(v.string(), v.null()),
  }),
  handler: async (ctx) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) {
      return { isReviewer: false, canPost: false, authorName: null };
    }
    return {
      isReviewer: await isReviewer(ctx),
      canPost: !(await isBanned(ctx, user._id)),
      authorName: authorOf(user).authorName,
    };
  },
});

/// Posts the caller's strategy [strategyPublicId] as it is now, as
/// [postPublicId]. The post shows a copy, so what they change afterwards
/// stays theirs until they update the post. A retry with the same
/// [postPublicId] finds the post already made.
export const publish = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    postPublicId: v.string(),
    title: v.string(),
  },
  returns: v.object({ ok: v.literal(true), postPublicId: v.string() }),
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    assertSafeFileNameId("Post id", args.postPublicId);
    const source = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user } = await assertStrategyRole(ctx, source, "owner");
    const retried = await ctx.db
      .query("communityPosts")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.postPublicId))
      .unique();
    if (retried !== null) {
      if (retried.authorId !== user._id) {
        throw conflictError(`Post id already exists: ${args.postPublicId}`);
      }
      return { ok: true, postPublicId: retried.publicId } as const;
    }
    assertMoveFinished(source);
    assertKnownMapChange(source.mapData, undefined);
    if (await isBanned(ctx, user._id)) throw forbiddenError();
    const title = normalizedTitle(args.title);

    const posted = await ctx.db
      .query("communityPosts")
      .withIndex("by_sourceStrategyId", (q) =>
        q.eq("sourceStrategyId", source._id),
      )
      .collect();
    if (posted.some((post) => post.status !== "removed")) {
      throw conflictError("This strategy is already posted.");
    }
    const livePosts = (await livePostsBy(ctx, user._id)).length;
    if (livePosts >= MAX_LIVE_POSTS_PER_AUTHOR) {
      throw invalidPayloadError(
        `You can have at most ${MAX_LIVE_POSTS_PER_AUTHOR} posts at a time.`,
      );
    }
    const now = Date.now();
    // Taken-down posts count too, or posting and taking down would get past.
    const recentPosts = await ctx.db
      .query("communityPosts")
      .withIndex("by_authorId_and_publishedAt", (q) =>
        q.eq("authorId", user._id).gt("publishedAt", now - HOUR_MS),
      )
      .take(POSTS_PER_HOUR);
    if (recentPosts.length >= POSTS_PER_HOUR) {
      throw rateLimitedError(
        "You've posted a lot in the last hour. Try again later.",
      );
    }

    const snapshot = await takeSnapshot(ctx, source, title, user._id);
    const author = authorOf(user);
    const postPublicId = args.postPublicId;
    await ctx.db.insert("communityPosts", {
      publicId: postPublicId,
      authorId: user._id,
      ...author,
      sourceStrategyId: source._id,
      sourceStrategyPublicId: source.publicId,
      sourceContentVersion: await readContentVersion(ctx, source._id),
      snapshotStrategyId: snapshot.strategyId,
      snapshotStrategyPublicId: snapshot.publicId,
      shareToken: snapshot.shareToken,
      title,
      searchText: searchTextOf(title, author.authorName),
      mapData: source.mapData,
      side: sideOf(snapshot.pageIsAttack),
      agentTypes: snapshot.agentTypes,
      pageCount: snapshot.pageIsAttack.length,
      lineupCount: snapshot.lineupCount,
      status: "listed",
      starCount: 0,
      copyCount: 0,
      trendScore: 0,
      reportCount: 0,
      publishedAt: now,
      updatedAt: now,
    });
    return { ok: true, postPublicId } as const;
  },
});

/// Changes the caller's post: its title, and with [refresh] what it shows,
/// copied again from their strategy as it is now. Stars, copies and reports
/// stay with the post.
export const updatePost = mutation({
  args: {
    ...cloudProtocolArgs,
    postPublicId: v.string(),
    title: v.optional(v.string()),
    refresh: v.optional(v.boolean()),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const post = await getPostByPublicId(ctx, args.postPublicId);
    if (post.authorId !== user._id) throw forbiddenError();
    if (post.status === "removed" || post.snapshotStrategyId === undefined) {
      throw notFoundError("Post", args.postPublicId);
    }
    // What reviewers are deciding on stays as it was reported.
    if (post.status === "hidden") {
      throw conflictError("This post is being reviewed and can't be changed.");
    }
    // A ban stops the author changing what their other posts show, too.
    if (await isBanned(ctx, user._id)) throw forbiddenError();
    const title =
      args.title === undefined ? post.title : normalizedTitle(args.title);
    const author = authorOf(user);
    const patch: Partial<Doc<"communityPosts">> = {
      ...author,
      title,
      searchText: searchTextOf(title, author.authorName),
      updatedAt: Date.now(),
    };

    if (args.refresh === true) {
      const source = await ctx.db.get(post.sourceStrategyId);
      if (source === null) {
        throw notFoundError("Strategy", post.sourceStrategyPublicId);
      }
      await assertStrategyRole(ctx, source, "owner");
      assertMoveFinished(source);
      assertKnownMapChange(source.mapData, undefined);
      const old = await ctx.db.get(post.snapshotStrategyId);
      const snapshot = await takeSnapshot(ctx, source, title, user._id, {
        replacing: old,
        shareToken: post.shareToken,
      });
      if (old !== null) await deleteStrategyRecord(ctx, old);
      Object.assign(patch, {
        sourceContentVersion: await readContentVersion(ctx, source._id),
        snapshotStrategyId: snapshot.strategyId,
        snapshotStrategyPublicId: snapshot.publicId,
        shareToken: snapshot.shareToken,
        mapData: source.mapData,
        side: sideOf(snapshot.pageIsAttack),
        agentTypes: snapshot.agentTypes,
        pageCount: snapshot.pageIsAttack.length,
        lineupCount: snapshot.lineupCount,
      });
    } else if (title !== post.title) {
      await ctx.db.patch(post.snapshotStrategyId, { name: title });
    }
    // What a reviewer cleared is no longer what the post shows, so reports
    // hide it again; enough already waiting hide it now.
    const changed = args.refresh === true || title !== post.title;
    const lapsed = changed && post.clearedAt !== undefined;
    if (lapsed) patch.clearedAt = undefined;
    await ctx.db.patch(post._id, patch);
    if (lapsed && post.reportCount >= REPORTS_TO_HIDE) {
      const updated = await ctx.db.get(post._id);
      if (updated !== null) {
        await hidePost(ctx, updated);
        await ctx.scheduler.runAfter(0, notifyReviewersRef, {
          postPublicId: updated.publicId,
          title: updated.title,
          authorName: updated.authorName,
          reportCount: updated.reportCount,
          hidden: true,
        });
      }
    }
    return { ok: true } as const;
  },
});

/// Takes a post down: its link stops working and it leaves the feed.
/// Copies people made stay theirs. Its author or a reviewer; while reports
/// have it hidden, a reviewer only.
export const takeDown = mutation({
  args: { ...cloudProtocolArgs, postPublicId: v.string() },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const post = await getPostByPublicId(ctx, args.postPublicId);
    const reviewer = await isReviewer(ctx);
    if (post.authorId !== user._id && !reviewer) throw forbiddenError();
    // Taking a reported post down and posting it again would skip the
    // review, so while it is hidden only a reviewer takes it down.
    if (post.status === "hidden" && !reviewer) {
      throw conflictError(
        "This post is being reviewed and can't be taken down.",
      );
    }
    await removePost(ctx, post);
    return { ok: true } as const;
  },
});

/// Stars or unstars a post for the caller. Doing what is already done does
/// nothing. The post's count catches up within a few minutes.
export const setStar = mutation({
  args: {
    ...cloudProtocolArgs,
    postPublicId: v.string(),
    starred: v.boolean(),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const post = await getPostByPublicId(ctx, args.postPublicId);
    const existing = await ctx.db
      .query("communityStars")
      .withIndex("by_postId_and_userId", (q) =>
        q.eq("postId", post._id).eq("userId", user._id),
      )
      .first();
    if (args.starred && existing === null) {
      if (post.status !== "listed") {
        throw notFoundError("Post", args.postPublicId);
      }
      await ctx.db.insert("communityStars", {
        postId: post._id,
        postPublicId: post.publicId,
        userId: user._id,
        createdAt: Date.now(),
      });
      await recordCountChange(ctx, {
        postId: post._id,
        stars: 1,
        copies: 0,
      });
    } else if (!args.starred && existing !== null) {
      await ctx.db.delete(existing._id);
      await recordCountChange(ctx, {
        postId: post._id,
        stars: -1,
        copies: 0,
      });
    }
    return { ok: true } as const;
  },
});

/// Copies a post into the caller's library as a strategy of their own,
/// named after the post, in [folderPublicId] when that folder is theirs.
/// [publicId] names the new strategy; a retry with the same one is safe.
export const copyPost = mutation({
  args: {
    ...cloudProtocolArgs,
    postPublicId: v.string(),
    publicId: v.string(),
    folderPublicId: v.optional(v.string()),
  },
  returns: createResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    assertSafeFileNameId("Strategy id", args.publicId);
    const user = await requireCurrentUser(ctx);
    const existing = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
      .first();
    if (existing !== null) {
      if (existing.ownerId === user._id) {
        return { ok: true, reused: true } as const;
      }
      throw conflictError(`Strategy publicId already exists: ${args.publicId}`);
    }
    const post = await getPostByPublicId(ctx, args.postPublicId);
    const snapshot =
      post.snapshotStrategyId === undefined
        ? null
        : await ctx.db.get(post.snapshotStrategyId);
    if (post.status !== "listed" || snapshot === null) {
      throw notFoundError("Post", args.postPublicId);
    }
    const now = Date.now();
    const recentCopies = await ctx.db
      .query("communityCopies")
      .withIndex("by_userId_and_createdAt", (q) =>
        q.eq("userId", user._id).gt("createdAt", now - HOUR_MS),
      )
      .take(COPIES_PER_HOUR);
    if (recentCopies.length >= COPIES_PER_HOUR) {
      throw rateLimitedError(
        "You've made a lot of copies in the last hour. Try again later.",
      );
    }
    const folder =
      args.folderPublicId === undefined
        ? null
        : await ctx.db
            .query("folders")
            .withIndex("by_publicId", (q) =>
              q.eq("publicId", args.folderPublicId!),
            )
            .first();
    await copyStrategy(
      ctx,
      snapshot,
      {
        publicId: args.publicId,
        ownerId: user._id,
        folderId: folder?.ownerId === user._id ? folder._id : undefined,
        name: post.title,
        userId: user._id,
      },
      () =>
        errorWithCode(
          "STRATEGY_TOO_LARGE_TO_DUPLICATE",
          "This strategy is too large to copy.",
        ),
    );
    // A copy counts once per account, however many it makes, and never
    // the author's own.
    const earlier = await ctx.db
      .query("communityCopies")
      .withIndex("by_postId_and_userId", (q) =>
        q.eq("postId", post._id).eq("userId", user._id),
      )
      .first();
    const counted = earlier === null && post.authorId !== user._id;
    await ctx.db.insert("communityCopies", {
      userId: user._id,
      postId: post._id,
      postPublicId: post.publicId,
      strategyPublicId: args.publicId,
      counted,
      createdAt: now,
    });
    if (counted) {
      await recordCountChange(ctx, {
        postId: post._id,
        stars: 0,
        copies: 1,
      });
    }
    return { ok: true } as const;
  },
});

/// Reports a post. One report per account per post; reporting again
/// changes nothing. The author is never told who reported it. Enough
/// reports take it out of the feed until a reviewer looks.
export const report = mutation({
  args: {
    ...cloudProtocolArgs,
    postPublicId: v.string(),
    reason: reportReasonValidator,
    note: v.optional(v.string()),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const post = await getPostByPublicId(ctx, args.postPublicId);
    const note = args.note?.trim() ?? "";
    if (note.length > MAX_REPORT_NOTE_LENGTH) {
      throw invalidPayloadError(
        `A report note is at most ${MAX_REPORT_NOTE_LENGTH} characters.`,
      );
    }
    if (post.status === "removed") return { ok: true } as const;
    const existing = await ctx.db
      .query("communityReports")
      .withIndex("by_postId_and_reporterId", (q) =>
        q.eq("postId", post._id).eq("reporterId", user._id),
      )
      .first();
    if (existing !== null) return { ok: true } as const;
    const now = Date.now();
    const recentReports = await ctx.db
      .query("communityReports")
      .withIndex("by_reporterId_and_createdAt", (q) =>
        q.eq("reporterId", user._id).gt("createdAt", now - DAY_MS),
      )
      .take(REPORTS_PER_DAY);
    if (recentReports.length >= REPORTS_PER_DAY) {
      throw rateLimitedError(
        "You've sent a lot of reports today. Try again later.",
      );
    }
    await ctx.db.insert("communityReports", {
      postId: post._id,
      reporterId: user._id,
      reason: args.reason,
      ...(note.length === 0 ? {} : { note }),
      createdAt: now,
    });
    const reportCount = post.reportCount + 1;
    await ctx.db.patch(post._id, { reportCount });
    if (post.status !== "listed" || reportCount !== REPORTS_TO_HIDE) {
      return { ok: true } as const;
    }
    // A post a reviewer put back stays up; the reviewers are told it is
    // being reported again and decide.
    const hidden = post.clearedAt === undefined;
    if (hidden) await hidePost(ctx, post);
    await ctx.scheduler.runAfter(0, notifyReviewersRef, {
      postPublicId: post.publicId,
      title: post.title,
      authorName: post.authorName,
      reportCount,
      hidden,
    });
    return { ok: true } as const;
  },
});

/// Posts waiting for a reviewer: those reports hid, oldest post first, each
/// with the link only reviewers are given; then posts a reviewer put back
/// that are reported enough again, most reported first, with their ordinary
/// link since they are still up. Reviewers only.
export const listForReview = query({
  args: {},
  returns: v.array(
    v.object({
      post: postCardValidator,
      reportCount: v.number(),
      hidden: v.boolean(),
    }),
  ),
  handler: async (ctx) => {
    if (!(await isReviewer(ctx))) throw forbiddenError();
    const hidden = await ctx.db
      .query("communityPosts")
      .withIndex("by_status_and_publishedAt", (q) => q.eq("status", "hidden"))
      .take(100);
    // Only a cleared post stays listed with this many reports.
    const reportedAgain = await ctx.db
      .query("communityPosts")
      .withIndex("by_status_and_reportCount", (q) =>
        q.eq("status", "listed").gte("reportCount", REPORTS_TO_HIDE),
      )
      .order("desc")
      .take(100);
    return [
      ...hidden.map((post) => ({
        post: {
          ...postCard(post),
          shareToken: post.reviewToken ?? post.shareToken,
        },
        reportCount: post.reportCount,
        hidden: true,
      })),
      ...reportedAgain.map((post) => ({
        post: postCard(post),
        reportCount: post.reportCount,
        hidden: false,
      })),
    ];
  },
});

/// A post's reports, grouped by reason with what reporters wrote, for a
/// reviewer deciding on it. Reviewers only.
export const getReports = query({
  args: { postPublicId: v.string() },
  returns: v.array(
    v.object({
      reason: reportReasonValidator,
      count: v.number(),
      notes: v.array(v.string()),
    }),
  ),
  handler: async (ctx, args) => {
    if (!(await isReviewer(ctx))) throw forbiddenError();
    const post = await getPostByPublicId(ctx, args.postPublicId);
    const reports = await ctx.db
      .query("communityReports")
      .withIndex("by_postId_and_reporterId", (q) => q.eq("postId", post._id))
      .take(500);
    const byReason = new Map<
      Doc<"communityReports">["reason"],
      { count: number; notes: string[] }
    >();
    for (const report of reports) {
      const entry = byReason.get(report.reason) ?? { count: 0, notes: [] };
      entry.count += 1;
      if (report.note !== undefined) entry.notes.push(report.note);
      byReason.set(report.reason, entry);
    }
    return [...byReason.entries()]
      .sort((a, b) => b[1].count - a[1].count)
      .map(([reason, entry]) => ({ reason, ...entry }));
  },
});

/// A reviewer's decision on a reported post. restore puts it back in the
/// feed (or keeps it there), clears its reports and marks it cleared, so
/// more reports tell the reviewers instead of hiding it again; remove takes
/// it down; ban also stops its author posting.
export const review = mutation({
  args: {
    ...cloudProtocolArgs,
    postPublicId: v.string(),
    decision: v.union(
      v.literal("restore"),
      v.literal("remove"),
      v.literal("ban"),
    ),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    await requireCurrentUser(ctx);
    if (!(await isReviewer(ctx))) throw forbiddenError();
    const post = await getPostByPublicId(ctx, args.postPublicId);
    if (args.decision === "restore") {
      if (post.status === "removed") {
        throw notFoundError("Post", args.postPublicId);
      }
      await clearReports(ctx, post._id);
      await relistPost(ctx, post);
      await ctx.db.patch(post._id, { reportCount: 0, clearedAt: Date.now() });
      return { ok: true } as const;
    }
    await removePost(ctx, post);
    if (args.decision === "ban" && !(await isBanned(ctx, post.authorId))) {
      await ctx.db.insert("communityBans", {
        userId: post.authorId,
        createdAt: Date.now(),
      });
    }
    return { ok: true } as const;
  },
});

/// Tells the reviewers a post needs them, in the Discord channel at
/// COMMUNITY_REVIEW_WEBHOOK_URL: reports hid it ([hidden]), or a post they
/// put back was reported enough again and is still up. Without a webhook
/// set, nothing is sent. Either way the post waits in listForReview, which
/// the app shows reviewers.
export const notifyReviewers = internalAction({
  args: {
    postPublicId: v.string(),
    title: v.string(),
    authorName: v.union(v.string(), v.null()),
    reportCount: v.number(),
    hidden: v.boolean(),
  },
  returns: v.null(),
  handler: async (_ctx, args) => {
    const webhook = process.env.COMMUNITY_REVIEW_WEBHOOK_URL;
    if (webhook === undefined || webhook.length === 0) return null;
    const what = args.hidden
      ? `A Community post was hidden after ${args.reportCount} reports`
      : `A Community post a reviewer put back has ${args.reportCount} reports again and is still up`;
    const content =
      `${what}: ` +
      `"${args.title}"${args.authorName === null ? "" : ` by ${args.authorName}`}. ` +
      `${POST_LINK_ORIGIN}/community/${args.postPublicId}`;
    const response = await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // No mentions: a title is the author's text.
      body: JSON.stringify({ content, allowed_mentions: { parse: [] } }),
    });
    if (!response.ok) {
      // Shows as a failed run in the logs. The post still waits in the
      // app's review list.
      throw new Error(
        `The reviewers' message was refused (${response.status}) for post ${args.postPublicId}.`,
      );
    }
    return null;
  },
});

const FOLD_BATCH = 1000;

async function recordCountChange(
  ctx: MutationCtx,
  change: { postId: Id<"communityPosts">; stars: number; copies: number },
): Promise<void> {
  await ctx.db.insert("communityCountChanges", change);
  await startFolding(ctx, "communityCounts");
}

/// Folds stars, unstars and copies into their posts' counts. Runs minutes
/// after the first change it folds, so a busy post is written once per run
/// instead of once per star, and the feed's cached pages stay valid between.
async function foldCountBatch(ctx: MutationCtx): Promise<FoldLeft> {
  const changes = await ctx.db.query("communityCountChanges").take(FOLD_BATCH);
  const byPost = new Map<Id<"communityPosts">, { stars: number; copies: number }>();
  for (const change of changes) {
    const total = byPost.get(change.postId) ?? { stars: 0, copies: 0 };
    total.stars += change.stars;
    total.copies += change.copies;
    byPost.set(change.postId, total);
    await ctx.db.delete(change._id);
  }
  for (const [postId, total] of byPost) {
    if (total.stars === 0 && total.copies === 0) continue;
    const post = await ctx.db.get(postId);
    if (post === null) continue;
    await ctx.db.patch(postId, {
      starCount: Math.max(0, post.starCount + total.stars),
      copyCount: Math.max(0, post.copyCount + total.copies),
    });
  }
  return changes.length === FOLD_BATCH ? "fullBatch" : "nothing";
}

export const foldCountChanges = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    await sweepFolding(ctx, "communityCounts", await foldCountBatch(ctx));
    return null;
  },
});

export const scheduledCountFold = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    await continueFolding(ctx, "communityCounts", await foldCountBatch(ctx));
    return null;
  },
});

const TRENDING_READ_LIMIT = 8000;

/// Sets each post's trend score: its stars plus twice its copies from the
/// last week, the author's own left out. A copy is harder to fake than a
/// star and says more. Posts whose score is unchanged are not written.
export const refreshTrending = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const since = Date.now() - TRENDING_WINDOW_MS;
    const scores = new Map<Id<"communityPosts">, number>();
    // Who starred each post, so the author's own star is taken off once
    // the post is read below.
    const starrers = new Map<Id<"communityPosts">, Set<Id<"users">>>();
    // Newest first: past the limit, the oldest of the week drop out, not
    // what happened since.
    const stars = await ctx.db
      .query("communityStars")
      .withIndex("by_createdAt", (q) => q.gte("createdAt", since))
      .order("desc")
      .take(TRENDING_READ_LIMIT);
    for (const star of stars) {
      scores.set(star.postId, (scores.get(star.postId) ?? 0) + 1);
      const users = starrers.get(star.postId) ?? new Set();
      users.add(star.userId);
      starrers.set(star.postId, users);
    }
    const copies = await ctx.db
      .query("communityCopies")
      .withIndex("by_counted_and_createdAt", (q) =>
        q.eq("counted", true).gte("createdAt", since),
      )
      .order("desc")
      .take(TRENDING_READ_LIMIT);
    if (
      stars.length === TRENDING_READ_LIMIT ||
      copies.length === TRENDING_READ_LIMIT
    ) {
      console.warn(
        `Trending counted only the newest ${TRENDING_READ_LIMIT} stars or copies of the week.`,
      );
    }
    for (const copy of copies) {
      scores.set(copy.postId, (scores.get(copy.postId) ?? 0) + 2);
    }
    const trending = await ctx.db
      .query("communityPosts")
      .withIndex("by_trendScore", (q) => q.gt("trendScore", 0))
      .take(TRENDING_READ_LIMIT);
    for (const post of trending) {
      if (!scores.has(post._id)) await ctx.db.patch(post._id, { trendScore: 0 });
    }
    for (const [postId, counted] of scores) {
      const post = await ctx.db.get(postId);
      if (post === null) continue;
      const score = starrers.get(postId)?.has(post.authorId)
        ? counted - 1
        : counted;
      if (post.trendScore !== score) {
        await ctx.db.patch(postId, { trendScore: score });
      }
    }
    return null;
  },
});

/// Deletes the rest of a restored post's reports, a batch at a time.
export const clearReportsBatch = internalMutation({
  args: { postId: v.id("communityPosts") },
  returns: v.null(),
  handler: async (ctx, args) => {
    await clearReports(ctx, args.postId);
    return null;
  },
});

/// [authorId]'s posts that are not taken down. Read by status, so however
/// many they have taken down, none of these is missed.
async function livePostsBy(ctx: QueryCtx, authorId: Id<"users">) {
  const byStatus = (status: "listed" | "hidden") =>
    ctx.db
      .query("communityPosts")
      .withIndex("by_authorId_and_status", (q) =>
        q.eq("authorId", authorId).eq("status", status),
      )
      .take(MAX_LIVE_POSTS_PER_AUTHOR);
  return [...(await byStatus("listed")), ...(await byStatus("hidden"))];
}

const REPORTS_CLEARED_PER_BATCH = 1000;
const clearReportsBatchRef = makeFunctionReference<"mutation">(
  "community:clearReportsBatch",
);

/// Deletes [postId]'s reports, so a restored post starts its count again and
/// its reporters can report it again. Past one batch the rest are deleted by
/// scheduled batches.
async function clearReports(ctx: MutationCtx, postId: Id<"communityPosts">) {
  const reports = await ctx.db
    .query("communityReports")
    .withIndex("by_postId_and_reporterId", (q) => q.eq("postId", postId))
    .take(REPORTS_CLEARED_PER_BATCH);
  for (const report of reports) await ctx.db.delete(report._id);
  if (reports.length === REPORTS_CLEARED_PER_BATCH) {
    await ctx.scheduler.runAfter(0, clearReportsBatchRef, { postId });
  }
}

/// Copies [source] into a new snapshot owned by the community account.
/// A first snapshot gets a new link anyone can read it through. One
/// [replacing] an older snapshot takes over that one's links instead
/// (public and review alike), so a link already handed out keeps working.
async function takeSnapshot(
  ctx: MutationCtx,
  source: Doc<"strategies">,
  title: string,
  authorId: Id<"users">,
  options: { replacing?: Doc<"strategies"> | null; shareToken?: string } = {},
) {
  const ownerId = await communityOwnerId(ctx);
  const publicId = createPublicId();
  const copy = await copyStrategy(
    ctx,
    source,
    { publicId, ownerId, folderId: undefined, name: title, userId: authorId },
    tooLargeToPost,
  );
  const now = Date.now();
  if (options.replacing != null && options.shareToken !== undefined) {
    const links = await ctx.db
      .query("shareLinks")
      .withIndex("by_strategyId", (q) =>
        q.eq("strategyId", options.replacing!._id),
      )
      .take(10);
    for (const link of links) {
      await ctx.db.patch(link._id, { strategyId: copy.strategyId, updatedAt: now });
    }
    return { ...copy, publicId, shareToken: options.shareToken };
  }
  const shareToken = `${COMMUNITY_TOKEN_PREFIX}${createPublicId()}`;
  await insertSnapshotLink(ctx, copy.strategyId, shareToken, ownerId);
  return { ...copy, publicId, shareToken };
}

async function insertSnapshotLink(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  token: string,
  ownerId: Id<"users">,
) {
  const now = Date.now();
  await ctx.db.insert("shareLinks", {
    token,
    targetType: "strategy",
    strategyId,
    role: "viewer",
    createdByUserId: ownerId,
    createdAt: now,
    updatedAt: now,
  });
}

async function shareLinkOf(ctx: MutationCtx, token: string) {
  return await ctx.db
    .query("shareLinks")
    .withIndex("by_token", (q) => q.eq("token", token))
    .first();
}

/// Takes [post] out of the feed for review: its public link stops working,
/// and a review link only reviewers are given opens it instead.
async function hidePost(ctx: MutationCtx, post: Doc<"communityPosts">) {
  const now = Date.now();
  const link = await shareLinkOf(ctx, post.shareToken);
  if (link !== null && link.revokedAt === undefined) {
    await ctx.db.patch(link._id, { revokedAt: now, updatedAt: now });
  }
  let reviewToken: string | undefined;
  if (post.snapshotStrategyId !== undefined) {
    reviewToken = `${COMMUNITY_TOKEN_PREFIX}review-${createPublicId()}`;
    await insertSnapshotLink(
      ctx,
      post.snapshotStrategyId,
      reviewToken,
      await communityOwnerId(ctx),
    );
  }
  await ctx.db.patch(post._id, { status: "hidden", reviewToken });
}

/// Puts a hidden [post] back: its public link works again and the review
/// link goes.
async function relistPost(ctx: MutationCtx, post: Doc<"communityPosts">) {
  const now = Date.now();
  const link = await shareLinkOf(ctx, post.shareToken);
  if (link !== null && link.revokedAt !== undefined) {
    await ctx.db.patch(link._id, { revokedAt: undefined, updatedAt: now });
  }
  if (post.reviewToken !== undefined) {
    const review = await shareLinkOf(ctx, post.reviewToken);
    if (review !== null) await ctx.db.delete(review._id);
  }
  await ctx.db.patch(post._id, { status: "listed", reviewToken: undefined });
}

/// Takes [post] down for good: out of the feed, its snapshot deleted with
/// its share link.
async function removePost(ctx: MutationCtx, post: Doc<"communityPosts">) {
  if (post.snapshotStrategyId !== undefined) {
    const snapshot = await ctx.db.get(post.snapshotStrategyId);
    if (snapshot !== null) await deleteStrategyRecord(ctx, snapshot);
  }
  await ctx.db.patch(post._id, {
    status: "removed",
    snapshotStrategyId: undefined,
    reviewToken: undefined,
    updatedAt: Date.now(),
  });
}
