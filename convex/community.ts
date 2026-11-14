import { makeFunctionReference } from "convex/server";
import { v } from "convex/values";
import { internalAction, query } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
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
  currentUserOrNull,
  FEED_PAGE_ROWS,
  getPostByPublicId,
  isBanned,
  isReviewer,
  MAX_LIVE_POSTS_PER_AUTHOR,
  MAX_REPORT_NOTE_LENGTH,
  normalizedTitle,
  postCard,
  postCardValidator,
  postSideValidator,
  postStatusValidator,
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
} from "./lib/errors";
import { assertSafeFileNameId } from "./lib/fileNameIds";
import { assertKnownMapChange } from "./lib/maps";
import { createResultValidator, okResultValidator } from "./lib/publicValidators";
import { readStrategyAgentTypes } from "./lib/strategyAgentSummary";
import { copyStrategy, deleteStrategyRecord } from "./lib/strategyCopy";

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

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

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

/// The caller's own posts that are not taken down, newest first, for the
/// Posted badge in their library and the post's dialog.
export const listMine = query({
  args: {},
  returns: v.array(
    v.object({
      post: postCardValidator,
      status: postStatusValidator,
      sourceStrategyPublicId: v.string(),
      saveCount: v.number(),
      updatedAt: v.number(),
    }),
  ),
  handler: async (ctx) => {
    const user = await currentUserOrNull(ctx);
    if (user === null) return [];
    const posts = await ctx.db
      .query("communityPosts")
      .withIndex("by_authorId", (q) => q.eq("authorId", user._id))
      .order("desc")
      .take(MAX_LIVE_POSTS_PER_AUTHOR * 4);
    return posts
      .filter((post) => post.status !== "removed")
      .map((post) => ({
        post: postCard(post),
        status: post.status,
        sourceStrategyPublicId: post.sourceStrategyPublicId,
        saveCount: post.saveCount,
        updatedAt: post.updatedAt,
      }));
  },
});

/// Whether the strategy a post was copied from has changed since the post
/// was last updated. Its author only; read once when they open the post's
/// dialog, since it reads the strategy's content version.
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
    return { sourceExists: true, changed: version !== post.sourceContentVersion };
  },
});

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
    const posts = await ctx.db
      .query("communityPosts")
      .withIndex("by_authorId", (q) => q.eq("authorId", user._id))
      .take(MAX_LIVE_POSTS_PER_AUTHOR * 4);
    const postBySource = new Map<string, string>();
    for (const post of posts) {
      if (post.status !== "removed") {
        postBySource.set(post.sourceStrategyId, post.publicId);
      }
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

/// What the caller may do in Community.
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

// ---------------------------------------------------------------------------
// Posting
// ---------------------------------------------------------------------------

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
    const ownPosts = await ctx.db
      .query("communityPosts")
      .withIndex("by_authorId", (q) => q.eq("authorId", user._id))
      .collect();
    if (
      ownPosts.filter((post) => post.status !== "removed").length >=
      MAX_LIVE_POSTS_PER_AUTHOR
    ) {
      throw invalidPayloadError(
        `You can have at most ${MAX_LIVE_POSTS_PER_AUTHOR} posts at a time.`,
      );
    }

    const now = Date.now();
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
      saveCount: 0,
      trendScore: 0,
      reportCount: 0,
      publishedAt: now,
      updatedAt: now,
    });
    return { ok: true, postPublicId } as const;
  },
});

/// Changes the caller's post: its title, and with [refresh] what it shows,
/// copied again from their strategy as it is now. Stars, saves and reports
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
    await ctx.db.patch(post._id, patch);
    return { ok: true } as const;
  },
});

/// Takes a post down: its link stops working and it leaves the feed.
/// Copies people saved stay theirs. Its author or a reviewer.
export const takeDown = mutation({
  args: { ...cloudProtocolArgs, postPublicId: v.string() },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const post = await getPostByPublicId(ctx, args.postPublicId);
    if (post.authorId !== user._id && !(await isReviewer(ctx))) {
      throw forbiddenError();
    }
    await removePost(ctx, post);
    return { ok: true } as const;
  },
});

// ---------------------------------------------------------------------------
// Stars and copies
// ---------------------------------------------------------------------------

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
      await ctx.db.insert("communityCountChanges", {
        postId: post._id,
        stars: 1,
        saves: 0,
      });
    } else if (!args.starred && existing !== null) {
      await ctx.db.delete(existing._id);
      await ctx.db.insert("communityCountChanges", {
        postId: post._id,
        stars: -1,
        saves: 0,
      });
    }
    return { ok: true } as const;
  },
});

/// Copies a post into the caller's library as a strategy of their own,
/// named after the post, in [folderPublicId] when that folder is theirs.
/// [publicId] names the new strategy; a retry with the same one is safe.
export const saveCopy = mutation({
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
    // A copy counts once per account, however many it saves.
    const saved = await ctx.db
      .query("communitySaves")
      .withIndex("by_postId_and_userId", (q) =>
        q.eq("postId", post._id).eq("userId", user._id),
      )
      .first();
    if (saved === null && post.authorId !== user._id) {
      await ctx.db.insert("communitySaves", {
        postId: post._id,
        userId: user._id,
        createdAt: Date.now(),
      });
      await ctx.db.insert("communityCountChanges", {
        postId: post._id,
        stars: 0,
        saves: 1,
      });
    }
    return { ok: true } as const;
  },
});

// ---------------------------------------------------------------------------
// Reports and review
// ---------------------------------------------------------------------------

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
    await ctx.db.insert("communityReports", {
      postId: post._id,
      reporterId: user._id,
      reason: args.reason,
      ...(note.length === 0 ? {} : { note }),
      createdAt: Date.now(),
    });
    const reportCount = post.reportCount + 1;
    const hide = post.status === "listed" && reportCount >= REPORTS_TO_HIDE;
    await ctx.db.patch(post._id, { reportCount });
    if (hide) {
      await hidePost(ctx, post);
      await ctx.scheduler.runAfter(0, notifyReviewersRef, {
        postPublicId: post.publicId,
        title: post.title,
        authorName: post.authorName,
        reportCount,
      });
    }
    return { ok: true } as const;
  },
});

/// Posts waiting for a reviewer, oldest report first. Reviewers only.
export const listForReview = query({
  args: {},
  returns: v.array(
    v.object({ post: postCardValidator, reportCount: v.number() }),
  ),
  handler: async (ctx) => {
    if (!(await isReviewer(ctx))) throw forbiddenError();
    const hidden = await ctx.db
      .query("communityPosts")
      .withIndex("by_status_and_publishedAt", (q) => q.eq("status", "hidden"))
      .take(100);
    return hidden.map((post) => ({
      post: postCard(post),
      reportCount: post.reportCount,
    }));
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
/// feed and clears its reports; remove takes it down; ban also stops its
/// author posting.
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
      await ctx.db.patch(post._id, { reportCount: 0 });
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

/// Tells the reviewers a post was hidden, in the Discord channel at
/// COMMUNITY_REVIEW_WEBHOOK_URL. Without one set, nothing is sent and the
/// post waits in listForReview.
export const notifyReviewers = internalAction({
  args: {
    postPublicId: v.string(),
    title: v.string(),
    authorName: v.union(v.string(), v.null()),
    reportCount: v.number(),
  },
  returns: v.null(),
  handler: async (_ctx, args) => {
    const webhook = process.env.COMMUNITY_REVIEW_WEBHOOK_URL;
    if (webhook === undefined || webhook.length === 0) return null;
    const content =
      `A Community post was hidden after ${args.reportCount} reports: ` +
      `"${args.title}"${args.authorName === null ? "" : ` by ${args.authorName}`}. ` +
      `${POST_LINK_ORIGIN}/community/${args.postPublicId}`;
    await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // No mentions: a title is the author's text.
      body: JSON.stringify({ content, allowed_mentions: { parse: [] } }),
    });
    return null;
  },
});

// ---------------------------------------------------------------------------
// Counts
// ---------------------------------------------------------------------------

const FOLD_BATCH = 1000;

/// Folds stars, unstars and saves into their posts' counts. Runs every few
/// minutes, so a busy post is written once per run instead of once per
/// star, and the feed's cached pages stay valid between runs.
export const foldCountChanges = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const changes = await ctx.db.query("communityCountChanges").take(FOLD_BATCH);
    const byPost = new Map<Id<"communityPosts">, { stars: number; saves: number }>();
    for (const change of changes) {
      const total = byPost.get(change.postId) ?? { stars: 0, saves: 0 };
      total.stars += change.stars;
      total.saves += change.saves;
      byPost.set(change.postId, total);
      await ctx.db.delete(change._id);
    }
    for (const [postId, total] of byPost) {
      if (total.stars === 0 && total.saves === 0) continue;
      const post = await ctx.db.get(postId);
      if (post === null) continue;
      await ctx.db.patch(postId, {
        starCount: Math.max(0, post.starCount + total.stars),
        saveCount: Math.max(0, post.saveCount + total.saves),
      });
    }
    if (changes.length === FOLD_BATCH) {
      await ctx.scheduler.runAfter(0, foldCountChangesRef, {});
    }
    return null;
  },
});

const TRENDING_READ_LIMIT = 8000;

/// Sets each post's trend score: its stars plus twice its saves from the
/// last week. A save is harder to fake than a star and says more. Posts
/// whose score is unchanged are not written.
export const refreshTrending = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const since = Date.now() - TRENDING_WINDOW_MS;
    const scores = new Map<Id<"communityPosts">, number>();
    // Newest first: past the limit, the oldest of the week drop out, not
    // what happened since.
    const stars = await ctx.db
      .query("communityStars")
      .withIndex("by_createdAt", (q) => q.gte("createdAt", since))
      .order("desc")
      .take(TRENDING_READ_LIMIT);
    for (const star of stars) {
      scores.set(star.postId, (scores.get(star.postId) ?? 0) + 1);
    }
    const saves = await ctx.db
      .query("communitySaves")
      .withIndex("by_createdAt", (q) => q.gte("createdAt", since))
      .order("desc")
      .take(TRENDING_READ_LIMIT);
    if (
      stars.length === TRENDING_READ_LIMIT ||
      saves.length === TRENDING_READ_LIMIT
    ) {
      console.warn(
        `Trending counted only the newest ${TRENDING_READ_LIMIT} stars or saves of the week.`,
      );
    }
    for (const save of saves) {
      scores.set(save.postId, (scores.get(save.postId) ?? 0) + 2);
    }
    // Posts that were trending and no longer are drop back to zero.
    const trending = await ctx.db
      .query("communityPosts")
      .withIndex("by_trendScore", (q) => q.gt("trendScore", 0))
      .take(TRENDING_READ_LIMIT);
    for (const post of trending) {
      if (!scores.has(post._id)) await ctx.db.patch(post._id, { trendScore: 0 });
    }
    for (const [postId, score] of scores) {
      const post = await ctx.db.get(postId);
      if (post !== null && post.trendScore !== score) {
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
