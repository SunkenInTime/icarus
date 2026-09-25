import { mutation, type MutationCtx } from "./_generated/server";
import { ConvexError, v, type Infer } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { assertStrategyRole } from "./lib/auth";
import { refreshStrategyAgentSummary } from "./lib/strategyAgentSummary";
import {
  collectAssetIdsShownByLineups,
  expectAssets,
  referencedAssetIds,
  removeUploadPlaceholders,
  staleUploadAgeMs,
} from "./lib/imageAssets";
import {
  clampPageIndex,
  getStrategyByPublicId,
  sortByNumberField,
} from "./lib/entities";
import {
  applyBatchResultValidator,
  currentOpSnapshotValidator,
  operationResultValidator,
  strategyOpValidator,
  type StrategyOp as WireStrategyOp,
} from "./lib/opTypes";
import {
  assertSupportedCloudProtocol,
  CLOUD_OPERATION_TOO_LARGE_MESSAGE,
  cloudOperationExceedsPolicy,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import { valuesEqual } from "./lib/canonicalValues";
import { errorWithCode, invalidPayloadError } from "./lib/errors";
import { purgeDeletedPageOrphansRef } from "./maintenance";

type ElementPayload = Doc<"elements">["payload"];
type LineupPayload = Doc<"lineups">["payload"];
type StrategyPatchPayload = {
  name?: string;
  mapData?: string;
  themeProfileId?: string;
  clearThemeProfileId?: boolean;
  themeOverridePalette?: Doc<"strategies">["themeOverridePalette"];
  clearThemeOverridePalette?: boolean;
};
type PagePayload = {
  name?: string;
  isAutoNamed?: boolean;
  settings?: Doc<"pageContents">["settings"];
  isAttack?: boolean;
};
type StrategyOp = {
  opId: string;
  type: WireStrategyOp["type"];
  kind: "add" | "patch" | "delete" | "reorder";
  entityType: "strategy" | "page" | "pageContent" | "element" | "lineup";
  entityPublicId?: string;
  pagePublicId?: string;
  payload?: unknown;
  sortIndex?: number;
  expectedRevision?: number;
};
type TargetSnapshot = {
  revision: number;
  payload: unknown;
};
type OperationResult = {
  status: "ack" | "reject" | "failed";
  reason?: string;
  appliedRevision?: number;
  latestRevision?: number;
  latestPayload?: unknown;
  code?: string;
  rawCode?: string;
  message?: string;
  eventPageId?: Id<"pages">;
};

type CurrentTarget = StrategyOp["entityType"];
type PublicOperationResult = Infer<typeof operationResultValidator>;

function normalizeOp(op: WireStrategyOp): StrategyOp {
  switch (op.type) {
    case "strategy.patch":
      return {
        opId: op.opId,
        type: op.type,
        kind: "patch",
        entityType: "strategy",
        payload: op.payload,
        expectedRevision: op.expectedStrategyRevision,
      };
    case "page.add":
      return {
        opId: op.opId,
        type: op.type,
        kind: "add",
        entityType: "page",
        entityPublicId: op.pagePublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedStrategyRevision,
      };
    case "page.patch":
      return {
        opId: op.opId,
        type: op.type,
        kind: "patch",
        entityType: "page",
        entityPublicId: op.pagePublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        expectedRevision: op.expectedPageRevision,
      };
    case "page.delete":
      return {
        opId: op.opId,
        type: op.type,
        kind: "delete",
        entityType: "page",
        entityPublicId: op.pagePublicId,
        pagePublicId: op.pagePublicId,
        expectedRevision: op.expectedStrategyRevision,
      };
    case "page.reorder":
      return {
        opId: op.opId,
        type: op.type,
        kind: "reorder",
        entityType: "page",
        entityPublicId: op.pagePublicId,
        pagePublicId: op.pagePublicId,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedStrategyRevision,
      };
    case "pageContent.patch":
      return {
        opId: op.opId,
        type: op.type,
        kind: "patch",
        entityType: "pageContent",
        entityPublicId: op.pagePublicId,
        pagePublicId: op.pagePublicId,
        payload: { settings: op.settings },
        expectedRevision: op.expectedPageContentRevision,
      };
    case "element.add":
      return {
        opId: op.opId,
        type: op.type,
        kind: "add",
        entityType: "element",
        entityPublicId: op.elementPublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedElementRevision,
      };
    case "element.patch":
      return {
        opId: op.opId,
        type: op.type,
        kind: "patch",
        entityType: "element",
        entityPublicId: op.elementPublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedElementRevision,
      };
    case "element.delete":
      return {
        opId: op.opId,
        type: op.type,
        kind: "delete",
        entityType: "element",
        entityPublicId: op.elementPublicId,
        pagePublicId: op.pagePublicId,
        expectedRevision: op.expectedElementRevision,
      };
    case "element.reorder":
      return {
        opId: op.opId,
        type: op.type,
        kind: "reorder",
        entityType: "element",
        entityPublicId: op.elementPublicId,
        pagePublicId: op.pagePublicId,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedElementRevision,
      };
    case "lineup.add":
      return {
        opId: op.opId,
        type: op.type,
        kind: "add",
        entityType: "lineup",
        entityPublicId: op.lineupPublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedLineupRevision,
      };
    case "lineup.patch":
      return {
        opId: op.opId,
        type: op.type,
        kind: "patch",
        entityType: "lineup",
        entityPublicId: op.lineupPublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedLineupRevision,
      };
    case "lineup.delete":
      return {
        opId: op.opId,
        type: op.type,
        kind: "delete",
        entityType: "lineup",
        entityPublicId: op.lineupPublicId,
        pagePublicId: op.pagePublicId,
        expectedRevision: op.expectedLineupRevision,
      };
    case "lineup.reorder":
      return {
        opId: op.opId,
        type: op.type,
        kind: "reorder",
        entityType: "lineup",
        entityPublicId: op.lineupPublicId,
        pagePublicId: op.pagePublicId,
        sortIndex: op.sortIndex,
        expectedRevision: op.expectedLineupRevision,
      };
  }
}

function isRecord(payload: unknown): payload is Record<string, unknown> {
  return (
    typeof payload === "object" && payload !== null && !Array.isArray(payload)
  );
}

function assertKnownPayloadKeys(
  payload: Record<string, unknown>,
  allowedKeys: Set<string>,
  label: string,
): void {
  for (const key of Object.keys(payload)) {
    if (!allowedKeys.has(key)) {
      throw invalidPayloadError(`Invalid ${label} payload`);
    }
  }
}

const strategyPatchPayloadKeys = new Set([
  "name",
  "mapData",
  "themeProfileId",
  "clearThemeProfileId",
  "themeOverridePalette",
  "clearThemeOverridePalette",
]);
const pagePayloadKeys = new Set([
  "name",
  "isAutoNamed",
  "settings",
  "isAttack",
]);

function assertStrategyPatchPayload(payload: unknown): StrategyPatchPayload {
  if (payload === undefined) return {};
  if (!isRecord(payload)) throw invalidPayloadError("Invalid strategy payload");
  assertKnownPayloadKeys(payload, strategyPatchPayloadKeys, "strategy");
  return payload as StrategyPatchPayload;
}

function assertPagePayload(payload: unknown): PagePayload {
  if (payload === undefined) return {};
  if (!isRecord(payload)) throw invalidPayloadError("Invalid page payload");
  assertKnownPayloadKeys(payload, pagePayloadKeys, "page");
  return payload as PagePayload;
}

function assertElementPayload(payload: unknown): ElementPayload {
  if (!isRecord(payload)) {
    throw errorWithCode("MISSING_ELEMENT_PAYLOAD", "Missing element payload");
  }
  const kind = payload.kind;
  if (
    kind !== "agent" &&
    kind !== "ability" &&
    kind !== "drawing" &&
    kind !== "text" &&
    kind !== "image" &&
    kind !== "utility"
  ) {
    throw errorWithCode(
      "INVALID_ELEMENT_PAYLOAD_KIND",
      "Invalid element payload kind",
    );
  }
  if (typeof payload.payloadVersion !== "number") {
    throw errorWithCode(
      "INVALID_ELEMENT_PAYLOAD_VERSION",
      "Invalid element payload version",
    );
  }
  if (!isRecord(payload.data)) {
    throw errorWithCode(
      "INVALID_ELEMENT_PAYLOAD_DATA",
      "Invalid element payload data",
    );
  }
  if (
    typeof payload.data.elementType === "string" &&
    payload.data.elementType !== kind
  ) {
    throw errorWithCode(
      "ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH",
      "elementType_payloadKind_mismatch",
    );
  }
  return payload as ElementPayload;
}

const lineupGraphKinds = new Set<unknown>([
  "lineupOrigin",
  "lineupLanding",
  "lineupLink",
]);

function invalidLineupData(message: string) {
  return errorWithCode("INVALID_LINEUP_PAYLOAD_DATA", message);
}

/// Checks one lineup row before it is stored. A graph row (origin, landing
/// or link) is keyed `<payloadKind>:<entity id>`: entity ids repeat across
/// kinds (a landing made with a link shares the link's id), so the kind is
/// part of the key, and the key must name the entity the payload holds.
function assertLineupPayload(
  payload: unknown,
  lineupPublicId: string,
): LineupPayload {
  if (!isRecord(payload)) {
    throw errorWithCode("MISSING_LINEUP_PAYLOAD", "Missing lineup payload");
  }
  if (payload.kind !== "lineupGroup" && !lineupGraphKinds.has(payload.kind)) {
    throw errorWithCode(
      "INVALID_LINEUP_PAYLOAD_KIND",
      "Invalid lineup payload kind",
    );
  }
  if (typeof payload.payloadVersion !== "number") {
    throw errorWithCode(
      "INVALID_LINEUP_PAYLOAD_VERSION",
      "Invalid lineup payload version",
    );
  }
  if (!isRecord(payload.data)) {
    throw errorWithCode(
      "INVALID_LINEUP_PAYLOAD_DATA",
      "Invalid lineup payload data",
    );
  }
  const data = payload.data;
  if (payload.kind === "lineupGroup") {
    // A lineup group with no items reads back as no lineup at all, so storing
    // one would turn into a deletion nobody made on the next load.
    if (!Array.isArray(data.items) || data.items.length === 0) {
      throw invalidLineupData("Lineup payload has no items");
    }
    return payload as LineupPayload;
  }
  if (typeof data.id !== "string" || data.id.length === 0) {
    throw invalidLineupData("Lineup payload has no id");
  }
  if (lineupPublicId !== `${payload.kind}:${data.id}`) {
    throw invalidLineupData("Lineup key does not match its payload");
  }
  // Each entity must carry what hydration draws; a row without it would load
  // as nothing and read as a deletion nobody made.
  if (payload.kind === "lineupOrigin" && !isRecord(data.agent)) {
    throw invalidLineupData("Lineup origin has no agent");
  }
  if (payload.kind === "lineupLanding" && !isRecord(data.ability)) {
    throw invalidLineupData("Lineup landing has no ability");
  }
  if (
    payload.kind === "lineupLink" &&
    (typeof data.originId !== "string" || typeof data.landingId !== "string")
  ) {
    throw invalidLineupData("Lineup link does not name its origin and landing");
  }
  return payload as LineupPayload;
}

function setIfChanged(
  patch: Record<string, unknown>,
  key: string,
  currentValue: unknown,
  nextValue: unknown,
): void {
  if (!valuesEqual(currentValue, nextValue)) patch[key] = nextValue;
}

function requireExpectedRevision(op: StrategyOp, currentRevision: number) {
  if (op.expectedRevision === undefined) {
    return { status: "reject" as const, reason: "missing_expected_revision" };
  }
  if (op.expectedRevision !== currentRevision) {
    return { status: "reject" as const, reason: "revision_mismatch" };
  }
  return null;
}

function strategyPayload(strategy: Doc<"strategies">) {
  return {
    name: strategy.name,
    mapData: strategy.mapData,
    themeProfileId: strategy.themeProfileId ?? null,
    themeOverridePalette: strategy.themeOverridePalette ?? null,
  };
}

function pagePayload(page: Doc<"pages">) {
  return {
    name: page.name,
    ...(page.isAutoNamed === undefined
      ? {}
      : { isAutoNamed: page.isAutoNamed }),
    isAttack: page.isAttack,
    sortIndex: page.sortIndex,
  };
}

async function getPageByPublicIdOrNull(
  ctx: MutationCtx,
  publicId: string,
): Promise<Doc<"pages"> | null> {
  return await ctx.db
    .query("pages")
    .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
    .first();
}

async function getElementByPublicIdOrNull(
  ctx: MutationCtx,
  publicId: string,
): Promise<Doc<"elements"> | null> {
  return await ctx.db
    .query("elements")
    .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
    .first();
}

async function getLineupByPublicIdOrNull(
  ctx: MutationCtx,
  publicId: string,
): Promise<Doc<"lineups"> | null> {
  return await ctx.db
    .query("lineups")
    .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
    .first();
}

async function getPageContent(
  ctx: MutationCtx,
  pageId: Id<"pages">,
): Promise<Doc<"pageContents">> {
  const rows = await ctx.db
    .query("pageContents")
    .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
    .take(2);
  if (rows.length !== 1) {
    throw errorWithCode(
      "INVALID_PAGE_CONTENT_COUNT",
      "Each page must have exactly one page content row",
    );
  }
  return rows[0]!;
}

async function getTargetSnapshot(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<TargetSnapshot | null> {
  if (
    op.entityType === "strategy" ||
    (op.entityType === "page" && op.kind !== "patch")
  ) {
    return { revision: strategy.revision, payload: strategyPayload(strategy) };
  }
  const publicId = op.entityPublicId ?? op.pagePublicId;
  if (publicId === undefined) return null;
  if (op.entityType === "page") {
    const page = await getPageByPublicIdOrNull(ctx, publicId);
    if (page === null || page.strategyId !== strategy._id) return null;
    return { revision: page.revision, payload: pagePayload(page) };
  }
  if (op.entityType === "pageContent") {
    const page = await getPageByPublicIdOrNull(ctx, publicId);
    if (page === null || page.strategyId !== strategy._id) return null;
    const content = await getPageContent(ctx, page._id);
    return {
      revision: content.revision,
      payload: { settings: content.settings ?? null },
    };
  }
  if (op.entityType === "element") {
    const element = await getElementByPublicIdOrNull(ctx, publicId);
    if (element === null || element.strategyId !== strategy._id) return null;
    return { revision: element.revision, payload: element.payload };
  }
  const lineup = await getLineupByPublicIdOrNull(ctx, publicId);
  if (lineup === null || lineup.strategyId !== strategy._id) return null;
  return { revision: lineup.revision, payload: lineup.payload };
}

function rejected(
  reason: string,
  snapshot?: TargetSnapshot | null,
  eventPageId?: Id<"pages">,
): OperationResult {
  return {
    status: "reject",
    reason,
    latestRevision: snapshot?.revision,
    latestPayload: snapshot?.payload,
    eventPageId,
  };
}

function noop(revision?: number, eventPageId?: Id<"pages">): OperationResult {
  return {
    status: "ack",
    reason: "noop",
    appliedRevision: revision,
    latestRevision: revision,
    eventPageId,
  };
}

function currentTargetForOp(op: StrategyOp): CurrentTarget {
  if (
    op.entityType === "page" &&
    (op.kind === "add" || op.kind === "delete" || op.kind === "reorder")
  ) {
    return "strategy";
  }
  return op.entityType;
}

function isRejectionReason(
  reason: string,
): reason is Extract<PublicOperationResult, { status: "rejected" }>["reason"] {
  return (
    reason === "already_exists" ||
    reason === "element_strategy_mismatch" ||
    reason === "lineup_strategy_mismatch" ||
    reason === "missing_expected_revision" ||
    reason === "not_found" ||
    reason === "page_strategy_mismatch" ||
    reason === "revision_mismatch"
  );
}

function toPublicResult(
  op: StrategyOp,
  result: OperationResult,
): PublicOperationResult {
  if (result.status === "failed") {
    return {
      opId: op.opId,
      status: "failed",
      code: result.code ?? "INTERNAL_ERROR",
      rawCode: result.rawCode ?? "INTERNAL_ERROR",
      message: result.message ?? "Unexpected Convex function failure",
    };
  }
  if (result.status === "ack" && result.reason === "noop") {
    return {
      opId: op.opId,
      status: "noop",
      ...(result.appliedRevision === undefined
        ? {}
        : { currentRevision: result.appliedRevision }),
    };
  }
  if (result.status === "ack") {
    if (result.appliedRevision === undefined) {
      throw new Error(`Applied op ${op.opId} did not return a revision`);
    }
    return {
      opId: op.opId,
      status: "applied",
      appliedRevision: result.appliedRevision,
    };
  }
  const reason = result.reason ?? "not_found";
  if (!isRejectionReason(reason)) {
    throw new Error(`Unknown op rejection reason: ${reason}`);
  }
  return {
    opId: op.opId,
    status: "rejected",
    reason,
    ...(result.latestRevision === undefined || result.latestPayload === undefined
      ? {}
      : {
          current: {
            type: currentTargetForOp(op),
            revision: result.latestRevision,
            value: result.latestPayload,
          } as Infer<typeof currentOpSnapshotValidator>,
        }),
  };
}

async function applyStrategyOp(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<{ strategy: Doc<"strategies">; result: OperationResult }> {
  if (op.kind !== "patch") {
    throw errorWithCode("UNSUPPORTED_OP", "Unsupported strategy op");
  }
  const payload = assertStrategyPatchPayload(op.payload);
  const patch: Record<string, unknown> = {};
  if (payload.name !== undefined) {
    setIfChanged(patch, "name", strategy.name, payload.name);
  }
  if (payload.mapData !== undefined) {
    setIfChanged(patch, "mapData", strategy.mapData, payload.mapData);
  }
  if (payload.themeProfileId !== undefined) {
    setIfChanged(
      patch,
      "themeProfileId",
      strategy.themeProfileId,
      payload.themeProfileId,
    );
  }
  if (payload.clearThemeProfileId === true) {
    setIfChanged(patch, "themeProfileId", strategy.themeProfileId, undefined);
  }
  if (payload.themeOverridePalette !== undefined) {
    setIfChanged(
      patch,
      "themeOverridePalette",
      strategy.themeOverridePalette,
      payload.themeOverridePalette,
    );
  }
  if (payload.clearThemeOverridePalette === true) {
    setIfChanged(
      patch,
      "themeOverridePalette",
      strategy.themeOverridePalette,
      undefined,
    );
  }
  if (Object.keys(patch).length === 0) {
    return { strategy, result: noop(strategy.revision) };
  }
  const mismatch = requireExpectedRevision(op, strategy.revision);
  if (mismatch !== null) {
    return {
      strategy,
      result: rejected(mismatch.reason, {
        revision: strategy.revision,
        payload: strategyPayload(strategy),
      }),
    };
  }

  const revision = strategy.revision + 1;
  const updatedAt = Date.now();
  await ctx.db.patch(strategy._id, { ...patch, revision, updatedAt });
  const updated = {
    ...strategy,
    ...patch,
    revision,
    updatedAt,
  } as Doc<"strategies">;
  return {
    strategy: updated,
    result: { status: "ack", appliedRevision: revision },
  };
}

async function applyPageOp(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<{ strategy: Doc<"strategies">; result: OperationResult }> {
  const publicId = op.entityPublicId ?? op.pagePublicId;
  if (publicId === undefined) {
    throw errorWithCode("MISSING_PAGE_ID", "Missing page id");
  }
  const existing = await getPageByPublicIdOrNull(ctx, publicId);

  if (op.kind === "add") {
    const payload = assertPagePayload(op.payload);
    if (existing !== null) {
      if (existing.strategyId !== strategy._id) {
        return { strategy, result: rejected("page_strategy_mismatch") };
      }
      const content = await getPageContent(ctx, existing._id);
      const pages = await ctx.db
        .query("pages")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
        .collect();
      const desiredSortIndex = clampPageIndex(
        op.sortIndex ?? 0,
        Math.max(0, pages.length - 1),
      );
      const identical =
        existing.name === (payload.name ?? "Page") &&
        existing.isAutoNamed === payload.isAutoNamed &&
        existing.sortIndex === desiredSortIndex &&
        existing.isAttack === (payload.isAttack ?? true) &&
        valuesEqual(content.settings, payload.settings);
      if (identical) {
        return { strategy, result: noop(strategy.revision, existing._id) };
      }
      return {
        strategy,
        result: rejected(
          "already_exists",
          { revision: strategy.revision, payload: strategyPayload(strategy) },
          existing._id,
        ),
      };
    }
    const mismatch = requireExpectedRevision(op, strategy.revision);
    if (mismatch !== null) {
      return {
        strategy,
        result: rejected(mismatch.reason, {
          revision: strategy.revision,
          payload: strategyPayload(strategy),
        }),
      };
    }

    const now = Date.now();
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    const orderedPages = sortByNumberField(pages, "sortIndex");
    const desiredSortIndex = clampPageIndex(
      op.sortIndex ?? 0,
      orderedPages.length,
    );
    for (let index = 0; index < orderedPages.length; index += 1) {
      const page = orderedPages[index]!;
      const normalizedIndex = index >= desiredSortIndex ? index + 1 : index;
      const normalizedName =
        page.isAutoNamed === true
          ? `Page ${normalizedIndex + 1}`
          : page.name;
      if (
        page.sortIndex !== normalizedIndex ||
        page.name !== normalizedName
      ) {
        await ctx.db.patch(page._id, {
          name: normalizedName,
          sortIndex: normalizedIndex,
          revision: page.revision + 1,
          updatedAt: now,
        });
      }
    }
    const pageId = await ctx.db.insert("pages", {
      publicId,
      strategyId: strategy._id,
      name: payload.name ?? "Page",
      ...(payload.isAutoNamed === undefined
        ? {}
        : { isAutoNamed: payload.isAutoNamed }),
      sortIndex: desiredSortIndex,
      isAttack: payload.isAttack ?? true,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("pageContents", {
      pageId,
      settings: payload.settings,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });
    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, { revision, updatedAt: now });
    return {
      strategy: { ...strategy, revision, updatedAt: now },
      result: { status: "ack", appliedRevision: revision, eventPageId: pageId },
    };
  }

  if (op.kind === "delete") {
    if (existing === null || existing.strategyId !== strategy._id) {
      return { strategy, result: noop(strategy.revision) };
    }
    const mismatch = requireExpectedRevision(op, strategy.revision);
    if (mismatch !== null) {
      return {
        strategy,
        result: rejected(
          mismatch.reason,
          { revision: strategy.revision, payload: strategyPayload(strategy) },
          existing._id,
        ),
      };
    }
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    if (pages.length <= 1) {
      throw errorWithCode("INVALID_OP", "Cannot delete last page");
    }
    const contentRows = await ctx.db
      .query("pageContents")
      .withIndex("by_pageId", (q) => q.eq("pageId", existing._id))
      .collect();
    for (const content of contentRows) await ctx.db.delete(content._id);
    await ctx.db.delete(existing._id);
    await ctx.scheduler.runAfter(0, purgeDeletedPageOrphansRef, {
      pageId: existing._id,
      strategyId: strategy._id,
    });
    const now = Date.now();
    const remaining = sortByNumberField(
      pages.filter((page) => page._id !== existing._id),
      "sortIndex",
    );
    for (let index = 0; index < remaining.length; index += 1) {
      const page = remaining[index]!;
      const normalizedName =
        page.isAutoNamed === true ? `Page ${index + 1}` : page.name;
      if (page.sortIndex !== index || page.name !== normalizedName) {
        await ctx.db.patch(page._id, {
          name: normalizedName,
          sortIndex: index,
          revision: page.revision + 1,
          updatedAt: now,
        });
      }
    }
    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, { revision, updatedAt: now });
    return {
      strategy: { ...strategy, revision, updatedAt: now },
      result: {
        status: "ack",
        appliedRevision: revision,
        eventPageId: existing._id,
      },
    };
  }

  if (existing === null || existing.strategyId !== strategy._id) {
    return { strategy, result: rejected("not_found") };
  }
  if (op.kind === "reorder") {
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    const orderedPages = sortByNumberField(pages, "sortIndex");
    const currentIndex = orderedPages.findIndex(
      (page) => page._id === existing._id,
    );
    const desiredSortIndex = clampPageIndex(
      op.sortIndex ?? currentIndex,
      Math.max(0, orderedPages.length - 1),
    );
    const reorderedPages = orderedPages.filter(
      (page) => page._id !== existing._id,
    );
    reorderedPages.splice(desiredSortIndex, 0, existing);
    const alreadyNormalized = reorderedPages.every(
      (page, index) => page.sortIndex === index,
    );
    if (currentIndex === desiredSortIndex && alreadyNormalized) {
      return { strategy, result: noop(strategy.revision, existing._id) };
    }
    const mismatch = requireExpectedRevision(op, strategy.revision);
    if (mismatch !== null) {
      return {
        strategy,
        result: rejected(
          mismatch.reason,
          { revision: strategy.revision, payload: strategyPayload(strategy) },
          existing._id,
        ),
      };
    }
    const now = Date.now();
    for (let index = 0; index < reorderedPages.length; index += 1) {
      const page = reorderedPages[index]!;
      const normalizedName =
        page.isAutoNamed === true ? `Page ${index + 1}` : page.name;
      if (page.sortIndex !== index || page.name !== normalizedName) {
        await ctx.db.patch(page._id, {
          name: normalizedName,
          sortIndex: index,
          revision: page.revision + 1,
          updatedAt: now,
        });
      }
    }
    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, { revision, updatedAt: now });
    return {
      strategy: { ...strategy, revision, updatedAt: now },
      result: {
        status: "ack",
        appliedRevision: revision,
        eventPageId: existing._id,
      },
    };
  }
  if (op.kind !== "patch") {
    throw errorWithCode("UNSUPPORTED_OP", "Unsupported page op");
  }
  const payload = assertPagePayload(op.payload);
  if (payload.settings !== undefined) {
    throw errorWithCode(
      "PAGE_SETTINGS_REQUIRE_PAGE_CONTENT",
      "Page settings require a pageContent operation",
    );
  }
  const patch: Record<string, unknown> = {};
  if (payload.name !== undefined) {
    setIfChanged(patch, "name", existing.name, payload.name);
  }
  if (payload.isAutoNamed !== undefined) {
    setIfChanged(
      patch,
      "isAutoNamed",
      existing.isAutoNamed,
      payload.isAutoNamed,
    );
  }
  if (payload.isAttack !== undefined) {
    setIfChanged(patch, "isAttack", existing.isAttack, payload.isAttack);
  }
  if (Object.keys(patch).length === 0) {
    return { strategy, result: noop(existing.revision, existing._id) };
  }
  const mismatch = requireExpectedRevision(op, existing.revision);
  if (mismatch !== null) {
    return {
      strategy,
      result: rejected(
        mismatch.reason,
        { revision: existing.revision, payload: pagePayload(existing) },
        existing._id,
      ),
    };
  }
  const revision = existing.revision + 1;
  await ctx.db.patch(existing._id, {
    ...patch,
    revision,
    updatedAt: Date.now(),
  });
  return {
    strategy,
    result: {
      status: "ack",
      appliedRevision: revision,
      eventPageId: existing._id,
    },
  };
}

async function applyPageContentOp(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<OperationResult> {
  if (op.kind !== "patch") {
    throw errorWithCode("UNSUPPORTED_OP", "Unsupported page content op");
  }
  const publicId = op.entityPublicId ?? op.pagePublicId;
  if (publicId === undefined) {
    throw errorWithCode("MISSING_PAGE_ID", "Missing page id");
  }
  const page = await getPageByPublicIdOrNull(ctx, publicId);
  if (page === null || page.strategyId !== strategy._id) {
    return rejected("not_found");
  }
  const payload = assertPagePayload(op.payload);
  if (payload.name !== undefined || payload.isAttack !== undefined) {
    throw errorWithCode(
      "PAGE_DESCRIPTOR_REQUIRES_PAGE_OP",
      "Page descriptor fields require a page operation",
    );
  }
  const content = await getPageContent(ctx, page._id);
  if (valuesEqual(content.settings, payload.settings)) {
    return noop(content.revision, page._id);
  }
  const mismatch = requireExpectedRevision(op, content.revision);
  if (mismatch !== null) {
    return rejected(
      mismatch.reason,
      {
        revision: content.revision,
        payload: { settings: content.settings ?? null },
      },
      page._id,
    );
  }
  const revision = content.revision + 1;
  await ctx.db.patch(content._id, {
    settings: payload.settings,
    revision,
    updatedAt: Date.now(),
  });
  return { status: "ack", appliedRevision: revision, eventPageId: page._id };
}

async function applyElementOp(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<OperationResult> {
  const publicId = op.entityPublicId;
  if (publicId === undefined) {
    throw errorWithCode("MISSING_ENTITY_PUBLIC_ID", "Missing entityPublicId");
  }
  const existing = await getElementByPublicIdOrNull(ctx, publicId);

  if (op.kind === "add") {
    if (op.pagePublicId === undefined) {
      throw errorWithCode("MISSING_PAGE_PUBLIC_ID", "Missing pagePublicId");
    }
    const page = await getPageByPublicIdOrNull(ctx, op.pagePublicId);
    if (page === null || page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }
    const payload = assertElementPayload(op.payload);
    if (existing !== null) {
      if (existing.strategyId !== strategy._id) {
        return rejected("element_strategy_mismatch");
      }
      if (existing.deleted) {
        const mismatch = requireExpectedRevision(op, existing.revision);
        if (mismatch !== null) {
          return rejected(
            mismatch.reason,
            { revision: existing.revision, payload: existing.payload },
            existing.pageId,
          );
        }
        const revision = existing.revision + 1;
        await ctx.db.patch(existing._id, {
          pageId: page._id,
          elementType: payload.kind,
          payloadKind: payload.kind,
          payloadVersion: payload.payloadVersion,
          payload,
          sortIndex: op.sortIndex ?? 0,
          revision,
          deleted: false,
          updatedAt: Date.now(),
        });
        return {
          status: "ack",
          appliedRevision: revision,
          eventPageId: page._id,
        };
      }
      const identical =
        existing.pageId === page._id &&
        existing.elementType === payload.kind &&
        valuesEqual(existing.payload, payload) &&
        existing.sortIndex === (op.sortIndex ?? 0) &&
        existing.deleted === false;
      if (identical) return noop(existing.revision, existing.pageId);
      return rejected(
        "already_exists",
        { revision: existing.revision, payload: existing.payload },
        existing.pageId,
      );
    }
    const now = Date.now();
    await ctx.db.insert("elements", {
      publicId,
      strategyId: strategy._id,
      pageId: page._id,
      elementType: payload.kind,
      payloadKind: payload.kind,
      payloadVersion: payload.payloadVersion,
      payload,
      sortIndex: op.sortIndex ?? 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
    return { status: "ack", appliedRevision: 1, eventPageId: page._id };
  }

  if (op.kind === "delete") {
    if (existing === null || existing.strategyId !== strategy._id)
      return noop();
    if (existing.deleted) return noop(existing.revision, existing.pageId);
    const mismatch = requireExpectedRevision(op, existing.revision);
    if (mismatch !== null) {
      return rejected(
        mismatch.reason,
        { revision: existing.revision, payload: existing.payload },
        existing.pageId,
      );
    }
    const revision = existing.revision + 1;
    await ctx.db.patch(existing._id, {
      deleted: true,
      revision,
      updatedAt: Date.now(),
    });
    return {
      status: "ack",
      appliedRevision: revision,
      eventPageId: existing.pageId,
    };
  }

  if (existing === null || existing.strategyId !== strategy._id) {
    return rejected("not_found");
  }
  const patch: Record<string, unknown> = {};
  let eventPageId = existing.pageId;
  if (op.kind === "patch") {
    if (op.payload !== undefined) {
      const payload = assertElementPayload(op.payload);
      if (payload.kind !== existing.elementType) {
        throw errorWithCode(
          "ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH",
          "elementType_payloadKind_mismatch",
        );
      }
      setIfChanged(patch, "payload", existing.payload, payload);
      setIfChanged(patch, "payloadKind", existing.payloadKind, payload.kind);
      setIfChanged(
        patch,
        "payloadVersion",
        existing.payloadVersion,
        payload.payloadVersion,
      );
    }
    if (op.sortIndex !== undefined) {
      setIfChanged(patch, "sortIndex", existing.sortIndex, op.sortIndex);
    }
    if (op.pagePublicId !== undefined) {
      const page = await getPageByPublicIdOrNull(ctx, op.pagePublicId);
      if (page === null || page.strategyId !== strategy._id) {
        throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
      }
      setIfChanged(patch, "pageId", existing.pageId, page._id);
      eventPageId = page._id;
    }
  } else if (op.kind === "reorder") {
    setIfChanged(
      patch,
      "sortIndex",
      existing.sortIndex,
      op.sortIndex ?? existing.sortIndex,
    );
  } else {
    throw errorWithCode("UNSUPPORTED_OP", "Unsupported element op");
  }
  if (Object.keys(patch).length === 0) {
    return noop(existing.revision, eventPageId);
  }
  const mismatch = requireExpectedRevision(op, existing.revision);
  if (mismatch !== null) {
    return rejected(
      mismatch.reason,
      { revision: existing.revision, payload: existing.payload },
      existing.pageId,
    );
  }
  const revision = existing.revision + 1;
  await ctx.db.patch(existing._id, {
    ...patch,
    revision,
    updatedAt: Date.now(),
  });
  return { status: "ack", appliedRevision: revision, eventPageId };
}

async function applyLineupOp(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<OperationResult> {
  const publicId = op.entityPublicId;
  if (publicId === undefined) {
    throw errorWithCode("MISSING_ENTITY_PUBLIC_ID", "Missing entityPublicId");
  }
  const existing = await getLineupByPublicIdOrNull(ctx, publicId);

  if (op.kind === "add") {
    if (op.pagePublicId === undefined) {
      throw errorWithCode("MISSING_PAGE_PUBLIC_ID", "Missing pagePublicId");
    }
    const page = await getPageByPublicIdOrNull(ctx, op.pagePublicId);
    if (page === null || page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }
    const payload = assertLineupPayload(op.payload, publicId);
    if (existing !== null) {
      if (existing.strategyId !== strategy._id) {
        return rejected("lineup_strategy_mismatch");
      }
      if (existing.deleted) {
        const mismatch = requireExpectedRevision(op, existing.revision);
        if (mismatch !== null) {
          return rejected(
            mismatch.reason,
            { revision: existing.revision, payload: existing.payload },
            existing.pageId,
          );
        }
        const revision = existing.revision + 1;
        await ctx.db.patch(existing._id, {
          pageId: page._id,
          payloadKind: payload.kind,
          payloadVersion: payload.payloadVersion,
          payload,
          sortIndex: op.sortIndex ?? 0,
          revision,
          deleted: false,
          updatedAt: Date.now(),
        });
        return {
          status: "ack",
          appliedRevision: revision,
          eventPageId: page._id,
        };
      }
      const identical =
        existing.pageId === page._id &&
        valuesEqual(existing.payload, payload) &&
        existing.sortIndex === (op.sortIndex ?? 0) &&
        existing.deleted === false;
      if (identical) return noop(existing.revision, existing.pageId);
      return rejected(
        "already_exists",
        { revision: existing.revision, payload: existing.payload },
        existing.pageId,
      );
    }
    const now = Date.now();
    await ctx.db.insert("lineups", {
      publicId,
      strategyId: strategy._id,
      pageId: page._id,
      payloadKind: payload.kind,
      payloadVersion: payload.payloadVersion,
      payload,
      sortIndex: op.sortIndex ?? 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
    return { status: "ack", appliedRevision: 1, eventPageId: page._id };
  }

  if (op.kind === "delete") {
    if (existing === null || existing.strategyId !== strategy._id)
      return noop();
    if (existing.deleted) return noop(existing.revision, existing.pageId);
    const mismatch = requireExpectedRevision(op, existing.revision);
    if (mismatch !== null) {
      return rejected(
        mismatch.reason,
        { revision: existing.revision, payload: existing.payload },
        existing.pageId,
      );
    }
    const revision = existing.revision + 1;
    await ctx.db.patch(existing._id, {
      deleted: true,
      revision,
      updatedAt: Date.now(),
    });
    return {
      status: "ack",
      appliedRevision: revision,
      eventPageId: existing.pageId,
    };
  }

  if (existing === null || existing.strategyId !== strategy._id) {
    return rejected("not_found");
  }
  const patch: Record<string, unknown> = {};
  let eventPageId = existing.pageId;
  if (op.kind === "patch") {
    if (op.payload !== undefined) {
      const payload = assertLineupPayload(op.payload, publicId);
      setIfChanged(patch, "payload", existing.payload, payload);
      setIfChanged(patch, "payloadKind", existing.payloadKind, payload.kind);
      setIfChanged(
        patch,
        "payloadVersion",
        existing.payloadVersion,
        payload.payloadVersion,
      );
    }
    if (op.sortIndex !== undefined) {
      setIfChanged(patch, "sortIndex", existing.sortIndex, op.sortIndex);
    }
    if (op.pagePublicId !== undefined) {
      const page = await getPageByPublicIdOrNull(ctx, op.pagePublicId);
      if (page === null || page.strategyId !== strategy._id) {
        throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
      }
      setIfChanged(patch, "pageId", existing.pageId, page._id);
      eventPageId = page._id;
    }
  } else if (op.kind === "reorder") {
    setIfChanged(
      patch,
      "sortIndex",
      existing.sortIndex,
      op.sortIndex ?? existing.sortIndex,
    );
  } else {
    throw errorWithCode("UNSUPPORTED_OP", "Unsupported lineup op");
  }
  if (Object.keys(patch).length === 0) {
    return noop(existing.revision, eventPageId);
  }
  const mismatch = requireExpectedRevision(op, existing.revision);
  if (mismatch !== null) {
    return rejected(
      mismatch.reason,
      { revision: existing.revision, payload: existing.payload },
      existing.pageId,
    );
  }
  const revision = existing.revision + 1;
  await ctx.db.patch(existing._id, {
    ...patch,
    revision,
    updatedAt: Date.now(),
  });
  return { status: "ack", appliedRevision: revision, eventPageId };
}

/// The element or lineup row an op targets in this strategy, if any.
async function contentRowForOp(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
): Promise<Doc<"elements"> | Doc<"lineups"> | null> {
  const publicId = op.entityPublicId;
  if (publicId === undefined) return null;
  const row =
    op.entityType === "element"
      ? await getElementByPublicIdOrNull(ctx, publicId)
      : op.entityType === "lineup"
        ? await getLineupByPublicIdOrNull(ctx, publicId)
        : null;
  return row !== null && row.strategyId === strategy._id ? row : null;
}

/// Keeps asset rows in step with an accepted content op. An image the row
/// newly shows gets a placeholder if nothing has been uploaded for it yet, so
/// a slow upload reads as on its way rather than missing, and a duplicate
/// waits for it. A deleted image element drops its placeholder unless a
/// lineup still shows the image; [shownByLineups] reads that at most once
/// per batch.
///
/// Restoring a deleted element (undo) usually finds its asset row still
/// there, since deleting an element leaves its asset alone. With no row, an
/// element restored within the stale-upload window may still have its upload
/// coming, so it gets a placeholder like a new one. One first placed longer
/// ago would have uploaded or been swept by now, so it does not: a
/// placeholder there could only spin for another day before reading as
/// unavailable.
async function reconcileExpectedAssets(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  op: StrategyOp,
  rowBefore: Doc<"elements"> | Doc<"lineups"> | null,
  shownByLineups: () => Promise<Set<string>>,
): Promise<void> {
  const row = await contentRowForOp(ctx, strategy, op);
  if (row === null) return;
  const now = Date.now();
  const assetsBefore = referencedAssetIds(rowBefore);
  const assetsAfter = referencedAssetIds(row);
  const restoredAfterUploadWindow =
    op.entityType === "element" &&
    rowBefore?.deleted === true &&
    !row.deleted &&
    now - row.createdAt >= staleUploadAgeMs;
  if (!restoredAfterUploadWindow) {
    await expectAssets(
      ctx,
      strategy._id,
      [...assetsAfter].filter((id) => !assetsBefore.has(id)),
      now,
    );
  }
  if (op.entityType === "element") {
    await removeUploadPlaceholders(
      ctx,
      strategy._id,
      [...assetsBefore].filter((id) => !assetsAfter.has(id)),
      shownByLineups,
    );
  }
}

export const applyBatch = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    clientId: v.string(),
    ops: v.array(strategyOpValidator),
  },
  returns: applyBatchResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    let strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const results: PublicOperationResult[] = [];
    let acceptedStrategyBatchBaseRevision: number | undefined;
    let contentChanged = false;
    // The images the strategy's lineups show, read once per batch and only
    // when deleting an image leaves a placeholder at stake.
    let lineupAssetIds: Promise<Set<string>> | null = null;
    const shownByLineups = () =>
      (lineupAssetIds ??= collectAssetIdsShownByLineups(ctx, strategy._id));

    // Outcomes are per operation: accepted changes and visible rejections are
    // committed together by this single Convex transaction. One stale op must
    // not erase an independent op that the server already accepted.
    for (const rawOp of args.ops) {
      let op = normalizeOp(rawOp);
      const existingEvent = await ctx.db
        .query("operationEvents")
        .withIndex("by_strategyId_clientId_opId", (q) =>
          q
            .eq("strategyId", strategy._id)
            .eq("clientId", args.clientId)
            .eq("opId", op.opId),
        )
        .first();
      if (existingEvent !== null) {
        const latest = await getTargetSnapshot(ctx, strategy, op);
        const replayResult: OperationResult =
          existingEvent.status === "failed"
            ? {
                status: "failed",
                code: existingEvent.code,
                rawCode: existingEvent.rawCode,
                message: existingEvent.message,
              }
            : existingEvent.status === "rejected"
              ? {
                  status: "reject",
                  reason: existingEvent.reason,
                  latestRevision: latest?.revision,
                  latestPayload: latest?.payload,
                }
              : noop(latest?.revision);
        results.push(toPublicResult(op, replayResult));
        continue;
      }

      const originalExpectedRevision = op.expectedRevision;
      const targetsStrategyRevision = currentTargetForOp(op) === "strategy";
      const strategyRevisionBefore = strategy.revision;
      if (
        targetsStrategyRevision &&
        acceptedStrategyBatchBaseRevision !== undefined &&
        originalExpectedRevision === acceptedStrategyBatchBaseRevision
      ) {
        // Offline clients can queue several independent page structure edits
        // from one strategy snapshot. Once the first matching op advances the
        // strategy in this transaction, chain its same-base siblings onto the
        // revision produced by the preceding op. A stale first op never opens
        // this path, so another client's revision still rejects the full batch.
        op = { ...op, expectedRevision: strategy.revision };
      }

      const rowBefore = await contentRowForOp(ctx, strategy, op);

      let result: OperationResult;
      if (cloudOperationExceedsPolicy(rawOp)) {
        result = {
          status: "failed",
          code: "INVALID_PAYLOAD",
          rawCode: "INVALID_PAYLOAD",
          message: CLOUD_OPERATION_TOO_LARGE_MESSAGE,
        };
      } else {
        try {
          if (op.entityType === "strategy") {
            const applied = await applyStrategyOp(ctx, strategy, op);
            strategy = applied.strategy;
            result = applied.result;
          } else if (op.entityType === "page") {
            const applied = await applyPageOp(ctx, strategy, op);
            strategy = applied.strategy;
            result = applied.result;
          } else if (op.entityType === "pageContent") {
            result = await applyPageContentOp(ctx, strategy, op);
          } else if (op.entityType === "element") {
            result = await applyElementOp(ctx, strategy, op);
          } else {
            result = await applyLineupOp(ctx, strategy, op);
          }
          if (result.status === "ack" && op.entityType !== "strategy") {
            contentChanged = true;
          }
          if (result.status === "ack") {
            await reconcileExpectedAssets(
              ctx,
              strategy,
              op,
              rowBefore,
              shownByLineups,
            );
          }
        } catch (error) {
          if (!(error instanceof ConvexError)) throw error;
          const rawCode =
            typeof error.data?.code === "string"
              ? error.data.code
              : "INTERNAL_ERROR";
          const message =
            typeof error.data?.message === "string"
              ? error.data.message
              : error.message;
          result = {
            status: "failed",
            code: rawCode,
            rawCode,
            message,
          };
        }
      }

      if (
        targetsStrategyRevision &&
        acceptedStrategyBatchBaseRevision === undefined &&
        originalExpectedRevision !== undefined &&
        originalExpectedRevision === strategyRevisionBefore &&
        result.status === "ack"
      ) {
        acceptedStrategyBatchBaseRevision = originalExpectedRevision;
      }

      const publicResult = toPublicResult(op, result);

      await ctx.db.insert("operationEvents", {
        strategyId: strategy._id,
        pageId: result.eventPageId,
        clientId: args.clientId,
        opId: op.opId,
        opType: op.type,
        status: publicResult.status,
        reason:
          publicResult.status === "rejected" ? publicResult.reason : undefined,
        code: publicResult.status === "failed" ? publicResult.code : undefined,
        rawCode:
          publicResult.status === "failed" ? publicResult.rawCode : undefined,
        message:
          publicResult.status === "failed" ? publicResult.message : undefined,
        expectedRevision: originalExpectedRevision,
        appliedRevision:
          publicResult.status === "applied"
            ? publicResult.appliedRevision
            : publicResult.status === "noop"
              ? publicResult.currentRevision
              : undefined,
        createdAt: Date.now(),
      });
      results.push(publicResult);
    }

    if (contentChanged) {
      await refreshStrategyAgentSummary(ctx, strategy._id);
    }

    return { strategyPublicId: strategy.publicId, results };
  },
});
