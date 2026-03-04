import { PaginatedQueryReference, PaginatedQueryArgs, UsePaginatedQueryReturnType } from "./use_paginated_query.js";
/**
 * Experimental new usePaginatedQuery implementation that will replace the current one
 * in the future.
 *
 * Load data reactively from a paginated query to a create a growing list.
 *
 * This is an alternate implementation that relies on new client pagination logic.
 *
 * This can be used to power "infinite scroll" UIs.
 *
 * This hook must be used with public query references that match
 * {@link PaginatedQueryReference}.
 *
 * `usePaginatedQuery` concatenates all the pages of results into a single list
 * and manages the continuation cursors when requesting more items.
 *
 * Example usage:
 * ```typescript
 * const { results, status, isLoading, loadMore } = usePaginatedQuery(
 *   api.messages.list,
 *   { channel: "#general" },
 *   { initialNumItems: 5 }
 * );
 * ```
 *
 * If the query reference or arguments change, the pagination state will be reset
 * to the first page. Similarly, if any of the pages result in an InvalidCursor
 * error or an error associated with too much data, the pagination state will also
 * reset to the first page.
 *
 * To learn more about pagination, see [Paginated Queries](https://docs.convex.dev/database/pagination).
 *
 * @param query - A FunctionReference to the public query function to run.
 * @param args - The arguments object for the query function, excluding
 * the `paginationOpts` property. That property is injected by this hook.
 * @param options - An object specifying the `initialNumItems` to be loaded in
 * the first page.
 * @returns A {@link UsePaginatedQueryResult} that includes the currently loaded
 * items, the status of the pagination, and a `loadMore` function.
 *
 * @public
 */
export declare function usePaginatedQuery_experimental<Query extends PaginatedQueryReference>(query: Query, args: PaginatedQueryArgs<Query> | "skip", options: {
    initialNumItems: number;
}): UsePaginatedQueryReturnType<Query>;
/**
 * Reset pagination id for tests only, so tests know what it is.
 */
export declare function resetPaginationId(): void;
//# sourceMappingURL=use_paginated_query2.d.ts.map