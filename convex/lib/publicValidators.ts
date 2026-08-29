import { v } from "convex/values";
import {
  elementPayloadKindValidator,
  elementPayloadValidator,
  lineupGroupPayloadValidator,
  mapThemePaletteValidator,
  strategySettingsValidator,
} from "./payloadValidators";

export const accessRoleValidator = v.union(
  v.literal("owner"),
  v.literal("editor"),
  v.literal("viewer"),
);

export const collaboratorRoleValidator = v.union(
  v.literal("editor"),
  v.literal("viewer"),
);

export const okResultValidator = v.object({ ok: v.literal(true) });

export const createResultValidator = v.union(
  okResultValidator,
  v.object({ ok: v.literal(true), reused: v.literal(true) }),
);

export const revisionResultValidator = v.union(
  v.object({ ok: v.literal(true), revision: v.number() }),
  v.object({
    ok: v.literal(true),
    reused: v.literal(true),
    revision: v.number(),
  }),
);

export const strategyHeaderValidator = v.object({
  publicId: v.string(),
  name: v.string(),
  mapData: v.string(),
  revision: v.number(),
  createdAt: v.number(),
  updatedAt: v.number(),
  themeProfileId: v.union(v.string(), v.null()),
  themeOverridePalette: v.union(mapThemePaletteValidator, v.null()),
  role: accessRoleValidator,
});

export const strategySummaryValidator = v.object({
  publicId: v.string(),
  name: v.string(),
  mapData: v.string(),
  revision: v.number(),
  createdAt: v.number(),
  updatedAt: v.number(),
  role: accessRoleValidator,
  attackLabel: v.union(
    v.literal("Unknown"),
    v.literal("Mixed"),
    v.literal("Attack"),
    v.literal("Defend"),
  ),
  folderPublicId: v.union(v.string(), v.null()),
  themeProfileId: v.union(v.string(), v.null()),
  themeOverridePalette: v.union(mapThemePaletteValidator, v.null()),
});

export const folderSummaryValidator = v.object({
  publicId: v.string(),
  name: v.string(),
  iconId: v.union(v.number(), v.null()),
  iconCodePoint: v.union(v.number(), v.null()),
  iconFontFamily: v.union(v.string(), v.null()),
  iconFontPackage: v.union(v.string(), v.null()),
  color: v.union(v.string(), v.null()),
  customColorValue: v.union(v.number(), v.null()),
  parentFolderPublicId: v.union(v.string(), v.null()),
  createdAt: v.number(),
  updatedAt: v.number(),
  role: accessRoleValidator,
});

export const pageDescriptorValidator = v.object({
  publicId: v.string(),
  strategyPublicId: v.string(),
  name: v.string(),
  sortIndex: v.number(),
  isAttack: v.boolean(),
  revision: v.number(),
  createdAt: v.number(),
  updatedAt: v.number(),
});

export const pageContentValidator = v.object({
  settings: v.union(strategySettingsValidator, v.null()),
  revision: v.number(),
  createdAt: v.number(),
  updatedAt: v.number(),
});

export const fullPageValidator = v.object({
  publicId: v.string(),
  strategyPublicId: v.string(),
  name: v.string(),
  sortIndex: v.number(),
  isAttack: v.boolean(),
  revision: v.number(),
  createdAt: v.number(),
  updatedAt: v.number(),
  settings: v.union(strategySettingsValidator, v.null()),
  contentRevision: v.number(),
  contentCreatedAt: v.number(),
  contentUpdatedAt: v.number(),
});

export const elementValidator = v.object({
  publicId: v.string(),
  strategyPublicId: v.string(),
  pagePublicId: v.string(),
  elementType: elementPayloadKindValidator,
  payload: elementPayloadValidator,
  sortIndex: v.number(),
  revision: v.number(),
  deleted: v.boolean(),
  createdAt: v.number(),
  updatedAt: v.number(),
});

export const lineupValidator = v.object({
  publicId: v.string(),
  strategyPublicId: v.string(),
  pagePublicId: v.string(),
  payload: lineupGroupPayloadValidator,
  sortIndex: v.number(),
  revision: v.number(),
  deleted: v.boolean(),
  createdAt: v.number(),
  updatedAt: v.number(),
});

export const imageProviderValidator = v.union(
  v.literal("convex"),
  v.literal("r2"),
);

export const imageUploadStatusValidator = v.union(
  v.literal("pending"),
  v.literal("active"),
  v.literal("failed"),
  v.literal("deleted"),
);

export const imageAssetValidator = v.object({
  publicId: v.string(),
  provider: imageProviderValidator,
  uploadStatus: imageUploadStatusValidator,
  fileExtension: v.string(),
  mimeType: v.union(v.string(), v.null()),
  width: v.union(v.number(), v.null()),
  height: v.union(v.number(), v.null()),
  byteSize: v.union(v.number(), v.null()),
  uploadedAt: v.union(v.number(), v.null()),
  url: v.union(v.string(), v.null()),
  legacyStoragePath: v.union(v.string(), v.null()),
});

export const strategyShellValidator = v.object({
  header: strategyHeaderValidator,
  pages: v.array(pageDescriptorValidator),
});

export const pageSnapshotValidator = v.object({
  page: pageDescriptorValidator,
  content: pageContentValidator,
  elements: v.array(elementValidator),
  lineups: v.array(lineupValidator),
  assets: v.array(imageAssetValidator),
});

export const fullStrategySnapshotValidator = v.object({
  header: strategyHeaderValidator,
  pages: v.array(fullPageValidator),
  elements: v.array(elementValidator),
  lineups: v.array(lineupValidator),
  assets: v.array(imageAssetValidator),
});
