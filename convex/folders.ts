import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx, MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import {
  assertFolderRole,
  getEffectiveFolderRoleForUser,
  requireCurrentUser,
} from "./lib/auth";
import { getFolderByPublicId } from "./lib/entities";

type FolderScope = "owned" | "shared" | "all";
type AnyCtx = QueryCtx | MutationCtx;

function matchesScope(
  ownerId: string,
  userId: string,
  scope: FolderScope,
): boolean {
  if (scope === "all") {
    return true;
  }
  if (scope === "owned") {
    return ownerId === userId;
  }
  return ownerId !== userId;
}

async function listAccessibleFoldersForScope(
  ctx: AnyCtx,
  userId: Id<"users">,
  scope: FolderScope,
) : Promise<Array<{ folder: Doc<"folders">; role: "owner" | "editor" | "viewer" }>> {
  const folders = await ctx.db.query("folders").collect();
  const results: Array<{
    folder: Doc<"folders">;
    role: "owner" | "editor" | "viewer";
  }> = [];

  for (const folder of folders) {
    const role = await getEffectiveFolderRoleForUser(ctx, folder, userId);
    if (role === null) {
      continue;
    }
    if (!matchesScope(folder.ownerId, userId, scope)) {
      continue;
    }
    results.push({ folder, role });
  }

  return results;
}

const folderScopeValidator = v.optional(
  v.union(v.literal("owned"), v.literal("shared"), v.literal("all")),
);

export const listForParent = query({
  args: {
    parentFolderPublicId: v.optional(v.string()),
    scope: folderScopeValidator,
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const scope = args.scope ?? "owned";

    let parentFolderId: Id<"folders"> | undefined;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      await assertFolderRole(ctx, parent, "viewer");
      parentFolderId = parent._id;
    }

    const accessible = await listAccessibleFoldersForScope(ctx, user._id, scope);
    const folderLookup = new Map(accessible.map(({ folder }) => [folder._id, folder]));

    return accessible
      .filter(({ folder }) => folder.parentFolderId === parentFolderId)
      .sort((a, b) => a.folder.createdAt - b.folder.createdAt)
      .map(({ folder, role }) => ({
        publicId: folder.publicId,
        name: folder.name,
        iconCodePoint: folder.iconCodePoint ?? null,
        iconFontFamily: folder.iconFontFamily ?? null,
        iconFontPackage: folder.iconFontPackage ?? null,
        color: folder.color ?? null,
        customColorValue: folder.customColorValue ?? null,
        parentFolderPublicId:
          folder.parentFolderId === undefined
            ? null
            : folderLookup.get(folder.parentFolderId)?.publicId ?? null,
        createdAt: folder.createdAt,
        updatedAt: folder.updatedAt,
        role,
      }));
  },
});

export const create = mutation({
  args: {
    publicId: v.string(),
    name: v.string(),
    parentFolderPublicId: v.optional(v.string()),
    iconCodePoint: v.optional(v.number()),
    iconFontFamily: v.optional(v.string()),
    iconFontPackage: v.optional(v.string()),
    color: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const now = Date.now();

    let parentFolderId: Id<"folders"> | undefined;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      const { role } = await assertFolderRole(ctx, parent, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    const existing = await ctx.db
      .query("folders")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
      .collect();
    const existingOwned = existing.find((item) => item.ownerId === user._id);
    if (existingOwned !== undefined) {
      return { ok: true, reused: true };
    }
    if (existing.length > 0) {
      throw new Error(`Folder publicId already exists: ${args.publicId}`);
    }

    await ctx.db.insert("folders", {
      publicId: args.publicId,
      ownerId: user._id,
      name: args.name,
      parentFolderId,
      iconCodePoint: args.iconCodePoint,
      iconFontFamily: args.iconFontFamily,
      iconFontPackage: args.iconFontPackage,
      color: args.color,
      customColorValue: args.customColorValue,
      createdAt: now,
      updatedAt: now,
    });

    return { ok: true };
  },
});

export const update = mutation({
  args: {
    folderPublicId: v.string(),
    name: v.optional(v.string()),
    iconCodePoint: v.optional(v.number()),
    iconFontFamily: v.optional(v.string()),
    iconFontPackage: v.optional(v.string()),
    clearIconFontFamily: v.optional(v.boolean()),
    clearIconFontPackage: v.optional(v.boolean()),
    color: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
    clearCustomColorValue: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);
    const { role } = await assertFolderRole(ctx, folder, "owner");

    if (role !== "owner") {
      throw new Error("Forbidden");
    }

    const patch: {
      name?: string;
      iconCodePoint?: number;
      iconFontFamily?: string;
      iconFontPackage?: string;
      color?: string;
      customColorValue?: number;
      updatedAt: number;
    } = {
      updatedAt: Date.now(),
    };

    if (args.name !== undefined) {
      patch.name = args.name;
    }
    if (args.iconCodePoint !== undefined) {
      patch.iconCodePoint = args.iconCodePoint;
    }
    if (args.clearIconFontFamily === true) {
      patch.iconFontFamily = undefined;
    } else if (args.iconFontFamily !== undefined) {
      patch.iconFontFamily = args.iconFontFamily;
    }
    if (args.clearIconFontPackage === true) {
      patch.iconFontPackage = undefined;
    } else if (args.iconFontPackage !== undefined) {
      patch.iconFontPackage = args.iconFontPackage;
    }
    if (args.color !== undefined) {
      patch.color = args.color;
    }
    if (args.clearCustomColorValue === true) {
      patch.customColorValue = undefined;
    } else if (args.customColorValue !== undefined) {
      patch.customColorValue = args.customColorValue;
    }

    await ctx.db.patch(folder._id, patch);
    return { ok: true };
  },
});

export const listAll = query({
  args: {
    scope: folderScopeValidator,
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const scope = args.scope ?? "all";
    const accessible = await listAccessibleFoldersForScope(ctx, user._id, scope);
    const folderLookup = new Map(accessible.map(({ folder }) => [folder._id, folder]));

    return accessible
      .sort((a, b) => a.folder.createdAt - b.folder.createdAt)
      .map(({ folder, role }) => ({
        publicId: folder.publicId,
        name: folder.name,
        iconCodePoint: folder.iconCodePoint ?? null,
        iconFontFamily: folder.iconFontFamily ?? null,
        iconFontPackage: folder.iconFontPackage ?? null,
        color: folder.color ?? null,
        customColorValue: folder.customColorValue ?? null,
        parentFolderPublicId:
          folder.parentFolderId === undefined
            ? null
            : folderLookup.get(folder.parentFolderId)?.publicId ?? null,
        createdAt: folder.createdAt,
        updatedAt: folder.updatedAt,
        role,
      }));
  },
});

export const move = mutation({
  args: {
    folderPublicId: v.string(),
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);
    const { role } = await assertFolderRole(ctx, folder, "owner");

    if (role !== "owner") {
      throw new Error("Forbidden");
    }

    let parentFolderId: Id<"folders"> | undefined;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      const parentAccess = await assertFolderRole(ctx, parent, "owner");
      if (parentAccess.role !== "owner" || parent.ownerId !== folder.ownerId) {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    await ctx.db.patch(folder._id, {
      parentFolderId,
      updatedAt: Date.now(),
    });

    return { ok: true };
  },
});

export const deleteFolder = mutation({
  args: {
    folderPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);
    const { role } = await assertFolderRole(ctx, folder, "owner");

    if (role !== "owner") {
      throw new Error("Forbidden");
    }

    const children = await ctx.db
      .query("folders")
      .withIndex("by_parentFolderId", (q) => q.eq("parentFolderId", folder._id))
      .collect();
    if (children.length > 0) {
      throw new Error("Folder has children");
    }

    const strategies = await ctx.db
      .query("strategies")
      .withIndex("by_folderId", (q) => q.eq("folderId", folder._id))
      .collect();
    if (strategies.length > 0) {
      throw new Error("Folder has strategies");
    }

    const collaborators = await ctx.db
      .query("folderCollaborators")
      .withIndex("by_folderId", (q) => q.eq("folderId", folder._id))
      .collect();
    for (const collaborator of collaborators) {
      await ctx.db.delete(collaborator._id);
    }

    const links = await ctx.db
      .query("shareLinks")
      .withIndex("by_folderId", (q) => q.eq("folderId", folder._id))
      .collect();
    for (const link of links) {
      await ctx.db.delete(link._id);
    }

    await ctx.db.delete(folder._id);
    return { ok: true };
  },
});

export { deleteFolder as delete };
