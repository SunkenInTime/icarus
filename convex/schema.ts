// convex/schema.ts
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

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
    sequence: v.number(),
    themeProfileId: v.optional(v.string()),
    themeOverridePalette: v.optional(v.string()),
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
    sortIndex: v.number(),
    isAttack: v.boolean(),
    settings: v.optional(v.string()),
    revision: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_strategyId", ["strategyId"]),
  elements: defineTable({
    publicId: v.string(),
    strategyId: v.id("strategies"),
    pageId: v.id("pages"),
    elementType: v.string(),
    payload: v.string(),
    sortIndex: v.number(),
    revision: v.number(),
    deleted: v.boolean(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_pageId", ["pageId"])
    .index("by_strategyId", ["strategyId"]),
  lineups: defineTable({
    publicId: v.string(),
    strategyId: v.id("strategies"),
    pageId: v.id("pages"),
    payload: v.string(),
    sortIndex: v.number(),
    revision: v.number(),
    deleted: v.boolean(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_pageId", ["pageId"])
    .index("by_strategyId", ["strategyId"]),
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
    strategyId: v.id("strategies"),
    pageId: v.id("pages"),
    elementId: v.optional(v.id("elements")),
    storagePath: v.string(),
    mimeType: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
    createdByUserId: v.id("users"),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_publicId", ["publicId"])
    .index("by_strategyId", ["strategyId"])
    .index("by_pageId", ["pageId"]),
  operationEvents: defineTable({
    strategyId: v.id("strategies"),
    pageId: v.optional(v.id("pages")),
    clientId: v.string(),
    opId: v.string(),
    opType: v.string(),
    status: v.union(v.literal("ack"), v.literal("reject")),
    reason: v.optional(v.string()),
    expectedSequence: v.optional(v.number()),
    appliedSequence: v.optional(v.number()),
    expectedRevision: v.optional(v.number()),
    appliedRevision: v.optional(v.number()),
    createdAt: v.number(),
  })
    .index("by_strategyId", ["strategyId"])
    .index("by_strategyId_clientId_opId", ["strategyId", "clientId", "opId"]),
});


