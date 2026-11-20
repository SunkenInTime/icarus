import { v } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { findUserByIdentity } from "./auth";
import { invalidPayloadError, notFoundError } from "./errors";
import { discordAvatarUrl, UNKNOWN_DISPLAY_NAME } from "./profile";

type AnyCtx = QueryCtx | MutationCtx;

/// The account that owns every post's snapshot, so a snapshot sits in
/// nobody's library. No sign-in can be it: a signed-in account's external id
/// is its token identifier (`<issuer>|<subject>`) or a Supabase subject.
export const COMMUNITY_OWNER_EXTERNAL_ID = "icarus:community";

/// Every post's share token starts with this, so a share link redeem can
/// refuse it: a post is opened, never joined.
export const COMMUNITY_TOKEN_PREFIX = "community-";

export const MAX_TITLE_LENGTH = 60;
export const MAX_REPORT_NOTE_LENGTH = 200;
/// Distinct accounts reporting a listed post that take it out of the feed
/// until a reviewer looks.
export const REPORTS_TO_HIDE = 3;
export const MAX_LIVE_POSTS_PER_AUTHOR = 50;
/// How fast one account can post, copy and report, so a script or a stuck
/// button can't flood the feed, the database or the reviewers. Counted from
/// the account's own recent rows. Stars have no limit: an unstar deletes its
/// row, so there is nothing to count, and a star only moves a number.
export const POSTS_PER_HOUR = 10;
export const COPIES_PER_HOUR = 30;
export const REPORTS_PER_DAY = 20;
export const HOUR_MS = 60 * 60 * 1000;
export const DAY_MS = 24 * HOUR_MS;
/// Rows one feed page reads. Filters the index can't apply (side, agents)
/// are applied to these, so a page can hold fewer matches than this; the
/// client asks for the next page while it has too few cards to fill the
/// screen.
export const FEED_PAGE_ROWS = 60;
export const TRENDING_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

export const postSideValidator = v.union(
  v.literal("attack"),
  v.literal("defense"),
  v.literal("mixed"),
);

export const postStatusValidator = v.union(
  v.literal("listed"),
  v.literal("hidden"),
  v.literal("removed"),
);

export const reportReasonValidator = v.union(
  v.literal("offensive"),
  v.literal("picture"),
  v.literal("link"),
  v.literal("spam"),
  v.literal("stolen"),
);

/// What a feed card needs, all of it from the post row.
export const postCardValidator = v.object({
  publicId: v.string(),
  title: v.string(),
  mapData: v.string(),
  side: postSideValidator,
  agentTypes: v.array(v.string()),
  authorName: v.union(v.string(), v.null()),
  authorAvatarUrl: v.union(v.string(), v.null()),
  starCount: v.number(),
  pageCount: v.number(),
  lineupCount: v.number(),
  publishedAt: v.number(),
  // The snapshot, read through shareToken.
  strategyPublicId: v.string(),
  shareToken: v.string(),
});

export function postCard(post: Doc<"communityPosts">) {
  return {
    publicId: post.publicId,
    title: post.title,
    mapData: post.mapData,
    side: post.side,
    agentTypes: post.agentTypes,
    authorName: post.authorName,
    authorAvatarUrl: post.authorAvatarUrl,
    starCount: post.starCount,
    pageCount: post.pageCount,
    lineupCount: post.lineupCount,
    publishedAt: post.publishedAt,
    strategyPublicId: post.snapshotStrategyPublicId,
    shareToken: post.shareToken,
  };
}

export function sideOf(pageIsAttack: boolean[]): Doc<"communityPosts">["side"] {
  if (pageIsAttack.length === 0 || pageIsAttack.every((attack) => attack)) {
    return "attack";
  }
  return pageIsAttack.every((attack) => !attack) ? "defense" : "mixed";
}

/// [title] trimmed, with runs of whitespace made one space. Refused when
/// empty or longer than [MAX_TITLE_LENGTH].
export function normalizedTitle(title: string): string {
  const normalized = title.trim().replace(/\s+/g, " ");
  if (normalized.length === 0) {
    throw invalidPayloadError("A post needs a title.");
  }
  if (normalized.length > MAX_TITLE_LENGTH) {
    throw invalidPayloadError(
      `A post title is at most ${MAX_TITLE_LENGTH} characters.`,
    );
  }
  return normalized;
}

export function searchTextOf(title: string, authorName: string | null) {
  return `${title} ${authorName ?? ""}`.trim().toLowerCase();
}

/// The name and picture a post shows for [user]. Rows written before
/// avatars were checked can hold any address, so it is checked again here.
export function authorOf(user: Doc<"users">) {
  return {
    authorName:
      user.displayName === UNKNOWN_DISPLAY_NAME ? null : user.displayName,
    authorAvatarUrl: discordAvatarUrl(user.avatarUrl),
  };
}

export async function getPostByPublicId(
  ctx: AnyCtx,
  publicId: string,
): Promise<Doc<"communityPosts">> {
  const post = await ctx.db
    .query("communityPosts")
    .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
    .unique();
  if (post === null) throw notFoundError("Post", publicId);
  return post;
}

/// The community account, made the first time a post needs it.
export async function communityOwnerId(
  ctx: MutationCtx,
): Promise<Id<"users">> {
  const existing = await ctx.db
    .query("users")
    .withIndex("by_externalId", (q) =>
      q.eq("externalId", COMMUNITY_OWNER_EXTERNAL_ID),
    )
    .unique();
  if (existing !== null) return existing._id;
  const now = Date.now();
  return await ctx.db.insert("users", {
    externalId: COMMUNITY_OWNER_EXTERNAL_ID,
    displayName: "Icarus Community",
    createdAt: now,
    updatedAt: now,
  });
}

/// Whether the caller reviews reported posts: their sign-in subject is
/// listed in the deployment's COMMUNITY_REVIEWERS (comma-separated).
export async function isReviewer(ctx: AnyCtx): Promise<boolean> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) return false;
  const reviewers = (process.env.COMMUNITY_REVIEWERS ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  return (
    reviewers.includes(identity.subject) ||
    reviewers.includes(identity.tokenIdentifier)
  );
}

/// The signed-in caller's account, or null when signed out or not set up.
export async function currentUserOrNull(
  ctx: AnyCtx,
): Promise<Doc<"users"> | null> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) return null;
  return await findUserByIdentity(ctx, identity);
}

export async function isBanned(
  ctx: AnyCtx,
  userId: Id<"users">,
): Promise<boolean> {
  const ban = await ctx.db
    .query("communityBans")
    .withIndex("by_userId", (q) => q.eq("userId", userId))
    .first();
  return ban !== null;
}
