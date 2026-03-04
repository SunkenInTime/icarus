"use strict";
var __defProp = Object.defineProperty;
var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);
import {
  serializePaginatedPathAndArgs,
  canonicalizeUdfPath
} from "./udf_path_utils.js";
import {
  asPaginationResult
} from "./pagination.js";
import { Long } from "../../vendor/long.js";
export class PaginatedQueryClient {
  constructor(client, onTransition) {
    this.client = client;
    this.onTransition = onTransition;
    __publicField(this, "paginatedQuerySet", /* @__PURE__ */ new Map());
    // hold onto a real Transition so we can construct synthetic ones with that timestamp
    __publicField(this, "lastTransitionTs");
    this.lastTransitionTs = Long.fromNumber(0);
    this.client.addOnTransitionHandler(
      (transition) => this.onBaseTransition(transition)
    );
  }
  /**
   * Subscribe to a paginated query.
   *
   * @param name - The name of the paginated query function
   * @param args - Arguments for the query (excluding paginationOpts)
   * @param options - Pagination options including initialNumItems
   * @returns Object with paginatedQueryToken and unsubscribe function
   */
  subscribe(name, args, options) {
    const canonicalizedUdfPath = canonicalizeUdfPath(name);
    const token = serializePaginatedPathAndArgs(
      canonicalizedUdfPath,
      args,
      options
    );
    const unsubscribe = () => this.removePaginatedQuerySubscriber(token);
    const existingEntry = this.paginatedQuerySet.get(token);
    if (existingEntry) {
      existingEntry.numSubscribers += 1;
      return {
        paginatedQueryToken: token,
        unsubscribe
      };
    }
    this.paginatedQuerySet.set(token, {
      token,
      canonicalizedUdfPath,
      args,
      numSubscribers: 1,
      options: { initialNumItems: options.initialNumItems },
      nextPageKey: 0,
      pageKeys: [],
      pageKeyToQuery: /* @__PURE__ */ new Map(),
      ongoingSplits: /* @__PURE__ */ new Map(),
      skip: false,
      id: options.id
    });
    this.addPageToPaginatedQuery(token, null, options.initialNumItems);
    return {
      paginatedQueryToken: token,
      unsubscribe
    };
  }
  /**
   * Get current results for a paginated query based on local state.
   *
   * Throws an error when one of the pages has errored.
   */
  localQueryResult(name, args, options) {
    const canonicalizedUdfPath = canonicalizeUdfPath(name);
    const token = serializePaginatedPathAndArgs(
      canonicalizedUdfPath,
      args,
      options
    );
    return this.localQueryResultByToken(token);
  }
  /**
   * @internal
   */
  localQueryResultByToken(token) {
    const paginatedQuery = this.paginatedQuerySet.get(token);
    if (!paginatedQuery) {
      return void 0;
    }
    const activePages = this.activePageQueryTokens(paginatedQuery);
    if (activePages.length === 0) {
      return {
        results: [],
        status: "LoadingFirstPage",
        loadMore: (numItems) => {
          return this.loadMoreOfPaginatedQuery(token, numItems);
        }
      };
    }
    let allResults = [];
    let hasUndefined = false;
    let isDone = false;
    for (const pageToken of activePages) {
      const result = this.client.localQueryResultByToken(pageToken);
      if (result === void 0) {
        hasUndefined = true;
        isDone = false;
        continue;
      }
      const paginationResult = asPaginationResult(result);
      allResults = allResults.concat(paginationResult.page);
      isDone = !!paginationResult.isDone;
    }
    let status;
    if (hasUndefined) {
      status = allResults.length === 0 ? "LoadingFirstPage" : "LoadingMore";
    } else if (isDone) {
      status = "Exhausted";
    } else {
      status = "CanLoadMore";
    }
    return {
      results: allResults,
      status,
      loadMore: (numItems) => {
        return this.loadMoreOfPaginatedQuery(token, numItems);
      }
    };
  }
  onBaseTransition(transition) {
    const changedBaseTokens = transition.queries.map((q) => q.token);
    const changed = this.queriesContainingTokens(changedBaseTokens);
    let paginatedQueries = [];
    if (changed.length > 0) {
      this.processPaginatedQuerySplits(
        changed,
        (token) => this.client.localQueryResultByToken(token)
      );
      paginatedQueries = changed.map((token) => ({
        token,
        modification: {
          kind: "Updated",
          result: this.localQueryResultByToken(token)
        }
      }));
    }
    const extendedTransition = {
      ...transition,
      paginatedQueries
    };
    this.onTransition(extendedTransition);
  }
  /**
   * Load more items for a paginated query.
   *
   * This *always* causes a transition, the status of the query
   * has probably changed from "CanLoadMore" to "LoadingMore".
   * Data might have changed too: maybe a subscription to this page
   * query already exists (unlikely but possible) or this page query
   * has an optimistic update providing some initial data.
   *
   * @internal
   */
  loadMoreOfPaginatedQuery(token, numItems) {
    this.mustGetPaginatedQuery(token);
    const lastPageToken = this.queryTokenForLastPageOfPaginatedQuery(token);
    const lastPageResult = this.client.localQueryResultByToken(lastPageToken);
    if (!lastPageResult) {
      return false;
    }
    const paginationResult = asPaginationResult(lastPageResult);
    if (paginationResult.isDone) {
      return false;
    }
    this.addPageToPaginatedQuery(
      token,
      paginationResult.continueCursor,
      numItems
    );
    const loadMoreTransition = {
      timestamp: this.lastTransitionTs,
      reflectedMutations: [],
      queries: [],
      paginatedQueries: [
        {
          token,
          modification: {
            kind: "Updated",
            result: this.localQueryResultByToken(token)
          }
        }
      ]
    };
    this.onTransition(loadMoreTransition);
    return true;
  }
  /**
   * @internal
   */
  queriesContainingTokens(queryTokens) {
    if (queryTokens.length === 0) {
      return [];
    }
    const changed = [];
    const queryTokenSet = new Set(queryTokens);
    for (const [paginatedToken, paginatedQuery] of this.paginatedQuerySet) {
      for (const pageToken of this.allQueryTokens(paginatedQuery)) {
        if (queryTokenSet.has(pageToken)) {
          changed.push(paginatedToken);
          break;
        }
      }
    }
    return changed;
  }
  /**
   * @internal
   */
  processPaginatedQuerySplits(changed, getResult) {
    for (const paginatedQueryToken of changed) {
      const paginatedQuery = this.mustGetPaginatedQuery(paginatedQueryToken);
      const { ongoingSplits, pageKeyToQuery, pageKeys } = paginatedQuery;
      for (const [pageKey, [splitKey1, splitKey2]] of ongoingSplits) {
        const bothNewPagesLoaded = getResult(pageKeyToQuery.get(splitKey1).queryToken) !== void 0 && getResult(pageKeyToQuery.get(splitKey2).queryToken) !== void 0;
        if (bothNewPagesLoaded) {
          this.completePaginatedQuerySplit(
            paginatedQuery,
            pageKey,
            splitKey1,
            splitKey2
          );
        }
      }
      for (const pageKey of pageKeys) {
        if (ongoingSplits.has(pageKey)) {
          continue;
        }
        const pageToken = pageKeyToQuery.get(pageKey).queryToken;
        const pageResult = getResult(pageToken);
        if (!pageResult) {
          continue;
        }
        const result = asPaginationResult(pageResult);
        const shouldSplit = result.splitCursor && (result.pageStatus === "SplitRecommended" || result.pageStatus === "SplitRequired" || // This client-driven page splitting condition will change in the future.
        result.page.length > paginatedQuery.options.initialNumItems * 2);
        if (shouldSplit) {
          this.splitPaginatedQueryPage(
            paginatedQuery,
            pageKey,
            result.splitCursor,
            // we just checked
            result.continueCursor
          );
        }
      }
    }
  }
  splitPaginatedQueryPage(paginatedQuery, pageKey, splitCursor, continueCursor) {
    const splitKey1 = paginatedQuery.nextPageKey++;
    const splitKey2 = paginatedQuery.nextPageKey++;
    const paginationOpts = {
      cursor: continueCursor,
      numItems: paginatedQuery.options.initialNumItems,
      id: paginatedQuery.id
    };
    const firstSubscription = this.client.subscribe(
      paginatedQuery.canonicalizedUdfPath,
      {
        ...paginatedQuery.args,
        paginationOpts: {
          ...paginationOpts,
          cursor: null,
          // Start from beginning for first split
          endCursor: splitCursor
        }
      }
    );
    paginatedQuery.pageKeyToQuery.set(splitKey1, firstSubscription);
    const secondSubscription = this.client.subscribe(
      paginatedQuery.canonicalizedUdfPath,
      {
        ...paginatedQuery.args,
        paginationOpts: {
          ...paginationOpts,
          cursor: splitCursor,
          endCursor: continueCursor
        }
      }
    );
    paginatedQuery.pageKeyToQuery.set(splitKey2, secondSubscription);
    paginatedQuery.ongoingSplits.set(pageKey, [splitKey1, splitKey2]);
  }
  /**
   * @internal
   */
  addPageToPaginatedQuery(token, continueCursor, numItems) {
    const paginatedQuery = this.mustGetPaginatedQuery(token);
    const pageKey = paginatedQuery.nextPageKey++;
    const paginationOpts = {
      cursor: continueCursor,
      numItems,
      id: paginatedQuery.id
    };
    const pageArgs = {
      ...paginatedQuery.args,
      paginationOpts
    };
    const subscription = this.client.subscribe(
      paginatedQuery.canonicalizedUdfPath,
      pageArgs
    );
    paginatedQuery.pageKeys.push(pageKey);
    paginatedQuery.pageKeyToQuery.set(pageKey, subscription);
    return subscription;
  }
  removePaginatedQuerySubscriber(token) {
    const paginatedQuery = this.paginatedQuerySet.get(token);
    if (!paginatedQuery) {
      return;
    }
    paginatedQuery.numSubscribers -= 1;
    if (paginatedQuery.numSubscribers > 0) {
      return;
    }
    for (const subscription of paginatedQuery.pageKeyToQuery.values()) {
      subscription.unsubscribe();
    }
    this.paginatedQuerySet.delete(token);
  }
  completePaginatedQuerySplit(paginatedQuery, pageKey, splitKey1, splitKey2) {
    const originalQuery = paginatedQuery.pageKeyToQuery.get(pageKey);
    paginatedQuery.pageKeyToQuery.delete(pageKey);
    const pageIndex = paginatedQuery.pageKeys.indexOf(pageKey);
    paginatedQuery.pageKeys.splice(pageIndex, 1, splitKey1, splitKey2);
    paginatedQuery.ongoingSplits.delete(pageKey);
    originalQuery.unsubscribe();
  }
  /** The query tokens for all active pages, in result order */
  activePageQueryTokens(paginatedQuery) {
    return paginatedQuery.pageKeys.map(
      (pageKey) => paginatedQuery.pageKeyToQuery.get(pageKey).queryToken
    );
  }
  allQueryTokens(paginatedQuery) {
    return Array.from(paginatedQuery.pageKeyToQuery.values()).map(
      (sub) => sub.queryToken
    );
  }
  queryTokenForLastPageOfPaginatedQuery(token) {
    const paginatedQuery = this.mustGetPaginatedQuery(token);
    const lastPageKey = paginatedQuery.pageKeys[paginatedQuery.pageKeys.length - 1];
    if (lastPageKey === void 0) {
      throw new Error(`No pages for paginated query ${token}`);
    }
    return paginatedQuery.pageKeyToQuery.get(lastPageKey).queryToken;
  }
  mustGetPaginatedQuery(token) {
    const paginatedQuery = this.paginatedQuerySet.get(token);
    if (!paginatedQuery) {
      throw new Error("paginated query no longer exists for token " + token);
    }
    return paginatedQuery;
  }
}
//# sourceMappingURL=paginated_query_client.js.map
