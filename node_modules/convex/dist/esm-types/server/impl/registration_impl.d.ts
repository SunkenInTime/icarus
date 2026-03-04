import { GenericDataModel } from "../data_model.js";
import { ActionBuilder, GenericActionCtx, MutationBuilder, PublicHttpAction, QueryBuilder } from "../registration.js";
export declare function validateReturnValue(v: any): void;
export declare function invokeFunction<Ctx, Args extends any[], F extends (ctx: Ctx, ...args: Args) => any>(func: F, ctx: Ctx, args: Args): Promise<any>;
/**
 * Define a mutation in this Convex app's public API.
 *
 * You should generally use the `mutation` function from
 * `"./_generated/server"`.
 *
 * Mutations can read from and write to the database, and are accessible from
 * the client. They run **transactionally**, all database reads and writes
 * within a single mutation are atomic and isolated from other mutations.
 *
 * @example
 * ```typescript
 * import { mutation } from "./_generated/server";
 * import { v } from "convex/values";
 *
 * export const createTask = mutation({
 *   args: { text: v.string() },
 *   returns: v.id("tasks"),
 *   handler: async (ctx, args) => {
 *     const taskId = await ctx.db.insert("tasks", {
 *       text: args.text,
 *       completed: false,
 *     });
 *     return taskId;
 *   },
 * });
 * ```
 *
 * **Best practice:** Always include `args` and `returns` validators on all
 * mutations. If the function doesn't return a value, use `returns: v.null()`.
 * Argument validation is critical for security since public mutations are
 * exposed to the internet.
 *
 * **Common mistake:** Mutations cannot call third-party APIs or use `fetch`.
 * They must be deterministic. Use actions for external API calls.
 *
 * **Common mistake:** Do not use `mutation` for sensitive internal functions
 * that should not be called by clients. Use `internalMutation` instead.
 *
 * @param func - The mutation function. It receives a {@link GenericMutationCtx} as its first argument.
 * @returns The wrapped mutation. Include this as an `export` to name it and make it accessible.
 *
 * @see https://docs.convex.dev/functions/mutation-functions
 * @public
 */
export declare const mutationGeneric: MutationBuilder<any, "public">;
/**
 * Define a mutation that is only accessible from other Convex functions (but not from the client).
 *
 * You should generally use the `internalMutation` function from
 * `"./_generated/server"`.
 *
 * Internal mutations can read from and write to the database but are **not**
 * exposed as part of your app's public API. They can only be called by other
 * Convex functions using `ctx.runMutation` or by the scheduler. Like public
 * mutations, they run transactionally.
 *
 * @example
 * ```typescript
 * import { internalMutation } from "./_generated/server";
 * import { v } from "convex/values";
 *
 * // This mutation can only be called from other Convex functions:
 * export const markTaskCompleted = internalMutation({
 *   args: { taskId: v.id("tasks") },
 *   returns: v.null(),
 *   handler: async (ctx, args) => {
 *     await ctx.db.patch("tasks", args.taskId, { completed: true });
 *     return null;
 *   },
 * });
 * ```
 *
 * **Best practice:** Use `internalMutation` for any mutation that should not
 * be directly callable by clients, such as write-back functions from actions
 * or scheduled background work. Reference it via the `internal` object:
 * `await ctx.runMutation(internal.myModule.markTaskCompleted, { taskId })`.
 *
 * @param func - The mutation function. It receives a {@link GenericMutationCtx} as its first argument.
 * @returns The wrapped mutation. Include this as an `export` to name it and make it accessible.
 *
 * @see https://docs.convex.dev/functions/internal-functions
 * @public
 */
export declare const internalMutationGeneric: MutationBuilder<any, "internal">;
/**
 * Define a query in this Convex app's public API.
 *
 * You should generally use the `query` function from
 * `"./_generated/server"`.
 *
 * Queries can read from the database and are accessible from the client. They
 * are **reactive**, when used with `useQuery` in React, the component
 * automatically re-renders whenever the underlying data changes. Queries
 * cannot modify the database.
 * Query results are automatically cached by the Convex client and kept
 * consistent via WebSocket subscriptions.
 *
 *
 * @example
 * ```typescript
 * import { query } from "./_generated/server";
 * import { v } from "convex/values";
 *
 * export const listTasks = query({
 *   args: { completed: v.optional(v.boolean()) },
 *   returns: v.array(v.object({
 *     _id: v.id("tasks"),
 *     _creationTime: v.number(),
 *     text: v.string(),
 *     completed: v.boolean(),
 *   })),
 *   handler: async (ctx, args) => {
 *     if (args.completed !== undefined) {
 *       return await ctx.db
 *         .query("tasks")
 *         .withIndex("by_completed", (q) => q.eq("completed", args.completed))
 *         .collect();
 *     }
 *     return await ctx.db.query("tasks").collect();
 *   },
 * });
 * ```
 *
 * **Best practice:** Always include `args` and `returns` validators. Use
 * `.withIndex()` instead of `.filter()` for efficient database queries.
 * Queries should be fast since they run on every relevant data change.
 *
 * **Common mistake:** Queries are pure reads, they cannot write to the
 * database, call external APIs, or schedule functions. Use actions for HTTP
 * calls and mutations for database writes and scheduling.
 *
 * @param func - The query function. It receives a {@link GenericQueryCtx} as its first argument.
 * @returns The wrapped query. Include this as an `export` to name it and make it accessible.
 *
 * @see https://docs.convex.dev/functions/query-functions
 * @public
 */
export declare const queryGeneric: QueryBuilder<any, "public">;
/**
 * Define a query that is only accessible from other Convex functions (but not from the client).
 *
 * You should generally use the `internalQuery` function from
 * `"./_generated/server"`.
 *
 * Internal queries can read from the database but are **not** exposed as part
 * of your app's public API. They can only be called by other Convex functions
 * using `ctx.runQuery`. This is useful for loading data in actions or for
 * helper queries that shouldn't be client-facing.
 *
 * @example
 * ```typescript
 * import { internalQuery } from "./_generated/server";
 * import { v } from "convex/values";
 *
 * // Only callable from other Convex functions:
 * export const getUser = internalQuery({
 *   args: { userId: v.id("users") },
 *   returns: v.union(
 *     v.object({
 *       _id: v.id("users"),
 *       _creationTime: v.number(),
 *       name: v.string(),
 *       email: v.string(),
 *     }),
 *     v.null(),
 *   ),
 *   handler: async (ctx, args) => {
 *     return await ctx.db.get("users", args.userId);
 *   },
 * });
 * ```
 *
 * **Best practice:** Use `internalQuery` for data-loading in actions via
 * `ctx.runQuery(internal.myModule.getUser, { userId })`.
 *
 * @param func - The query function. It receives a {@link GenericQueryCtx} as its first argument.
 * @returns The wrapped query. Include this as an `export` to name it and make it accessible.
 *
 * @see https://docs.convex.dev/functions/internal-functions
 * @public
 */
export declare const internalQueryGeneric: QueryBuilder<any, "internal">;
/**
 * Define an action in this Convex app's public API.
 *
 * Actions can call third-party APIs, use Node.js libraries, and perform other
 * side effects. Unlike queries and mutations, actions do **not** have direct
 * database access (`ctx.db` is not available). Instead, use `ctx.runQuery`
 * and `ctx.runMutation` to read and write data.
 *
 * You should generally use the `action` function from
 * `"./_generated/server"`.
 *
 * Actions are accessible from the client and run outside of the database
 * transaction, so they are not atomic. They are best for integrating with
 * external services.
 *
 * @example
 * ```typescript
 * // Add "use node"; at the top of the file if using Node.js built-in modules.
 * import { action } from "./_generated/server";
 * import { v } from "convex/values";
 * import { internal } from "./_generated/api";
 *
 * export const generateSummary = action({
 *   args: { text: v.string() },
 *   returns: v.string(),
 *   handler: async (ctx, args) => {
 *     // Call an external API:
 *     const response = await fetch("https://api.example.com/summarize", {
 *       method: "POST",
 *       body: JSON.stringify({ text: args.text }),
 *     });
 *     const { summary } = await response.json();
 *
 *     // Write results back via a mutation:
 *     await ctx.runMutation(internal.myModule.saveSummary, {
 *       text: args.text,
 *       summary,
 *     });
 *
 *     return summary;
 *   },
 * });
 * ```
 *
 * **Best practice:** Minimize the number of `ctx.runQuery` and
 * `ctx.runMutation` calls from actions. Each call is a separate transaction,
 * so splitting logic across multiple calls introduces the risk of race
 * conditions. Try to batch reads/writes into single query/mutation calls.
 *
 * **`"use node"` runtime:** Actions run in Convex's default JavaScript
 * runtime, which supports `fetch` and most NPM packages. Only add
 * `"use node";` at the top of the file if a third-party library specifically
 * requires Node.js built-in APIs, it is a last resort, not the default.
 * Node.js actions have slower cold starts, and **only actions can be defined
 * in `"use node"` files** (no queries or mutations), so prefer the default
 * runtime whenever possible.
 *
 * **Common mistake:** Do not try to access `ctx.db` in an action, it is
 * not available. Use `ctx.runQuery` and `ctx.runMutation` instead.
 *
 * @param func - The function. It receives a {@link GenericActionCtx} as its first argument.
 * @returns The wrapped function. Include this as an `export` to name it and make it accessible.
 *
 * @see https://docs.convex.dev/functions/actions
 * @public
 */
export declare const actionGeneric: ActionBuilder<any, "public">;
/**
 * Define an action that is only accessible from other Convex functions (but not from the client).
 *
 * You should generally use the `internalAction` function from
 * `"./_generated/server"`.
 *
 * Internal actions behave like public actions (they can call external APIs and
 * use Node.js libraries) but are **not** exposed in your app's public API. They
 * can only be called by other Convex functions using `ctx.runAction` or via the
 * scheduler.
 *
 * @example
 * ```typescript
 * import { internalAction } from "./_generated/server";
 * import { v } from "convex/values";
 *
 * export const sendEmail = internalAction({
 *   args: { to: v.string(), subject: v.string(), body: v.string() },
 *   returns: v.null(),
 *   handler: async (ctx, args) => {
 *     // Call an external email service (fetch works in the default runtime):
 *     await fetch("https://api.email-service.com/send", {
 *       method: "POST",
 *       headers: { "Content-Type": "application/json" },
 *       body: JSON.stringify(args),
 *     });
 *     return null;
 *   },
 * });
 * ```
 *
 * **Best practice:** Use `internalAction` for background work scheduled from
 * mutations: `await ctx.scheduler.runAfter(0, internal.myModule.sendEmail, { ... })`.
 * Only use `ctx.runAction` from another action if you need to cross runtimes
 * (e.g., default Convex runtime to Node.js). Otherwise, extract shared code
 * into a helper function.
 *
 * **`"use node"` runtime:** Only add `"use node";` at the top of the file
 * as a last resort when a third-party library requires Node.js APIs. Node.js
 * actions have slower cold starts, and **only actions can be defined in
 * `"use node"` files** (no queries or mutations).
 *
 * @param func - The function. It receives a {@link GenericActionCtx} as its first argument.
 * @returns The wrapped function. Include this as an `export` to name it and make it accessible.
 *
 * @see https://docs.convex.dev/functions/internal-functions
 * @public
 */
export declare const internalActionGeneric: ActionBuilder<any, "internal">;
/**
 * Define a Convex HTTP action.
 *
 * HTTP actions handle raw HTTP requests and return HTTP responses. They are
 * registered by routing URL paths to them in `convex/http.ts` using
 * {@link HttpRouter}. Like regular actions, they can call external APIs and
 * use `ctx.runQuery` / `ctx.runMutation` but do not have direct `ctx.db` access.
 *
 * @example
 * ```typescript
 * // convex/http.ts
 * import { httpRouter } from "convex/server";
 * import { httpAction } from "./_generated/server";
 *
 * const http = httpRouter();
 *
 * http.route({
 *   path: "/api/webhook",
 *   method: "POST",
 *   handler: httpAction(async (ctx, request) => {
 *     const body = await request.json();
 *     // Process the webhook payload...
 *     return new Response(JSON.stringify({ ok: true }), {
 *       status: 200,
 *       headers: { "Content-Type": "application/json" },
 *     });
 *   }),
 * });
 *
 * export default http;
 * ```
 *
 * **Best practice:** HTTP actions are registered at the exact path specified.
 * For example, `path: "/api/webhook"` registers at `/api/webhook`.
 *
 * @param func - The function. It receives a {@link GenericActionCtx} as its first argument, and a `Request` object
 * as its second.
 * @returns The wrapped function. Route a URL path to this function in `convex/http.ts`.
 *
 * @see https://docs.convex.dev/functions/http-actions
 * @public
 */
export declare const httpActionGeneric: (func: (ctx: GenericActionCtx<GenericDataModel>, request: Request) => Promise<Response>) => PublicHttpAction;
//# sourceMappingURL=registration_impl.d.ts.map