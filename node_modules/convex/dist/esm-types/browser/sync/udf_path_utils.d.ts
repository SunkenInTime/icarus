import { Value } from "../../values/index.js";
export declare function canonicalizeUdfPath(udfPath: string): string;
/**
 * The serialization here is not stable, these strings never make it outside the client.
 */
/**
 * A string representing the name and arguments of a query.
 *
 * This is used by the {@link BaseConvexClient}.
 *
 * @public
 */
export type QueryToken = string & {
    __queryToken: true;
};
/**
 * A string representing the name and arguments of a paginated query.
 *
 * This is a specialized form of QueryToken used for paginated queries.
 */
export type PaginatedQueryToken = QueryToken & {
    __paginatedQueryToken: true;
};
export declare function serializePathAndArgs(udfPath: string, args: Record<string, Value>): QueryToken;
export declare function serializePaginatedPathAndArgs(udfPath: string, args: Record<string, Value>, // args WITHOUT paginationOpts
options: {
    initialNumItems: number;
    id: number;
}): PaginatedQueryToken;
export declare function serializedQueryTokenIsPaginated(token: QueryToken | PaginatedQueryToken): token is PaginatedQueryToken;
//# sourceMappingURL=udf_path_utils.d.ts.map