import type { QueryCtx, MutationCtx } from "../_generated/server";
import type { Doc, Id } from "../_generated/dataModel";
import { unauthenticatedError } from "./errors";

export type StrategyRole = "owner" | "editor" | "viewer";

type AnyCtx = QueryCtx | MutationCtx;

const roleRank: Record<StrategyRole, number> = {
  viewer: 1,
  editor: 2,
  owner: 3,
};

export async function requireCurrentUser(ctx: AnyCtx): Promise<Doc<"users">> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) {
    throw unauthenticatedError();
  }

  const externalId = identity.subject ?? identity.tokenIdentifier;
  const user = await ctx.db
    .query("users")
    .withIndex("by_externalId", (q) => q.eq("externalId", externalId))
    .first();

  if (user === null) {
    throw new Error("Missing user record. Call users:ensureCurrentUser before querying collaborative data.");
  }

  return user;
}

export async function getStrategyRoleForUser(
  ctx: AnyCtx,
  strategy: Doc<"strategies">,
  userId: Id<"users">,
): Promise<StrategyRole | null> {
  if (strategy.ownerId === userId) {
    return "owner";
  }

  const collaborator = await ctx.db
    .query("strategyCollaborators")
    .withIndex("by_strategyId_userId", (q) =>
      q.eq("strategyId", strategy._id).eq("userId", userId),
    )
    .first();

  return collaborator?.role ?? null;
}

export function hasRole(
  actual: StrategyRole | null,
  required: StrategyRole,
): boolean {
  if (actual === null) return false;
  return roleRank[actual] >= roleRank[required];
}

export async function assertStrategyRole(
  ctx: AnyCtx,
  strategy: Doc<"strategies">,
  required: StrategyRole,
): Promise<{ user: Doc<"users">; role: StrategyRole }> {
  const user = await requireCurrentUser(ctx);
  const role = await getStrategyRoleForUser(ctx, strategy, user._id);

  if (!hasRole(role, required)) {
    throw new Error("Forbidden");
  }

  return { user, role: role as StrategyRole };
}
