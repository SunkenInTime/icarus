/**
 * The local state of the client:
 * - which queries are subscribed to
 * - the "Query Set Version," used to produce QuerySetModification messages
 * - the current auth token and "Identity Version"
 *
 * Local state does not include:
 * - query results (see RemoteQuerySet)
 * - locally made "optimistic update" modifications to query results (see OptimisticQueryResults)
 * - any query results at all
 **/
import { Value } from "../../values/index.js";
import { QueryId, QuerySetModification, IdentityVersion, Authenticate, QueryJournal, Transition, AdminAuthentication, UserIdentityAttributes } from "./protocol.js";
import { QueryToken } from "./udf_path_utils.js";
export type AuthState = {
    tokenType: "User";
    value: string;
} | {
    tokenType: "Admin";
    value: string;
    impersonating?: UserIdentityAttributes | undefined;
};
export declare class LocalSyncState {
    private nextQueryId;
    private querySetVersion;
    private readonly querySet;
    private readonly queryIdToToken;
    private identityVersion;
    private auth;
    private readonly outstandingQueriesOlderThanRestart;
    private outstandingAuthOlderThanRestart;
    private paused;
    private pendingQuerySetModifications;
    constructor();
    hasSyncedPastLastReconnect(): boolean;
    markAuthCompletion(): void;
    subscribe(udfPath: string, args: Record<string, Value>, journal?: QueryJournal | undefined, componentPath?: string | undefined): {
        queryToken: QueryToken;
        modification: QuerySetModification | null;
        unsubscribe: () => QuerySetModification | null;
    };
    transition(transition: Transition): void;
    queryId(udfPath: string, args: Record<string, Value>): QueryId | null;
    isCurrentOrNewerAuthVersion(version: IdentityVersion): boolean;
    getAuth(): AuthState | undefined;
    setAuth(value: string): Authenticate;
    setAdminAuth(value: string, actingAs?: UserIdentityAttributes): AdminAuthentication;
    clearAuth(): Authenticate;
    hasAuth(): boolean;
    isNewAuth(value: string): boolean;
    queryPath(queryId: QueryId): string | null;
    queryArgs(queryId: QueryId): Record<string, Value> | null;
    queryToken(queryId: QueryId): QueryToken | null;
    queryJournal(queryToken: QueryToken): QueryJournal | undefined;
    restart(oldRemoteQueryResults: Set<QueryId>): [QuerySetModification, (Authenticate | undefined)?];
    pause(): void;
    resume(): [QuerySetModification | undefined, Authenticate | undefined];
    private unpause;
    private removeSubscriber;
}
//# sourceMappingURL=local_state.d.ts.map