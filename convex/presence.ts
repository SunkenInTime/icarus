import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { signPass } from "../presence/src/pass";
import { assertStrategyRole } from "./lib/auth";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import { getStrategyByPublicId } from "./lib/entities";

// Live presence runs outside Convex, in the icarus-presence Worker
// (presence/). Convex's only part is deciding who may join a strategy's room:
// it checks access here and signs a short-lived pass the Worker verifies with
// the secret both share. Nothing about presence is stored.

/** Clients renew at half this, so a revoked user drops within one TTL. */
export const ROOM_PASS_TTL_MS = 2 * 60 * 1000;
const MAX_NAME_CHARS = 64;
const MAX_AVATAR_URL_CHARS = 512;
const UNKNOWN_DISCORD_NAME = "Discord user";

export const issueRoomPass = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
  },
  // Null when this deployment has no presence service configured; the client
  // then shows no presence rather than an error.
  returns: v.union(
    v.object({
      url: v.string(),
      pass: v.string(),
      expiresAt: v.number(),
    }),
    v.null(),
  ),
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user, role } = await assertStrategyRole(ctx, strategy, "viewer");

    const baseUrl = process.env.PRESENCE_URL;
    const secret = process.env.PRESENCE_PASS_SECRET;
    if (!baseUrl || !secret) return null;

    const identity = await ctx.auth.getUserIdentity();
    const metadata = discordMetadata(identity);
    // Email sign-ins have no Discord name; the part before the @ is what a
    // teammate would recognize. "Discord user" is ensureCurrentUser's
    // placeholder, never a name.
    const storedName =
      user.displayName === UNKNOWN_DISCORD_NAME ? null : user.displayName;
    const name = truncate(
      metadata.name ?? storedName ?? emailName(identity?.email) ?? "Teammate",
      MAX_NAME_CHARS,
    );
    const avatar = metadata.avatar ?? user.avatarUrl ?? null;

    const expiresAt = Date.now() + ROOM_PASS_TTL_MS;
    const pass = await signPass(
      {
        room: strategy.publicId,
        uid: await opaqueUserId(user._id),
        name,
        avatar:
          avatar !== null && avatar.length <= MAX_AVATAR_URL_CHARS
            ? avatar
            : null,
        role,
        exp: expiresAt,
      },
      secret,
    );
    // PRESENCE_URL is the Worker's https address; sockets need ws(s).
    const socketBase = baseUrl.replace(/^http/, "ws").replace(/\/+$/, "");
    return {
      url: `${socketBase}/v1/rooms/${strategy.publicId}`,
      pass,
      expiresAt,
    };
  },
});

/**
 * Supabase carries the Discord profile in the `user_metadata` claim, not in
 * the standard name/picture claims, so users.displayName is often the
 * "Discord user" fallback. Prefer what Discord says.
 *
 * Convex flattens nested JWT claims into dotted keys, so Discord's display
 * name arrives as identity["user_metadata.custom_claims.global_name"], not as
 * an object. Read that form, and a nested object too in case a provider or
 * test sends one.
 */
function discordMetadata(identity: Record<string, unknown> | null): {
  name: string | null;
  avatar: string | null;
} {
  const text = (...path: string[]) => {
    const value = claimAt(identity, path);
    return typeof value === "string" && value.trim() !== ""
      ? value.trim()
      : null;
  };
  return {
    name:
      text("user_metadata", "custom_claims", "global_name") ??
      text("user_metadata", "full_name") ??
      text("user_metadata", "name") ??
      text("user_metadata", "user_name"),
    avatar:
      text("user_metadata", "avatar_url") ?? text("user_metadata", "picture"),
  };
}

/**
 * The claim at [path], whether Convex flattened it ("a.b.c"), left part of it
 * nested ("a.b" -> {c}), or kept it whole ({a: {b: {c}}}).
 */
function claimAt(
  claims: Record<string, unknown> | null,
  path: string[],
): unknown {
  if (claims === null || path.length === 0) return claims;
  for (let split = path.length; split >= 1; split--) {
    const key = path.slice(0, split).join(".");
    if (!(key in claims)) continue;
    const value = claims[key];
    if (split === path.length) return value;
    if (typeof value === "object" && value !== null) {
      const found = claimAt(value as Record<string, unknown>, path.slice(split));
      if (found !== undefined) return found;
    }
  }
  return undefined;
}

function emailName(email: unknown): string | null {
  if (typeof email !== "string") return null;
  const local = email.split("@")[0]?.trim();
  return local ? local : null;
}

function truncate(text: string, max: number): string {
  return text.length <= max ? text : text.slice(0, max);
}

/** Stable per user, but reveals nothing about the Convex row. */
async function opaqueUserId(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`icarus-presence:${userId}`),
  );
  return Array.from(new Uint8Array(digest).slice(0, 12))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
