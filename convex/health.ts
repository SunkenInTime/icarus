// convex/health.ts
import { query } from "./_generated/server";
import { v } from "convex/values";

export const ping = query({
  args: {},
  returns: v.literal("ok"),
  handler: async () => {
    return "ok" as const;
  },
});
