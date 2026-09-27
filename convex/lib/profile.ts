// Who a signed-in person is, as their teammates should see them. Users sign
// in with Discord through Supabase, which keeps the Discord profile in the
// `user_metadata` claim rather than the standard name/picture claims.
//
// Convex flattens nested JWT claims into dotted keys, so the Discord display
// name arrives as identity["user_metadata.custom_claims.global_name"], not as
// an object (https://docs.convex.dev/auth/advanced/custom-jwt). Reading
// `identity.user_metadata` finds nothing.

/** Stored when a sign-in carries no name at all. Never shown as a name. */
export const UNKNOWN_DISPLAY_NAME = "Discord user";

export function profileFromIdentity(
  identity: Record<string, unknown> | null,
): { name: string | null; avatar: string | null } {
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
      text("user_metadata", "user_name") ??
      text("name") ??
      text("nickname") ??
      // Email sign-ins have no Discord name; the part before the @ is what a
      // teammate would recognize.
      emailName(text("email")),
    avatar:
      text("user_metadata", "avatar_url") ??
      text("user_metadata", "picture") ??
      text("pictureUrl"),
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

function emailName(email: string | null): string | null {
  const local = email?.split("@")[0]?.trim();
  return local ? local : null;
}
