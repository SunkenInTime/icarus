"use strict";
import { useState } from "react";
import { getFunctionName } from "../server/api.js";
import { convexToJson } from "../values/value.js";
import { useQueries } from "./use_queries.js";
import { ConvexError } from "../values/errors.js";
import { useConvex } from "./client.js";
export function usePaginatedQuery_experimental(query, args, options) {
  if (typeof options?.initialNumItems !== "number" || options.initialNumItems < 0) {
    throw new Error(
      `\`options.initialNumItems\` must be a positive number. Received \`${options?.initialNumItems}\`.`
    );
  }
  const skip = args === "skip";
  const argsObject = skip ? {} : args;
  const convexClient = useConvex();
  const logger = convexClient.logger;
  const createInitialState = () => {
    const id = nextPaginationId();
    return {
      query,
      args: argsObject,
      id,
      // Queries will contain zero or one queries forever.
      queries: skip ? {} : {
        paginatedQuery: {
          query,
          args: {
            ...argsObject
          },
          paginationOptions: {
            initialNumItems: options.initialNumItems,
            id
          }
        }
      },
      skip
    };
  };
  const [state, setState] = useState(createInitialState);
  let currState = state;
  if (getFunctionName(query) !== getFunctionName(state.query) || JSON.stringify(convexToJson(argsObject)) !== JSON.stringify(convexToJson(state.args)) || skip !== state.skip) {
    currState = createInitialState();
    setState(currState);
  }
  const resultsObject = useQueries(currState.queries);
  if (!("paginatedQuery" in resultsObject)) {
    if (!skip) {
      throw new Error("Why is it missing?");
    }
    return {
      results: [],
      status: "LoadingFirstPage",
      isLoading: true,
      loadMore: function skipNOP(_numItems) {
        return false;
      }
    };
  }
  const result = resultsObject.paginatedQuery;
  if (result === void 0) {
    return {
      results: [],
      loadMore: () => false,
      isLoading: true,
      status: "LoadingFirstPage"
    };
  }
  if (result instanceof Error) {
    if (result.message.includes("InvalidCursor") || result instanceof ConvexError && typeof result.data === "object" && result.data?.isConvexSystemError === true && result.data?.paginationError === "InvalidCursor") {
      logger.warn(
        "usePaginatedQuery hit error, resetting pagination state: " + result.message
      );
      setState(createInitialState);
      return {
        results: [],
        loadMore: () => false,
        isLoading: true,
        status: "LoadingFirstPage"
      };
    } else {
      throw result;
    }
  }
  return {
    ...result,
    loadMore: (num) => {
      return result.loadMore(num);
    },
    isLoading: result.status === "LoadingFirstPage" ? true : result.status === "LoadingMore" ? true : false
  };
}
let paginationId = 0;
function nextPaginationId() {
  paginationId++;
  return paginationId;
}
export function resetPaginationId() {
  paginationId = 0;
}
//# sourceMappingURL=use_paginated_query2.js.map
