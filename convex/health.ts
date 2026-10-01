// convex/health.ts
import { query } from "./_generated/server";
import { v } from "convex/values";
import { assertSupportedCloudProtocol } from "./lib/cloudProtocol";

export const ping = query({
  args: {
    // Given, the ping also answers whether this protocol is accepted: a
    // client the server once refused asks it to learn when it may sync
    // again. The connection health check sends nothing.
    clientProtocolVersion: v.optional(v.number()),
  },
  returns: v.literal("ok"),
  handler: async (_ctx, args) => {
    if (args.clientProtocolVersion !== undefined) {
      assertSupportedCloudProtocol(args.clientProtocolVersion);
    }
    return "ok" as const;
  },
});
