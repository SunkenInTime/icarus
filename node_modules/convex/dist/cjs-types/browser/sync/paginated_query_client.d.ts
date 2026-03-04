/**
 * PaginatedQueryClient maps subscriptions to paginated queries to the
 * individual page queries and handles page splits.
 *
 * In order to process all modified queries, paginated and normal, in the same
 * synchronous call the PaginatedQueryClient transition should be used exclusively.
 *
 * Like the BaseConvexClient, this client is not Convex Function type-aware: it deals
 * with queries as functions that return Value, not the specific value.
 * Use a higher-level library to get types.
 */
import { Value } from "../../values/index.js";
import { PaginatedQueryToken } from "./udf_path_utils.js";
import { BaseConvexClient, Transition } from "./client.js";
import { PaginatedQueryResult } from "./pagination.js";
export interface SubscribeToPaginatedQueryOptions {
    initialNumItems: number;
    id: number;
}
type AnyPaginatedQueryResult = PaginatedQueryResult<Value>;
export type PaginatedQueryModification = {
    kind: "Updated";
    result: AnyPaginatedQueryResult | undefined;
} | {
    kind: "Removed";
};
export type ExtendedTransition = Transition & {
    paginatedQueries: Array<{
        token: PaginatedQueryToken;
        modification: PaginatedQueryModification;
    }>;
};
export declare class PaginatedQueryClient {
    private client;
    private onTransition;
    private paginatedQuerySet;
    private lastTransitionTs;
    constructor(client: BaseConvexClient, onTransition: (transition: ExtendedTransition) => void);
    /**
     * Subscribe to a paginated query.
     *
     * @param name - The name of the paginated query function
     * @param args - Arguments for the query (excluding paginationOpts)
     * @param options - Pagination options including initialNumItems
     * @returns Object with paginatedQueryToken and unsubscribe function
     */
    subscribe(name: string, args: Record<string, Value>, options: SubscribeToPaginatedQueryOptions): {
        paginatedQueryToken: PaginatedQueryToken;
        unsubscribe: () => void;
    };
    /**
     * Get current results for a paginated query based on local state.
     *
     * Throws an error when one of the pages has errored.
     */
    localQueryResult(name: string, args: Record<string, Value>, options: {
        initialNumItems: number;
        id: number;
    }): AnyPaginatedQueryResult | undefined;
    private onBaseTransition;
    private splitPaginatedQueryPage;
    private removePaginatedQuerySubscriber;
    private completePaginatedQuerySplit;
    /** The query tokens for all active pages, in result order */
    private activePageQueryTokens;
    private allQueryTokens;
    private queryTokenForLastPageOfPaginatedQuery;
    private mustGetPaginatedQuery;
}
export {};
//# sourceMappingURL=paginated_query_client.d.ts.map