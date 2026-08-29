/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as crons from "../crons.js";
import type * as elements from "../elements.js";
import type * as folders from "../folders.js";
import type * as health from "../health.js";
import type * as images from "../images.js";
import type * as invites from "../invites.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_canonicalValues from "../lib/canonicalValues.js";
import type * as lib_cloudProtocol from "../lib/cloudProtocol.js";
import type * as lib_entities from "../lib/entities.js";
import type * as lib_errors from "../lib/errors.js";
import type * as lib_imageAssets from "../lib/imageAssets.js";
import type * as lib_opTypes from "../lib/opTypes.js";
import type * as lib_payloadValidators from "../lib/payloadValidators.js";
import type * as lib_publicValidators from "../lib/publicValidators.js";
import type * as lib_r2 from "../lib/r2.js";
import type * as lib_snapshotSerialization from "../lib/snapshotSerialization.js";
import type * as lineups from "../lineups.js";
import type * as maintenance from "../maintenance.js";
import type * as ops from "../ops.js";
import type * as page from "../page.js";
import type * as pages from "../pages.js";
import type * as shares from "../shares.js";
import type * as strategies from "../strategies.js";
import type * as strategy from "../strategy.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  crons: typeof crons;
  elements: typeof elements;
  folders: typeof folders;
  health: typeof health;
  images: typeof images;
  invites: typeof invites;
  "lib/auth": typeof lib_auth;
  "lib/canonicalValues": typeof lib_canonicalValues;
  "lib/cloudProtocol": typeof lib_cloudProtocol;
  "lib/entities": typeof lib_entities;
  "lib/errors": typeof lib_errors;
  "lib/imageAssets": typeof lib_imageAssets;
  "lib/opTypes": typeof lib_opTypes;
  "lib/payloadValidators": typeof lib_payloadValidators;
  "lib/publicValidators": typeof lib_publicValidators;
  "lib/r2": typeof lib_r2;
  "lib/snapshotSerialization": typeof lib_snapshotSerialization;
  lineups: typeof lineups;
  maintenance: typeof maintenance;
  ops: typeof ops;
  page: typeof page;
  pages: typeof pages;
  shares: typeof shares;
  strategies: typeof strategies;
  strategy: typeof strategy;
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
