// convex/health.ts
import { query } from "./_generated/server";

export const ping = query({
    args: {},
    handler: async () => {
        return "ok";
    },
});