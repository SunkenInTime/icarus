import { makeFunctionReference } from "convex/server";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "../../convex/lib/cloudProtocol";
import { markAssetReferencesReady } from "../../convex/lib/assetReferences";
import { syncLineupItems } from "../../convex/lib/lineupItems";

export const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
export const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
export const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

export type Json = any;

export function predictedRows(rows: Json): Json {
  return { ...rows, strategies: [rows.strategy], strategy: undefined };
}

export async function seed(t: Json, init: Json): Promise<void> {
  await t.run(async (ctx: Json) => {
    await markAssetReferencesReady(ctx);
    const user = (await ctx.db.query("users").collect())[0]!;
    const now = 1;
    const folderIds: Record<string, Json> = {};
    for (const folder of init.folders) {
      folderIds[folder.publicId] = await ctx.db.insert("folders", {
        publicId: folder.publicId,
        ownerId: user._id,
        name: folder.name,
        ...(folder.parentFolderPublicId === undefined
          ? {}
          : { parentFolderId: folderIds[folder.parentFolderPublicId] }),
        ...Object.fromEntries(
          [
            "iconId",
            "iconCodePoint",
            "iconFontFamily",
            "iconFontPackage",
            "color",
            "customColorValue",
          ]
            .filter((key) => folder[key] !== undefined)
            .map((key) => [key, folder[key]]),
        ),
        createdAt: now,
        updatedAt: now,
      });
    }
    const s = init.strategy;
    const strategyId = await ctx.db.insert("strategies", {
      publicId: s.publicId,
      ownerId: user._id,
      ...(s.folderPublicId === undefined
        ? {}
        : { folderId: folderIds[s.folderPublicId] }),
      name: s.name,
      mapData: s.mapData,
      revision: s.revision,
      createdAt: now,
      updatedAt: now,
    });
    const pageIds: Record<string, Json> = {};
    for (const p of init.pages) {
      pageIds[p.publicId] = await ctx.db.insert("pages", {
        publicId: p.publicId,
        strategyId,
        name: p.name,
        ...(p.isAutoNamed === undefined ? {} : { isAutoNamed: p.isAutoNamed }),
        sortIndex: p.sortIndex,
        isAttack: p.isAttack,
        revision: p.revision,
        createdAt: now,
        updatedAt: now,
      });
    }
    for (const c of init.settings) {
      await ctx.db.insert("pageContents", {
        pageId: pageIds[c.pagePublicId],
        ...(c.settings === undefined ? {} : { settings: c.settings }),
        revision: c.revision,
        createdAt: now,
        updatedAt: now,
      });
    }
    for (const e of init.elements) {
      await ctx.db.insert("elements", {
        publicId: e.publicId,
        strategyId,
        pageId: pageIds[e.pagePublicId],
        elementType: e.payload.kind,
        payloadKind: e.payload.kind,
        payloadVersion: e.payload.payloadVersion,
        payload: e.payload,
        sortIndex: e.sortIndex,
        revision: e.revision,
        deleted: e.deleted,
        createdAt: now,
        updatedAt: now,
      });
    }
    for (const g of init.lineupGroups) {
      const row = {
        publicId: g.publicId,
        strategyId,
        pageId: pageIds[g.pagePublicId],
        payloadKind: "lineups" as const,
        payloadVersion: g.payload.payloadVersion,
        payload: g.payload,
        sortIndex: g.sortIndex,
        revision: g.revision,
        deleted: g.deleted,
        createdAt: now,
        updatedAt: now,
      };
      const id = await ctx.db.insert("lineups", row);
      await syncLineupItems(ctx, id, row);
    }
  });
}

export async function dump(t: Json): Promise<Json> {
  return await t.run(async (ctx: Json) => {
    const strategies = await ctx.db.query("strategies").collect();
    const folders = await ctx.db.query("folders").collect();
    const folderById = new Map(folders.map((f: Json) => [f._id, f.publicId]));
    const strategyById = new Map(
      strategies.map((s: Json) => [s._id, s.publicId]),
    );
    const pages = await ctx.db.query("pages").collect();
    const pageById = new Map(pages.map((p: Json) => [p._id, p.publicId]));
    const contents = await ctx.db.query("pageContents").collect();
    const elements = await ctx.db.query("elements").collect();
    const lineups = await ctx.db.query("lineups").collect();
    return {
      strategies: strategies.map((s: Json) => ({
        publicId: s.publicId,
        folderPublicId: s.folderId === undefined ? undefined : folderById.get(s.folderId),
        name: s.name,
        mapData: s.mapData,
        themeProfileId: s.themeProfileId,
        themeOverridePalette: s.themeOverridePalette,
        revision: s.revision,
      })),
      folders: folders.map((f: Json) => ({
        publicId: f.publicId,
        name: f.name,
        parentFolderPublicId:
          f.parentFolderId === undefined ? undefined : folderById.get(f.parentFolderId),
        iconId: f.iconId,
        iconCodePoint: f.iconCodePoint,
        iconFontFamily: f.iconFontFamily,
        iconFontPackage: f.iconFontPackage,
        color: f.color,
        customColorValue: f.customColorValue,
      })),
      pages: pages.map((p: Json) => ({
        publicId: p.publicId,
        strategyPublicId: strategyById.get(p.strategyId),
        name: p.name,
        isAutoNamed: p.isAutoNamed,
        sortIndex: p.sortIndex,
        isAttack: p.isAttack,
        revision: p.revision,
        deleted: p.deletedAt !== undefined,
      })),
      settings: contents.map((c: Json) => ({
        pagePublicId: pageById.get(c.pageId),
        settings: c.settings,
        revision: c.revision,
      })),
      elements: elements.map((e: Json) => ({
        publicId: e.publicId,
        pagePublicId: pageById.get(e.pageId),
        payload: e.payload,
        sortIndex: e.sortIndex,
        revision: e.revision,
        deleted: e.deleted,
      })),
      lineupGroups: lineups.map((g: Json) => ({
        publicId: g.publicId,
        strategyPublicId: strategyById.get(g.strategyId),
        pagePublicId: pageById.get(g.pageId),
        payload: g.payload,
        sortIndex: g.sortIndex,
        revision: g.revision,
        deleted: g.deleted,
      })),
    };
  });
}
