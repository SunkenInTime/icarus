import type { PaginationResult } from "../../server/index.js";
import type { Infer, Value } from "../../values/index.js";
import type { paginationOptsValidator } from "../../server/index.js";
export type PaginationStatus = "LoadingFirstPage" | "CanLoadMore" | "LoadingMore" | "Exhausted";
export type PaginatedQueryResult<T> = {
    results: T[];
    status: PaginationStatus;
    loadMore: LoadMoreOfPaginatedQuery;
};
/**
 * Returns whether loading more was actually initiated; in cases where
 * a paginated query is already loading more items or there are no more
 * items available, calling loadMore() may do nothing.
 */
export type LoadMoreOfPaginatedQuery = (numItems: number) => boolean;
export declare function asPaginationArgs(value: Value): Record<string, Value> & {
    paginationOpts: Infer<typeof paginationOptsValidator>;
};
/**
 * Validates that a Value is a valid pagination result and returns it cast to PaginationResult.
 */
export declare function asPaginationResult(value: Value): PaginationResult<Value>;
//# sourceMappingURL=pagination.d.ts.map