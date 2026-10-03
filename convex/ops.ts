import { mutation, type MutationCtx } from "./_generated/server";
import { ConvexError, v, type Infer } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { assertCallerIsAccount, assertStrategyRole } from "./lib/auth";
import {
  refreshStrategyAgentSummary,
  syncLineupAgents,
} from "./lib/strategyAgentSummary";
import {
  expectAssets,
  referencedAssetIds,
  staleUploadAgeMs,
} from "./lib/imageAssets";
import {
  removeUploadPlaceholders,
  syncElementAssetReferences,
  syncLineupAssetReferences,
} from "./lib/assetReferences";
import {
  clampPageIndex,
  getStrategyByPublicId,
  isTrashed,
  listLivePages,
  sortByNumberField,
  trashPage,
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
import { assertLineupGroupAlone, syncLineupItems } from "./lib/lineupItems";
import { LINEUPS_PAYLOAD_VERSION } from "./lib/payloadValidators";
import {
  errorWithCode,
  invalidPayloadError,
  pageDeletedError,
} from "./lib/errors";

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

function invalidLineupData(message: string) {
  return errorWithCode("INVALID_LINEUP_PAYLOAD_DATA", message);
}

/// Checks one lineup group row before it is stored: a group keyed by its
/// id, whose origins, landings and links each have an id unique among their
/// kind, each origin placing an agent and each landing an ability, with at
/// least one link, and every link joining an origin and a landing the row
/// holds. A row that breaks any of these is refused whole, never stored.
/// A spot no link uses is allowed.
function assertLineupPayload(
  payload: unknown,
  lineupPublicId: string,
): LineupPayload {
  if (!isRecord(payload)) {
    throw errorWithCode("MISSING_LINEUP_PAYLOAD", "Missing lineup payload");
  }
  // Argument validation lets the graph rows of protocol 4 through, so an old
  // client reaches the protocol gate (see lineupOpPayloadValidator); none is
  // ever stored.
  if (payload.kind !== "lineups") {
    throw errorWithCode(
      "INVALID_LINEUP_PAYLOAD_KIND",
      "Invalid lineup payload kind",
    );
  }
  if (payload.payloadVersion !== LINEUPS_PAYLOAD_VERSION) {
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
  if (typeof data.id !== "string" || data.id.length === 0) {
    throw invalidLineupData("Lineup group has no id");
  }
  if (lineupPublicId !== data.id) {
    throw invalidLineupData("Lineup group key does not match its payload");
  }
  const originIds = idsOfEntries(data.origins, "origins", "agent");
  const landingIds = idsOfEntries(data.landings, "landings", "ability");
  idsOfEntries(data.links, "links");
  const links = data.links as Array<Record<string, unknown>>;
  // A group without a lineup would load as nothing and read as a deletion
  // nobody made.
  if (links.length === 0) {
    throw invalidLineupData("Lineup group has no lineups");
  }
  for (const link of links) {
    if (
      typeof link.originId !== "string" ||
      !originIds.has(link.originId) ||
      typeof link.landingId !== "string" ||
      !landingIds.has(link.landingId)
    ) {
      throw invalidLineupData(
        "A lineup names an origin or landing its group does not hold",
      );
    }
  }
  return payload as LineupPayload;
}

/// The ids of a lineup group's [field] (its origins, landings or links),
/// refusing the row unless [entries] is a list of objects each with an id
/// no other entry in it shares, and, given a [markerKey], the object it
/// places there.
function idsOfEntries(
  entries: unknown,
  field: string,
  markerKey?: "agent" | "ability",
): Set<string> {
  if (!Array.isArray(entries)) {
    throw invalidLineupData(`Lineup group ${field} is not a list`);
  }
  const ids = new Set<string>();
  for (const entry of entries) {
    if (
      !isRecord(entry) ||
      typeof entry.id !== "string" ||
      entry.id.length === 0
    ) {
      throw invalidLineupData(`Lineup group ${field} has an entry with no id`);
    }
    if (ids.has(entry.id)) {
      throw invalidLineupData(`Two of a lineup group's ${field} share an id`);
    }
    if (markerKey !== undefined && !isRecord(entry[markerKey])) {
      throw invalidLineupData(
        `Lineup group ${field} has an entry with no ${markerKey}`,
      );
    }
    ids.add(entry.id);
  }
  return ids;
}

/// A patch or reorder of a row a teammate deleted. Changing the tombstone
/// would ack an edit nobody sees, so it is refused; an add expecting the
/// tombstone's revision brings the row back instead ("Keep mine").
function refuseChangeToDeleted(
  row: Doc<"elements"> | Doc<"lineups">,
): OperationResult | null {
  if (!row.deleted) return null;
  return rejected(
    "deleted",
    { revision: row.revision, payload: row.payload },
    row.pageId,
  );
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

/// Whether content on [pageId] can change: not on a page in the trash, nor
/// on one an older delete removed whose rows wait to be purged.
async function contentPageIsLive(
  ctx: MutationCtx,
  pageId: Id<"pages">,
): Promise<boolean> {
  const page = await ctx.db.get(pageId);
  return page !== null && !isTrashed(page);
}

/// Refuses a change to content that is not on a live page. A change refused
/// while its page is in the trash lands if the page is restored and it is
/// sent again.
async function assertContentPageLive(
  ctx: MutationCtx,
  pageId: Id<"pages">,
): Promise<void> {
  if (!(await contentPageIsLive(ctx, pageId))) throw pageDeletedError();
}

/// A delete of content on a page that is not live. A client that can
/// restore pages is refused, so the delete is sent again once the page is
/// back. Older clients get the no-op they got when a deleted page's content
/// was purged: they cannot restore it, and have nothing left to delete.
async function refuseDeleteOffLivePage(
  ctx: MutationCtx,
  row: Doc<"elements"> | Doc<"lineups">,
  checkTrashedPageDeletes: boolean,
): Promise<OperationResult | null> {
  if (await contentPageIsLive(ctx, row.pageId)) return null;
  if (checkTrashedPageDeletes) throw pageDeletedError();
  return noop(row.revision, row.pageId);
}

/// The page a content op names to add to or move to: refused if it is not
/// this strategy's, or is in the trash.
async function requireTargetPage(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
  pagePublicId: string,
): Promise<Doc<"pages">> {
  const page = await getPageByPublicIdOrNull(ctx, pagePublicId);
  if (page === null || page.strategyId !== strategy._id) {
    throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
  }
  if (isTrashed(page)) throw pageDeletedError();
  return page;
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

/// A lineup row key is unique within its strategy only: a strategy copied
/// on a device keeps its original's lineup ids, so both upload the same keys.
async function getLineupByPublicIdOrNull(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  publicId: string,
): Promise<Doc<"lineups"> | null> {
  return await ctx.db
    .query("lineups")
    .withIndex("by_strategyId_and_publicId", (q) =>
      q.eq("strategyId", strategyId).eq("publicId", publicId),
    )
    .unique();
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
    if (page === null || page.strategyId !== strategy._id || isTrashed(page)) {
      return null;
    }
    return { revision: page.revision, payload: pagePayload(page) };
  }
  if (op.entityType === "pageContent") {
    const page = await getPageByPublicIdOrNull(ctx, publicId);
    if (page === null || page.strategyId !== strategy._id || isTrashed(page)) {
      return null;
    }
    const content = await getPageContent(ctx, page._id);
    return {
      revision: content.revision,
      payload: { settings: content.settings ?? null },
    };
  }
  // Content on a page in the trash is not the server's current copy.
  if (op.entityType === "element") {
    const element = await getElementByPublicIdOrNull(ctx, publicId);
    if (
      element === null ||
      element.strategyId !== strategy._id ||
      !(await contentPageIsLive(ctx, element.pageId))
    ) {
      return null;
    }
    return { revision: element.revision, payload: element.payload };
  }
  const lineup = await getLineupByPublicIdOrNull(ctx, strategy._id, publicId);
  if (lineup === null || !(await contentPageIsLive(ctx, lineup.pageId))) {
    return null;
  }
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
    reason === "deleted" ||
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
  userId: Id<"users">,
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
      if (isTrashed(existing)) throw pageDeletedError();
      const content = await getPageContent(ctx, existing._id);
      const pages = await listLivePages(ctx, strategy._id);
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
    const pages = await listLivePages(ctx, strategy._id);
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
    // Already in the trash counts as deleted.
    if (
      existing === null ||
      existing.strategyId !== strategy._id ||
      isTrashed(existing)
    ) {
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
    const pages = await listLivePages(ctx, strategy._id);
    if (pages.length <= 1) {
      throw errorWithCode("INVALID_OP", "Cannot delete last page");
    }
    const now = Date.now();
    await trashPage(ctx, existing, pages, userId, now);
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
  if (isTrashed(existing)) throw pageDeletedError();
  if (op.kind === "reorder") {
    const pages = await listLivePages(ctx, strategy._id);
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
  if (isTrashed(page)) throw pageDeletedError();
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
  checkTrashedPageDeletes: boolean,
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
    const page = await requireTargetPage(ctx, strategy, op.pagePublicId);
    const payload = assertElementPayload(op.payload);
    if (existing !== null) {
      if (existing.strategyId !== strategy._id) {
        return rejected("element_strategy_mismatch");
      }
      await assertContentPageLive(ctx, existing.pageId);
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
    const offLivePage = await refuseDeleteOffLivePage(
      ctx,
      existing,
      checkTrashedPageDeletes,
    );
    if (offLivePage !== null) return offLivePage;
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
  await assertContentPageLive(ctx, existing.pageId);
  const deleted = refuseChangeToDeleted(existing);
  if (deleted !== null) return deleted;
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
      const page = await requireTargetPage(ctx, strategy, op.pagePublicId);
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
  checkTrashedPageDeletes: boolean,
): Promise<OperationResult> {
  const publicId = op.entityPublicId;
  if (publicId === undefined) {
    throw errorWithCode("MISSING_ENTITY_PUBLIC_ID", "Missing entityPublicId");
  }
  const existing = await getLineupByPublicIdOrNull(
    ctx,
    strategy._id,
    publicId,
  );

  if (op.kind === "add") {
    if (op.pagePublicId === undefined) {
      throw errorWithCode("MISSING_PAGE_PUBLIC_ID", "Missing pagePublicId");
    }
    const page = await requireTargetPage(ctx, strategy, op.pagePublicId);
    const payload = assertLineupPayload(op.payload, publicId);
    if (existing !== null) {
      await assertContentPageLive(ctx, existing.pageId);
      if (existing.deleted) {
        const mismatch = requireExpectedRevision(op, existing.revision);
        if (mismatch !== null) {
          return rejected(
            mismatch.reason,
            { revision: existing.revision, payload: existing.payload },
            existing.pageId,
          );
        }
        await assertLineupGroupAlone(ctx, page._id, existing._id, payload);
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
      // The row already holds exactly this lineup: a retry landed twice, or
      // two devices uploaded the same copied strategy. Order is not part of
      // a lineup's content (each client places new rows after the highest it
      // knows), so a different sortIndex alone is still the same add.
      const identical =
        existing.pageId === page._id && valuesEqual(existing.payload, payload);
      if (identical) return noop(existing.revision, existing.pageId);
      return rejected(
        "already_exists",
        { revision: existing.revision, payload: existing.payload },
        existing.pageId,
      );
    }
    await assertLineupGroupAlone(ctx, page._id, null, payload);
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
    const offLivePage = await refuseDeleteOffLivePage(
      ctx,
      existing,
      checkTrashedPageDeletes,
    );
    if (offLivePage !== null) return offLivePage;
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
  await assertContentPageLive(ctx, existing.pageId);
  const deleted = refuseChangeToDeleted(existing);
  if (deleted !== null) return deleted;
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
      // A lineup row never moves between pages: no client action does that,
      // and a patch naming another page means its key clashed with a row on
      // a different page (a rejected add turned into a patch by "Keep mine").
      // Moving it would take the lineup away from the page that shows it,
      // so refuse and let the conflict surface instead.
      if (page._id !== existing.pageId) {
        // The client matches this text (lineupPageMismatchMessage) to
        // explain the refusal.
        throw errorWithCode(
          "LINEUP_PAGE_MISMATCH",
          "This lineup belongs to another page and cannot be moved",
        );
      }
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
  if (patch.payload !== undefined) {
    await assertLineupGroupAlone(
      ctx,
      existing.pageId,
      existing._id,
      patch.payload as LineupPayload,
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

function isAgentRow(row: Doc<"elements"> | Doc<"lineups"> | null): boolean {
  return row !== null && "elementType" in row && row.elementType === "agent";
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
        ? await getLineupByPublicIdOrNull(ctx, strategy._id, publicId)
        : null;
  return row !== null && row.strategyId === strategy._id ? row : null;
}

/// Keeps asset rows in step with an accepted content op. An image the row
/// newly shows gets a placeholder if nothing has been uploaded for it yet, so
/// a slow upload reads as on its way rather than missing, and a duplicate
/// waits for it. An image a deleted element showed is added to
/// [placeholderCandidates]; applyBatch drops those placeholders after the
/// whole batch, if nothing shows the image by then.
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
  placeholderCandidates: Set<string>,
): Promise<void> {
  const row = await contentRowForOp(ctx, strategy, op);
  if (row === null) return;
  // Keep the row's image references in step with it (media cleanup reads
  // those, not the content).
  if ("elementType" in row) {
    await syncElementAssetReferences(ctx, row._id, row);
  } else {
    await syncLineupAssetReferences(ctx, row._id, row);
    await syncLineupAgents(ctx, row._id, row);
    await syncLineupItems(ctx, row._id, row);
  }
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
    // Only nominated here; removed once the whole batch has applied (see
    // applyBatch), since a later op in the batch may show the image again.
    for (const id of assetsBefore) {
      if (!assetsAfter.has(id)) placeholderCandidates.add(id);
    }
  }
}

export const applyBatch = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    clientId: v.string(),
    ops: v.array(strategyOpValidator),
    // Set by clients that can restore a deleted page (pages:restore): a
    // delete of content on a page in the trash is refused, to be sent again
    // once the page is back. Older clients get the no-op a deleted page's
    // purged content gave them (see refuseDeleteOffLivePage).
    checkTrashedPageDeletes: v.optional(v.boolean()),
    // Sent by clients on protocol 4, which stored lineups as origin,
    // landing and link rows. Ignored: accepting them lets such a client
    // reach the protocol gate (CLIENT_UPGRADE_REQUIRED) instead of failing
    // argument validation.
    checkLineupLinkEnds: v.optional(v.boolean()),
    checkLineupEndDeletes: v.optional(v.boolean()),
    // Set by clients that bind a batch to the account whose outbox holds
    // it: that account's identity subject. A batch can reach the server
    // under a different sign-in than the one that queued it (the transport
    // resends a pending mutation after a new sign-in), so one bound to
    // another account is refused whole (see assertCallerIsAccount). Older
    // clients send it unbound, checked against whoever is signed in.
    accountSubject: v.optional(v.string()),
  },
  returns: applyBatchResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    if (args.accountSubject !== undefined) {
      await assertCallerIsAccount(ctx, args.accountSubject);
    }
    let strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user } = await assertStrategyRole(ctx, strategy, "editor");
    const results: PublicOperationResult[] = [];
    let acceptedStrategyBatchBaseRevision: number | undefined;
    // Whether an accepted op may have changed which agents the strategy
    // uses: a page added, moved to or out of the trash, an agent element,
    // or a lineup.
    let agentsMayHaveChanged = false;
    // Images deleted elements showed, whose upload placeholders may go once
    // the whole batch has applied and nothing shows them any more.
    const placeholderCandidates = new Set<string>();

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
        // An accepted op replays at the revision it landed at, not the
        // row's latest: a successor rebased onto a teammate's later edit
        // would overwrite that edit unseen. An event that recorded no
        // revision replays with none, for the same reason; the client then
        // keeps its base revision and a later edit meets the usual check.
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
              : noop(existingEvent.appliedRevision);
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
            const applied = await applyPageOp(ctx, strategy, op, user._id);
            strategy = applied.strategy;
            result = applied.result;
          } else if (op.entityType === "pageContent") {
            result = await applyPageContentOp(ctx, strategy, op);
          } else if (op.entityType === "element") {
            result = await applyElementOp(
              ctx,
              strategy,
              op,
              args.checkTrashedPageDeletes === true,
            );
          } else {
            result = await applyLineupOp(
              ctx,
              strategy,
              op,
              args.checkTrashedPageDeletes === true,
            );
          }
          if (
            result.status === "ack" &&
            (op.entityType === "page" ||
              op.entityType === "lineup" ||
              (op.entityType === "element" &&
                (isAgentRow(rowBefore) ||
                  (op.payload as { kind?: unknown } | undefined)?.kind ===
                    "agent")))
          ) {
            agentsMayHaveChanged = true;
          }
          if (result.status === "ack") {
            await reconcileExpectedAssets(
              ctx,
              strategy,
              op,
              rowBefore,
              placeholderCandidates,
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

    // Checked against the batch's final state, once.
    await removeUploadPlaceholders(ctx, strategy._id, placeholderCandidates);

    if (agentsMayHaveChanged) {
      await refreshStrategyAgentSummary(ctx, strategy._id);
    }

    return { strategyPublicId: strategy.publicId, results };
  },
});
