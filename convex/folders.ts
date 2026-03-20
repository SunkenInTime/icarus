import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { requireCurrentUser } from "./lib/auth";
import { getFolderByPublicId } from "./lib/entities";

async function deleteStrategyCascade(ctx: any, strategy: any) {
  const pages = await ctx.db
    .query("pages")
    .withIndex("by_strategyId", (q: any) => q.eq("strategyId", strategy._id))
    .collect();

  for (const page of pages) {
    const pageElements = await ctx.db
      .query("elements")
      .withIndex("by_pageId", (q: any) => q.eq("pageId", page._id))
      .collect();
    for (const element of pageElements) {
      await ctx.db.delete(element._id);
    }

    const pageLineups = await ctx.db
      .query("lineups")
      .withIndex("by_pageId", (q: any) => q.eq("pageId", page._id))
      .collect();
    for (const lineup of pageLineups) {
      await ctx.db.delete(lineup._id);
    }

    const assets = await ctx.db
      .query("imageAssets")
      .withIndex("by_pageId", (q: any) => q.eq("pageId", page._id))
      .collect();
    for (const asset of assets) {
      await ctx.db.delete(asset._id);
    }

    await ctx.db.delete(page._id);
  }

  const collaborators = await ctx.db
    .query("strategyCollaborators")
    .withIndex("by_strategyId", (q: any) => q.eq("strategyId", strategy._id))
    .collect();
  for (const collaborator of collaborators) {
    await ctx.db.delete(collaborator._id);
  }

  const invites = await ctx.db
    .query("inviteTokens")
    .withIndex("by_strategyId", (q: any) => q.eq("strategyId", strategy._id))
    .collect();
  for (const invite of invites) {
    await ctx.db.delete(invite._id);
  }

  await ctx.db.delete(strategy._id);
}

async function deleteFolderCascade(ctx: any, folder: any) {
  const childFolders = await ctx.db
    .query("folders")
    .withIndex("by_parentFolderId", (q: any) => q.eq("parentFolderId", folder._id))
    .collect();

  for (const child of childFolders) {
    await deleteFolderCascade(ctx, child);
  }

  const strategies = await ctx.db
    .query("strategies")
    .withIndex("by_folderId", (q: any) => q.eq("folderId", folder._id))
    .collect();
  for (const strategy of strategies) {
    await deleteStrategyCascade(ctx, strategy);
  }

  await ctx.db.delete(folder._id);
}

async function assertFolderParentIsValid(ctx: any, folder: any, parentFolderId: any) {
  if (parentFolderId === undefined) {
    return;
  }

  if (folder._id === parentFolderId) {
    throw new Error("Cannot move folder into itself");
  }

  let current = await ctx.db.get(parentFolderId);
  while (current !== null) {
    if (current._id === folder._id) {
      throw new Error("Cannot move folder into its descendant");
    }
    if (current.parentFolderId === undefined) {
      break;
    }
    current = await ctx.db.get(current.parentFolderId);
  }
}

export const listForParent = query({
  args: {
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);

    let parentFolderId;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      if (parent.ownerId !== user._id) {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    const folders = await ctx.db
      .query("folders")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", user._id))
      .collect();

    return folders
      .filter((f) => f.parentFolderId === parentFolderId)
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((f) => ({
        publicId: f.publicId,
        name: f.name,
        iconIndex: f.iconIndex ?? null,
        colorKey: f.colorKey ?? null,
        customColorValue: f.customColorValue ?? null,
        parentFolderPublicId:
          f.parentFolderId === undefined
            ? null
            : folders.find((p) => p._id === f.parentFolderId)?.publicId ?? null,
        createdAt: f.createdAt,
        updatedAt: f.updatedAt,
      }));
  },
});

export const create = mutation({
  args: {
    publicId: v.string(),
    name: v.string(),
    parentFolderPublicId: v.optional(v.string()),
    iconIndex: v.optional(v.number()),
    colorKey: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const now = Date.now();

    let parentFolderId;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      if (parent.ownerId !== user._id) {
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
      iconIndex: args.iconIndex,
      colorKey: args.colorKey,
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
    iconIndex: v.optional(v.number()),
    colorKey: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
    clearCustomColorValue: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    const patch: {
      name?: string;
      iconIndex?: number;
      colorKey?: string;
      customColorValue?: number | undefined;
      updatedAt: number;
    } = {
      updatedAt: Date.now(),
    };

    if (args.name !== undefined) {
      patch.name = args.name;
    }
    if (args.iconIndex !== undefined) {
      patch.iconIndex = args.iconIndex;
    }
    if (args.colorKey !== undefined) {
      patch.colorKey = args.colorKey;
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

export const move = mutation({
  args: {
    folderPublicId: v.string(),
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    let parentFolderId;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      if (parent.ownerId !== user._id) {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    await assertFolderParentIsValid(ctx, folder, parentFolderId);

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
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    await deleteFolderCascade(ctx, folder);
    return { ok: true };
  },
});

export const getPath = query({
  args: {
    folderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    if (args.folderPublicId === undefined) {
      return [];
    }

    const path = [];
    let current = await getFolderByPublicId(ctx, args.folderPublicId);

    while (current !== null) {
      if (current.ownerId !== user._id) {
        throw new Error("Forbidden");
      }

      path.unshift({
        publicId: current.publicId,
        name: current.name,
        iconIndex: current.iconIndex ?? null,
        colorKey: current.colorKey ?? null,
        customColorValue: current.customColorValue ?? null,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
        parentFolderPublicId: null,
      });

      if (current.parentFolderId === undefined) {
        break;
      }

      current = await ctx.db.get(current.parentFolderId);
    }

    for (let i = 0; i < path.length; i += 1) {
      path[i].parentFolderPublicId = i === 0 ? null : path[i - 1].publicId;
    }

    return path;
  },
});

export { deleteFolder as deleteRecursive };
export { deleteFolder as delete };
