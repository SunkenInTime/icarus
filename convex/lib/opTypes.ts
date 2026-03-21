import { v } from "convex/values";

export const opKindValidator = v.union(
  v.literal("add"),
  v.literal("move"),
  v.literal("patch"),
  v.literal("delete"),
  v.literal("reorder"),
);

export const entityTypeValidator = v.union(
  v.literal("strategy"),
  v.literal("page"),
  v.literal("element"),
  v.literal("lineup"),
);

export const strategyOpValidator = v.object({
  opId: v.string(),
  kind: opKindValidator,
  entityType: entityTypeValidator,
  entityPublicId: v.optional(v.string()),
  pagePublicId: v.optional(v.string()),
  payload: v.optional(v.string()),
  sortIndex: v.optional(v.number()),
  expectedRevision: v.optional(v.number()),
  expectedSequence: v.optional(v.number()),
});
