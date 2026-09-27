// convex/schema.ts
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import {
  elementPayloadKindValidator,
  elementPayloadValidator,
  lineupPayloadKindValidator,
  lineupPayloadValidator,
  mapThemePaletteValidator,
  strategySettingsValidator,
} from "./lib/payloadValidators";

export default defineSchema({
  users: defineTable({
    externalId: v.string(), // auth provider subject
    displayName: v.string(),
    avatarUrl: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_externalId", ["externalId"]),
  folders: defineTable({
    publicId: v.string(),
    ownerId: v.id("users"),
    name: v.string(),
    parentFolderId: v.optional(v.id("folders")),
    iconId: v.optional(v.number()),
    iconCodePoint: v.optional(v.number()),
    iconFontFamily: v.optional(v.string()),
    iconFontPackage: v.optional(v.string()),
    color: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_ownerId", ["ownerId"])
    .index("by_parentFolderId", ["parentFolderId"]),
  strategies: defineTable({
    publicId: v.string(),
    ownerId: v.id("users"),
    folderId: v.optional(v.id("folders")),
    name: v.string(),
    mapData: v.string(),
    revision: v.number(),
    themeProfileId: v.optional(v.string()),
    themeOverridePalette: v.optional(mapThemePaletteValidator),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_ownerId", ["ownerId"])
    .index("by_folderId", ["folderId"]),
  pages: defineTable({
    publicId: v.string(),
    strategyId: v.id("strategies"),
    name: v.string(),
    isAutoNamed: v.optional(v.boolean()),
    sortIndex: v.number(),
    isAttack: v.boolean(),
    revision: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_strategyId", ["strategyId"]),
  pageContents: defineTable({
    pageId: v.id("pages"),
    settings: v.optional(strategySettingsValidator),
    revision: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_pageId", ["pageId"]),
  elements: defineTable({
    publicId: v.string(),
    strategyId: v.id("strategies"),
    pageId: v.id("pages"),
    elementType: elementPayloadKindValidator,
    payloadKind: elementPayloadKindValidator,
    payloadVersion: v.number(),
    payload: elementPayloadValidator,
    sortIndex: v.number(),
    revision: v.number(),
    deleted: v.boolean(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_pageId", ["pageId"])
    .index("by_strategyId", ["strategyId"])
    // Reads one element type without touching the rest (large text rows).
    .index("by_strategyId_and_elementType", ["strategyId", "elementType"])
    .index("by_deleted_and_updatedAt", ["deleted", "updatedAt"]),
  lineups: defineTable({
    publicId: v.string(),
    strategyId: v.id("strategies"),
    pageId: v.id("pages"),
    // Graph rows are keyed `<payloadKind>:<entity id>`; see ops.ts. A key is
    // unique within its strategy, not across strategies: a copied strategy
    // may reuse its original's entity ids.
    payloadKind: lineupPayloadKindValidator,
    payloadVersion: v.number(),
    payload: lineupPayloadValidator,
    sortIndex: v.number(),
    revision: v.number(),
    deleted: v.boolean(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_strategyId_and_publicId", ["strategyId", "publicId"])
    .index("by_pageId", ["pageId"])
    .index("by_strategyId", ["strategyId"])
    .index("by_strategyId_and_payloadKind", ["strategyId", "payloadKind"])
    // Whether a live link on a page names an origin or landing, checked
    // when one is deleted (see assertLineupEndUnused in ops.ts).
    .index("by_pageId_and_payloadKind_and_deleted_and_originId", [
      "pageId",
      "payloadKind",
      "deleted",
      "payload.data.originId",
    ])
    .index("by_pageId_and_payloadKind_and_deleted_and_landingId", [
      "pageId",
      "payloadKind",
      "deleted",
      "payload.data.landingId",
    ])
    .index("by_deleted_and_updatedAt", ["deleted", "updatedAt"]),
  // Which content rows show which images: one small row per (element or
  // lineup row, image id it shows), kept in step with every content write
  // (see lib/assetReferences.ts). Media cleanup checks an image's references
  // here with an indexed lookup instead of reading every element and lineup
  // of the strategy, which can exceed Convex's per-transaction read limit.
  assetReferences: defineTable({
    strategyId: v.id("strategies"),
    assetPublicId: v.string(),
    pageId: v.id("pages"),
    elementId: v.optional(v.id("elements")),
    lineupId: v.optional(v.id("lineups")),
    // Mirrors the content row's `deleted`: a tombstone still references its
    // image until it is purged, since undo may restore it.
    deleted: v.boolean(),
  })
    .index("by_strategyId_and_assetPublicId", ["strategyId", "assetPublicId"])
    .index("by_strategyId_and_assetPublicId_and_deleted", [
      "strategyId",
      "assetPublicId",
      "deleted",
    ])
    .index("by_strategyId_and_deleted", ["strategyId", "deleted"])
    .index("by_elementId", ["elementId"])
    .index("by_lineupId", ["lineupId"]),
  // Images that may have lost their last reference (their content was
  // purged), written in the same transaction as the purge and checked in
  // small scheduled batches, so a failed check is retried, never lost.
  assetReclaimCandidates: defineTable({
    strategyId: v.id("strategies"),
    assetPublicId: v.string(),
    createdAt: v.number(),
  })
    .index("by_createdAt", ["createdAt"])
    .index("by_strategyId_and_assetPublicId", ["strategyId", "assetPublicId"]),
  // One row per one-off data backfill that has finished. Code that relies on
  // backfilled data checks for its row first (see assetReferencesReady).
  completedBackfills: defineTable({
    name: v.string(),
    completedAt: v.number(),
  }).index("by_name", ["name"]),
  strategyCollaborators: defineTable({
    strategyId: v.id("strategies"),
    userId: v.id("users"),
    role: v.union(v.literal("editor"), v.literal("viewer")),
    invitedByUserId: v.optional(v.id("users")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_strategyId", ["strategyId"])
    .index("by_userId", ["userId"])
    .index("by_strategyId_userId", ["strategyId", "userId"]),
  folderCollaborators: defineTable({
    folderId: v.id("folders"),
    userId: v.id("users"),
    role: v.union(v.literal("editor"), v.literal("viewer")),
    invitedByUserId: v.optional(v.id("users")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_folderId", ["folderId"])
    .index("by_userId", ["userId"])
    .index("by_folderId_userId", ["folderId", "userId"]),
  shareLinks: defineTable({
    token: v.string(),
    targetType: v.union(v.literal("strategy"), v.literal("folder")),
    strategyId: v.optional(v.id("strategies")),
    folderId: v.optional(v.id("folders")),
    role: v.union(v.literal("editor"), v.literal("viewer")),
    createdByUserId: v.id("users"),
    revokedAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_token", ["token"])
    .index("by_strategyId", ["strategyId"])
    .index("by_folderId", ["folderId"]),
  inviteTokens: defineTable({
    token: v.string(),
    strategyId: v.id("strategies"),
    role: v.union(v.literal("editor"), v.literal("viewer")),
    createdByUserId: v.id("users"),
    redeemedByUserId: v.optional(v.id("users")),
    expiresAt: v.optional(v.number()),
    revokedAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_token", ["token"])
    .index("by_strategyId", ["strategyId"]),
  imageAssets: defineTable({
    publicId: v.string(),
    uploadAttemptPublicId: v.optional(v.string()),
    provider: v.optional(v.union(v.literal("convex"), v.literal("r2"))),
    strategyId: v.optional(v.id("strategies")),
    createdByUserId: v.optional(v.id("users")),
    storageId: v.optional(v.id("_storage")),
    objectKey: v.optional(v.string()),
    uploadStatus: v.optional(
      v.union(
        v.literal("pending"),
        v.literal("active"),
        v.literal("failed"),
        v.literal("deleted"),
      ),
    ),
    fileExtension: v.optional(v.string()),
    mimeType: v.optional(v.string()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
    byteSize: v.optional(v.number()),
    etag: v.optional(v.string()),
    uploadedAt: v.optional(v.number()),
    deletedAt: v.optional(v.number()),
    cleanupClaimedAt: v.optional(v.number()),
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),
    // Legacy rows may still have a storagePath that can help infer the extension.
    storagePath: v.optional(v.string()),
  })
    .index("by_publicId", ["publicId"])
    .index("by_uploadAttemptPublicId", ["uploadAttemptPublicId"])
    .index("by_strategyId", ["strategyId"])
    .index("by_strategyId_and_uploadStatus_and_updatedAt", [
      "strategyId",
      "uploadStatus",
      "updatedAt",
    ])
    .index("by_strategyId_and_publicId", ["strategyId", "publicId"])
    .index("by_strategyId_and_publicId_and_uploadStatus", [
      "strategyId",
      "publicId",
      "uploadStatus",
    ])
    .index("by_uploadStatus_and_updatedAt", ["uploadStatus", "updatedAt"])
    .index("by_storageId", ["storageId"])
    .index("by_objectKey", ["objectKey"]),
  // Derived: which agents each strategy uses, kept current by ops.applyBatch
  // so the folder tree can summarise a folder without reading its elements.
  strategyAgentSummaries: defineTable({
    strategyId: v.id("strategies"),
    agentTypes: v.array(v.string()),
    updatedAt: v.number(),
  }).index("by_strategyId", ["strategyId"]),
  operationEvents: defineTable({
    strategyId: v.id("strategies"),
    pageId: v.optional(v.id("pages")),
    clientId: v.string(),
    opId: v.string(),
    opType: v.string(),
    status: v.union(
      v.literal("applied"),
      v.literal("noop"),
      v.literal("rejected"),
      v.literal("failed"),
    ),
    reason: v.optional(v.string()),
    code: v.optional(v.string()),
    rawCode: v.optional(v.string()),
    message: v.optional(v.string()),
    expectedRevision: v.optional(v.number()),
    appliedRevision: v.optional(v.number()),
    createdAt: v.number(),
  })
    .index("by_strategyId", ["strategyId"])
    .index("by_createdAt", ["createdAt"])
    .index("by_strategyId_clientId_opId", ["strategyId", "clientId", "opId"]),
});
