import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { signPass } from "../presence/src/pass";
import { assertStrategyRole } from "./lib/auth";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import { getStrategyByPublicId } from "./lib/entities";
import { profileFromIdentity, UNKNOWN_DISPLAY_NAME } from "./lib/profile";

// Live presence runs outside Convex, in the icarus-presence Worker
// (presence/). Convex's only part is deciding who may join a strategy's room:
// it checks access here and signs a short-lived pass the Worker verifies with
// the secret both share. Nothing about presence is stored.

/** Clients renew at half this, so a revoked user drops within one TTL. */
export const ROOM_PASS_TTL_MS = 2 * 60 * 1000;
const MAX_NAME_CHARS = 64;
const MAX_AVATAR_URL_CHARS = 512;

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

    // Read the profile from this sign-in rather than the users row, so a
    // name or avatar changed on Discord shows at the next renewal.
    const profile = profileFromIdentity(await ctx.auth.getUserIdentity());
    const storedName =
      user.displayName === UNKNOWN_DISPLAY_NAME ? null : user.displayName;
    const name = truncate(
      profile.name ?? storedName ?? "Teammate",
      MAX_NAME_CHARS,
    );
    const avatar = profile.avatar ?? user.avatarUrl ?? null;

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
