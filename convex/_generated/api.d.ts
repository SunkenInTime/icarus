/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as elements from "../elements.js";
import type * as folders from "../folders.js";
import type * as health from "../health.js";
import type * as images from "../images.js";
import type * as invites from "../invites.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_entities from "../lib/entities.js";
import type * as lib_errors from "../lib/errors.js";
import type * as lib_opTypes from "../lib/opTypes.js";
import type * as lineups from "../lineups.js";
import type * as ops from "../ops.js";
import type * as pages from "../pages.js";
import type * as shares from "../shares.js";
import type * as strategies from "../strategies.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  elements: typeof elements;
  folders: typeof folders;
  health: typeof health;
  images: typeof images;
  invites: typeof invites;
  "lib/auth": typeof lib_auth;
  "lib/entities": typeof lib_entities;
  "lib/errors": typeof lib_errors;
  "lib/opTypes": typeof lib_opTypes;
  lineups: typeof lineups;
  ops: typeof ops;
  pages: typeof pages;
  shares: typeof shares;
  strategies: typeof strategies;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
