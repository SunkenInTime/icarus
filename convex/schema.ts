// convex/schema.ts
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
    users: defineTable({
        externalId: v.string(), // auth provider subject
        displayName: v.string(),
        avatarUrl: v.optional(v.string()),
        createdAt: v.number(),
    }).index("by_externalId", ["externalId"]),

});