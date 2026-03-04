import { Value } from "../values/index.js";
import { PaginatedWatch, Watch } from "./client.js";
import { QueryJournal } from "../browser/sync/protocol.js";
import { FunctionReference } from "../server/api.js";
import { RequestForQueries } from "./use_queries.js";
import { PaginatedQueryResult } from "../browser/sync/pagination.js";
import { SubscribeToPaginatedQueryOptions } from "../browser/sync/paginated_query_client.js";
type Identifier = string;
export interface CreateWatch {
    (query: FunctionReference<"query">, args: Record<string, Value>, options: {
        journal?: QueryJournal;
        paginationOptions?: SubscribeToPaginatedQueryOptions;
    }): Watch<Value> | PaginatedWatch<Value>;
}
/**
 * A class for observing the results of multiple queries at the same time.
 *
 * Any time the result of a query changes, the listeners are notified.
 */
export declare class QueriesObserver {
    createWatch: CreateWatch;
    private queries;
    private listeners;
    constructor(createWatch: CreateWatch);
    setQueries(newQueries: Record<Identifier, {
        query: FunctionReference<"query">;
        args: Record<string, Value>;
        paginationOptions?: SubscribeToPaginatedQueryOptions;
    }>): void;
    subscribe(listener: () => void): () => void;
    getLocalResults(queries: RequestForQueries): Record<Identifier, Value | undefined | Error | PaginatedQueryResult<Value>>;
    setCreateWatch(createWatch: CreateWatch): void;
    destroy(): void;
    private addQuery;
    private removeQuery;
    private notifyListeners;
}
export {};
//# sourceMappingURL=queries_observer.d.ts.map