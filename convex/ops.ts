import { mutation, type MutationCtx } from "./_generated/server";
import { ConvexError, v } from "convex/values";
import type { Id } from "./_generated/dataModel";
import { assertStrategyRole } from "./lib/auth";
import {
  getElementByPublicId,
  getLineupByPublicId,
  getPageByPublicId,
  getStrategyByPublicId,
} from "./lib/entities";
import { strategyOpValidator } from "./lib/opTypes";
import { assertSupportedCloudProtocol } from "./lib/cloudProtocol";
import type { Doc } from "./_generated/dataModel";
import { errorWithCode, invalidPayloadError } from "./lib/errors";
import { purgeDeletedPageOrphansRef } from "./maintenance";

async function incrementSequence(ctx: any, strategy: any): Promise<any> {
  const nextSequence = strategy.sequence + 1;
  const now = Date.now();
  await ctx.db.patch(strategy._id, {
    sequence: nextSequence,
    updatedAt: now,
  });
  return {
    ...strategy,
    sequence: nextSequence,
    updatedAt: now,
  };
}

type ElementPayload = Doc<"elements">["payload"];
type LineupPayload = Doc<"lineups">["payload"];
type ReplayEntityTable = "elements" | "lineups";
type ReplayEntitySnapshot = {
  revision: number;
  payload: ElementPayload | LineupPayload;
};
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
  settings?: Doc<"pages">["settings"];
  isAttack?: boolean;
};

async function getReplayEntitySnapshot(
  ctx: MutationCtx,
  tableName: ReplayEntityTable,
  entityPublicId: string,
  strategyId: Id<"strategies">,
): Promise<ReplayEntitySnapshot | null> {
  const entity =
    tableName === "elements"
      ? await ctx.db
          .query("elements")
          .withIndex("by_publicId", (q) => q.eq("publicId", entityPublicId))
          .first()
      : await ctx.db
          .query("lineups")
          .withIndex("by_publicId", (q) => q.eq("publicId", entityPublicId))
          .first();

  if (entity === null || entity.strategyId !== strategyId) {
    return null;
  }
  return { revision: entity.revision, payload: entity.payload };
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

const pagePayloadKeys = new Set(["name", "settings", "isAttack"]);

function assertStrategyPatchPayload(payload: unknown): StrategyPatchPayload {
  if (payload === undefined) {
    return {};
  }
  if (!isRecord(payload)) {
    throw invalidPayloadError("Invalid strategy payload");
  }
  assertKnownPayloadKeys(payload, strategyPatchPayloadKeys, "strategy");
  return payload as StrategyPatchPayload;
}

function assertPagePayload(payload: unknown): PagePayload {
  if (payload === undefined) {
    return {};
  }
  if (!isRecord(payload)) {
    throw invalidPayloadError("Invalid page payload");
  }
  assertKnownPayloadKeys(payload, pagePayloadKeys, "page");
  return payload as PagePayload;
}

function assertElementPayload(payload: unknown): ElementPayload {
  if (!isRecord(payload)) {
    throw errorWithCode("MISSING_ELEMENT_PAYLOAD", "Missing element payload");
  }
  const kind = payload.kind;
  const payloadVersion = payload.payloadVersion;
  const data = payload.data;
  if (
    kind !== "agent" &&
    kind !== "ability" &&
    kind !== "drawing" &&
    kind !== "text" &&
    kind !== "image" &&
    kind !== "utility"
  ) {
    throw errorWithCode("INVALID_ELEMENT_PAYLOAD_KIND", "Invalid element payload kind");
  }
  if (typeof payloadVersion !== "number") {
    throw errorWithCode("INVALID_ELEMENT_PAYLOAD_VERSION", "Invalid element payload version");
  }
  if (!isRecord(data)) {
    throw errorWithCode("INVALID_ELEMENT_PAYLOAD_DATA", "Invalid element payload data");
  }
  if (typeof data.elementType === "string" && data.elementType !== kind) {
    throw errorWithCode("ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH", "elementType_payloadKind_mismatch");
  }
  return payload as ElementPayload;
}

function assertLineupPayload(payload: unknown): LineupPayload {
  if (!isRecord(payload)) {
    throw errorWithCode("MISSING_LINEUP_PAYLOAD", "Missing lineup payload");
  }
  if (payload.kind !== "lineupGroup") {
    throw errorWithCode("INVALID_LINEUP_PAYLOAD_KIND", "Invalid lineup payload kind");
  }
  if (typeof payload.payloadVersion !== "number") {
    throw errorWithCode("INVALID_LINEUP_PAYLOAD_VERSION", "Invalid lineup payload version");
  }
  if (!isRecord(payload.data)) {
    throw errorWithCode("INVALID_LINEUP_PAYLOAD_DATA", "Invalid lineup payload data");
  }
  return payload as LineupPayload;
}

function normalizeComparableValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(normalizeComparableValue);
  }
  if (isRecord(value)) {
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) {
      const child = value[key];
      if (child !== undefined) {
        result[key] = normalizeComparableValue(child);
      }
    }
    return result;
  }
  return value;
}

function valuesEqual(left: unknown, right: unknown): boolean {
  return (
    JSON.stringify(normalizeComparableValue(left)) ===
    JSON.stringify(normalizeComparableValue(right))
  );
}

function setIfChanged(
  patch: Record<string, unknown>,
  key: string,
  currentValue: unknown,
  nextValue: unknown,
): void {
  if (!valuesEqual(currentValue, nextValue)) {
    patch[key] = nextValue;
  }
}

function hasChanges(patch: Record<string, unknown>): boolean {
  return Object.keys(patch).length > 0;
}

async function patchStrategyAndIncrement(
  ctx: any,
  strategy: any,
  patch: Record<string, unknown>,
): Promise<any> {
  const nextSequence = strategy.sequence + 1;
  const now = Date.now();
  await ctx.db.patch(strategy._id, {
    ...patch,
    sequence: nextSequence,
    updatedAt: now,
  });
  return {
    ...strategy,
    ...patch,
    sequence: nextSequence,
    updatedAt: now,
  };
}

export const applyBatch = mutation({
  args: {
    strategyPublicId: v.string(),
    clientId: v.string(),
    clientProtocolVersion: v.number(),
    ops: v.array(strategyOpValidator),
  },
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);

    let strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const results: Array<Record<string, unknown>> = [];

    for (const op of args.ops) {
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
        let latestRevision: number | null = null;
        let latestPayload: ElementPayload | LineupPayload | null = null;

        if (op.entityType === "element" && op.entityPublicId !== undefined) {
          const snapshot = await getReplayEntitySnapshot(
            ctx,
            "elements",
            op.entityPublicId,
            strategy._id,
          );
          if (snapshot !== null) {
            latestRevision = snapshot.revision;
            latestPayload = snapshot.payload;
          }
        } else if (op.entityType === "lineup" && op.entityPublicId !== undefined) {
          const snapshot = await getReplayEntitySnapshot(
            ctx,
            "lineups",
            op.entityPublicId,
            strategy._id,
          );
          if (snapshot !== null) {
            latestRevision = snapshot.revision;
            latestPayload = snapshot.payload;
          }
        }

        results.push({
          opId: op.opId,
          status: existingEvent.status,
          reason: existingEvent.reason ?? null,
          appliedSequence: existingEvent.appliedSequence ?? null,
          expectedSequence: existingEvent.expectedSequence ?? null,
          appliedRevision: existingEvent.appliedRevision ?? null,
          expectedRevision: existingEvent.expectedRevision ?? null,
          latestSequence: strategy.sequence,
          latestRevision,
          latestPayload,
        });
        continue;
      }
      let status: "ack" | "reject" = "ack";
      let reason: string | undefined;
      let appliedRevision: number | undefined;
      let latestRevision: number | undefined;
      let latestPayload: ElementPayload | LineupPayload | undefined;
      let eventPageId: Id<"pages"> | undefined;
      let shouldRecordEvent = true;
      const markNoop = (currentRevision?: number) => {
        reason = "noop";
        shouldRecordEvent = false;
        if (currentRevision !== undefined) {
          appliedRevision = currentRevision;
        }
      };

      try {
        if (
          op.expectedSequence !== undefined &&
          op.expectedSequence !== strategy.sequence
        ) {
          status = "reject";
          reason = "sequence_mismatch";
        } else if (op.entityType === "strategy") {
          if (op.kind !== "patch") {
            throw errorWithCode("UNSUPPORTED_OP", "Unsupported strategy op");
          }

          const payload = assertStrategyPatchPayload(op.payload);
          const patch: Record<string, unknown> = {};
          if (typeof payload.name === "string") {
            setIfChanged(patch, "name", strategy.name, payload.name);
          }
          if (typeof payload.mapData === "string") {
            setIfChanged(patch, "mapData", strategy.mapData, payload.mapData);
          }
          if (typeof payload.themeProfileId === "string") {
            setIfChanged(
              patch,
              "themeProfileId",
              strategy.themeProfileId,
              payload.themeProfileId,
            );
          }
          if (payload.clearThemeProfileId === true) {
            setIfChanged(
              patch,
              "themeProfileId",
              strategy.themeProfileId,
              undefined,
            );
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

          if (hasChanges(patch)) {
            strategy = await patchStrategyAndIncrement(ctx, strategy, patch);
          } else {
            markNoop();
          }
        } else if (op.entityType === "page") {
          if (op.kind === "add") {
            const pagePublicId = op.pagePublicId;
            if (!pagePublicId) {
              throw errorWithCode("MISSING_PAGE_PUBLIC_ID", "Missing pagePublicId");
            }
            const payload = assertPagePayload(op.payload);
            const now = Date.now();
            const existingPage = await ctx.db
              .query("pages")
              .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
              .first();

            if (existingPage !== null) {
              if (existingPage.strategyId !== strategy._id) {
                throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
              }
              eventPageId = existingPage._id;

              const patch: Record<string, unknown> = {};
              setIfChanged(
                patch,
                "name",
                existingPage.name,
                typeof payload.name === "string"
                  ? payload.name
                  : existingPage.name,
              );
              setIfChanged(
                patch,
                "sortIndex",
                existingPage.sortIndex,
                op.sortIndex ?? existingPage.sortIndex,
              );
              setIfChanged(
                patch,
                "isAttack",
                existingPage.isAttack,
                typeof payload.isAttack === "boolean"
                  ? payload.isAttack
                  : existingPage.isAttack,
              );
              setIfChanged(
                patch,
                "settings",
                existingPage.settings,
                payload.settings !== undefined
                  ? payload.settings
                  : existingPage.settings,
              );

              if (hasChanges(patch)) {
                await ctx.db.patch(existingPage._id, {
                  ...patch,
                  revision: existingPage.revision + 1,
                  updatedAt: now,
                });
                appliedRevision = existingPage.revision + 1;
              } else {
                markNoop(existingPage.revision);
              }
            } else {
              const insertedPageId = await ctx.db.insert("pages", {
                publicId: pagePublicId,
                strategyId: strategy._id,
                name: typeof payload.name === "string" ? payload.name : "Page",
                sortIndex: op.sortIndex ?? 0,
                isAttack: payload.isAttack === false ? false : true,
                settings: payload.settings,
                revision: 1,
                createdAt: now,
                updatedAt: now,
              });
              eventPageId = insertedPageId;
              appliedRevision = 1;
            }

            if (shouldRecordEvent) {
              strategy = await incrementSequence(ctx, strategy);
            }
          } else {
            const pagePublicId = op.entityPublicId ?? op.pagePublicId;
            if (!pagePublicId) {
              throw errorWithCode("MISSING_PAGE_ID", "Missing page id");
            }
            const page = await getPageByPublicId(ctx, pagePublicId);
            if (page.strategyId !== strategy._id) {
              throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
            }
            eventPageId = page._id;

            latestRevision = page.revision;

            if (
              op.expectedRevision !== undefined &&
              op.expectedRevision !== page.revision
            ) {
              status = "reject";
              reason = "revision_mismatch";
            } else if (op.kind === "patch") {
              const payload = assertPagePayload(op.payload);
              const patch: Record<string, unknown> = {};
              if (typeof payload.name === "string") {
                setIfChanged(patch, "name", page.name, payload.name);
              }
              if (payload.settings !== undefined) {
                setIfChanged(patch, "settings", page.settings, payload.settings);
              }
              if (typeof payload.isAttack === "boolean") {
                setIfChanged(
                  patch,
                  "isAttack",
                  page.isAttack,
                  payload.isAttack,
                );
              }
              if (hasChanges(patch)) {
                await ctx.db.patch(page._id, {
                  ...patch,
                  revision: page.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = page.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              } else {
                markNoop(page.revision);
              }
            } else if (op.kind === "delete") {
              await ctx.db.delete(page._id);
              await ctx.scheduler.runAfter(0, purgeDeletedPageOrphansRef, {
                pageId: page._id,
              });
              appliedRevision = page.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "reorder") {
              const nextSortIndex = op.sortIndex ?? page.sortIndex;
              if (valuesEqual(page.sortIndex, nextSortIndex)) {
                markNoop(page.revision);
              } else {
                await ctx.db.patch(page._id, {
                  sortIndex: nextSortIndex,
                  revision: page.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = page.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              }
            } else {
              throw errorWithCode("UNSUPPORTED_OP", "Unsupported page op");
            }
          }
        } else if (op.entityType === "element") {
          if (op.kind === "add") {
            const elementPublicId = op.entityPublicId;
            const pagePublicId = op.pagePublicId;
            if (!elementPublicId || !pagePublicId || !op.payload) {
              throw errorWithCode(
                "MISSING_ADD_ELEMENT_ARGS",
                "Missing add element args",
              );
            }
            const page = await getPageByPublicId(ctx, pagePublicId);
            if (page.strategyId !== strategy._id) {
              throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
            }
            eventPageId = page._id;
            const payload = assertElementPayload(op.payload);
            const elementType = payload.kind;
            const now = Date.now();
            const existingElement = await ctx.db
              .query("elements")
              .withIndex("by_publicId", (q) => q.eq("publicId", elementPublicId))
              .first();

            if (existingElement !== null) {
              if (existingElement.strategyId !== strategy._id) {
                throw errorWithCode(
                  "ELEMENT_STRATEGY_MISMATCH",
                  "Element strategy mismatch",
                );
              }
              const patch: Record<string, unknown> = {};
              setIfChanged(patch, "pageId", existingElement.pageId, page._id);
              setIfChanged(
                patch,
                "elementType",
                existingElement.elementType,
                elementType,
              );
              setIfChanged(
                patch,
                "payloadKind",
                existingElement.payloadKind,
                payload.kind,
              );
              setIfChanged(
                patch,
                "payloadVersion",
                existingElement.payloadVersion,
                payload.payloadVersion,
              );
              setIfChanged(patch, "payload", existingElement.payload, payload);
              setIfChanged(
                patch,
                "sortIndex",
                existingElement.sortIndex,
                op.sortIndex ?? existingElement.sortIndex,
              );
              setIfChanged(patch, "deleted", existingElement.deleted, false);

              if (hasChanges(patch)) {
                await ctx.db.patch(existingElement._id, {
                  ...patch,
                  revision: existingElement.revision + 1,
                  updatedAt: now,
                });
                appliedRevision = existingElement.revision + 1;
              } else {
                markNoop(existingElement.revision);
              }
            } else {
              await ctx.db.insert("elements", {
                publicId: elementPublicId,
                strategyId: strategy._id,
                pageId: page._id,
                elementType,
                payloadKind: payload.kind,
                payloadVersion: payload.payloadVersion,
                payload,
                sortIndex: op.sortIndex ?? 0,
                revision: 1,
                deleted: false,
                createdAt: now,
                updatedAt: now,
              });
              appliedRevision = 1;
            }
            if (shouldRecordEvent) {
              strategy = await incrementSequence(ctx, strategy);
            }
          } else {
            if (!op.entityPublicId) {
              throw errorWithCode("MISSING_ENTITY_PUBLIC_ID", "Missing entityPublicId");
            }
            const element = await getElementByPublicId(ctx, op.entityPublicId);
            if (element.strategyId !== strategy._id) {
              throw errorWithCode(
                "ELEMENT_STRATEGY_MISMATCH",
                "Element strategy mismatch",
              );
            }
            eventPageId = element.pageId;

            latestRevision = element.revision;
            latestPayload = element.payload;

            if (
              op.expectedRevision !== undefined &&
              op.expectedRevision !== element.revision
            ) {
              status = "reject";
              reason = "revision_mismatch";
            } else if (op.kind === "delete") {
              if (element.deleted) {
                markNoop(element.revision);
              } else {
                await ctx.db.patch(element._id, {
                  deleted: true,
                  revision: element.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = element.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              }
            } else if (op.kind === "patch" || op.kind === "move") {
              const patch: Record<string, unknown> = {};
              if (op.payload !== undefined) {
                const payload = assertElementPayload(op.payload);
                if (payload.kind !== element.elementType) {
                  throw errorWithCode(
                    "ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH",
                    "elementType_payloadKind_mismatch",
                  );
                }
                setIfChanged(patch, "payload", element.payload, payload);
                setIfChanged(
                  patch,
                  "payloadKind",
                  element.payloadKind,
                  payload.kind,
                );
                setIfChanged(
                  patch,
                  "payloadVersion",
                  element.payloadVersion,
                  payload.payloadVersion,
                );
              }
              if (op.sortIndex !== undefined) {
                setIfChanged(
                  patch,
                  "sortIndex",
                  element.sortIndex,
                  op.sortIndex,
                );
              }
              if (op.pagePublicId !== undefined) {
                const page = await getPageByPublicId(ctx, op.pagePublicId);
                if (page.strategyId !== strategy._id) {
                  throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
                }
                setIfChanged(patch, "pageId", element.pageId, page._id);
                eventPageId = page._id;
              }

              if (hasChanges(patch)) {
                await ctx.db.patch(element._id, {
                  ...patch,
                  revision: element.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = element.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              } else {
                markNoop(element.revision);
              }
            } else if (op.kind === "reorder") {
              const nextSortIndex = op.sortIndex ?? element.sortIndex;
              if (valuesEqual(element.sortIndex, nextSortIndex)) {
                markNoop(element.revision);
              } else {
                await ctx.db.patch(element._id, {
                  sortIndex: nextSortIndex,
                  revision: element.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = element.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              }
            } else {
              throw errorWithCode("UNSUPPORTED_OP", "Unsupported element op");
            }
          }
        } else if (op.entityType === "lineup") {
          if (op.kind === "add") {
            const lineupPublicId = op.entityPublicId;
            const pagePublicId = op.pagePublicId;
            if (!lineupPublicId || !pagePublicId || !op.payload) {
              throw errorWithCode("MISSING_ADD_LINEUP_ARGS", "Missing add lineup args");
            }
            const page = await getPageByPublicId(ctx, pagePublicId);
            if (page.strategyId !== strategy._id) {
              throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
            }
            eventPageId = page._id;
            const payload = assertLineupPayload(op.payload);
            const now = Date.now();
            const existingLineup = await ctx.db
              .query("lineups")
              .withIndex("by_publicId", (q) => q.eq("publicId", lineupPublicId))
              .first();

            if (existingLineup !== null) {
              if (existingLineup.strategyId !== strategy._id) {
                throw errorWithCode(
                  "LINEUP_STRATEGY_MISMATCH",
                  "Lineup strategy mismatch",
                );
              }
              const patch: Record<string, unknown> = {};
              setIfChanged(patch, "pageId", existingLineup.pageId, page._id);
              setIfChanged(
                patch,
                "payloadKind",
                existingLineup.payloadKind,
                payload.kind,
              );
              setIfChanged(
                patch,
                "payloadVersion",
                existingLineup.payloadVersion,
                payload.payloadVersion,
              );
              setIfChanged(patch, "payload", existingLineup.payload, payload);
              setIfChanged(
                patch,
                "sortIndex",
                existingLineup.sortIndex,
                op.sortIndex ?? existingLineup.sortIndex,
              );
              setIfChanged(patch, "deleted", existingLineup.deleted, false);

              if (hasChanges(patch)) {
                await ctx.db.patch(existingLineup._id, {
                  ...patch,
                  revision: existingLineup.revision + 1,
                  updatedAt: now,
                });
                appliedRevision = existingLineup.revision + 1;
              } else {
                markNoop(existingLineup.revision);
              }
            } else {
              await ctx.db.insert("lineups", {
                publicId: lineupPublicId,
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
              appliedRevision = 1;
            }
            if (shouldRecordEvent) {
              strategy = await incrementSequence(ctx, strategy);
            }
          } else {
            if (!op.entityPublicId) {
              throw errorWithCode("MISSING_ENTITY_PUBLIC_ID", "Missing entityPublicId");
            }
            const lineup = await getLineupByPublicId(ctx, op.entityPublicId);
            if (lineup.strategyId !== strategy._id) {
              throw errorWithCode("LINEUP_STRATEGY_MISMATCH", "Lineup strategy mismatch");
            }
            eventPageId = lineup.pageId;

            latestRevision = lineup.revision;
            latestPayload = lineup.payload;

            if (
              op.expectedRevision !== undefined &&
              op.expectedRevision !== lineup.revision
            ) {
              status = "reject";
              reason = "revision_mismatch";
            } else if (op.kind === "delete") {
              if (lineup.deleted) {
                markNoop(lineup.revision);
              } else {
                await ctx.db.patch(lineup._id, {
                  deleted: true,
                  revision: lineup.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = lineup.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              }
            } else if (op.kind === "patch" || op.kind === "move") {
              const patch: Record<string, unknown> = {};
              if (op.payload !== undefined) {
                const payload = assertLineupPayload(op.payload);
                setIfChanged(patch, "payload", lineup.payload, payload);
                setIfChanged(
                  patch,
                  "payloadKind",
                  lineup.payloadKind,
                  payload.kind,
                );
                setIfChanged(
                  patch,
                  "payloadVersion",
                  lineup.payloadVersion,
                  payload.payloadVersion,
                );
              }
              if (op.sortIndex !== undefined) {
                setIfChanged(
                  patch,
                  "sortIndex",
                  lineup.sortIndex,
                  op.sortIndex,
                );
              }
              if (op.pagePublicId !== undefined) {
                const page = await getPageByPublicId(ctx, op.pagePublicId);
                if (page.strategyId !== strategy._id) {
                  throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
                }
                setIfChanged(patch, "pageId", lineup.pageId, page._id);
                eventPageId = page._id;
              }
              if (hasChanges(patch)) {
                await ctx.db.patch(lineup._id, {
                  ...patch,
                  revision: lineup.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = lineup.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              } else {
                markNoop(lineup.revision);
              }
            } else if (op.kind === "reorder") {
              const nextSortIndex = op.sortIndex ?? lineup.sortIndex;
              if (valuesEqual(lineup.sortIndex, nextSortIndex)) {
                markNoop(lineup.revision);
              } else {
                await ctx.db.patch(lineup._id, {
                  sortIndex: nextSortIndex,
                  revision: lineup.revision + 1,
                  updatedAt: Date.now(),
                });
                appliedRevision = lineup.revision + 1;
                strategy = await incrementSequence(ctx, strategy);
              }
            } else {
              throw errorWithCode("UNSUPPORTED_OP", "Unsupported lineup op");
            }
          }
        } else {
          throw errorWithCode("UNSUPPORTED_OP", "Unsupported entityType");
        }
      } catch (error) {
        if (error instanceof ConvexError) {
          status = "reject";
          const code =
            typeof error.data?.code === "string"
              ? error.data.code
              : "INTERNAL_ERROR";
          reason = code.toLowerCase();
          shouldRecordEvent = true;
        } else {
          throw error;
        }
      }

      if (shouldRecordEvent) {
        await ctx.db.insert("operationEvents", {
          strategyId: strategy._id,
          pageId: eventPageId,
          clientId: args.clientId,
          opId: op.opId,
          opType: `${op.entityType}.${op.kind}`,
          status,
          reason,
          expectedSequence: op.expectedSequence,
          appliedSequence: status === "ack" ? strategy.sequence : undefined,
          expectedRevision: op.expectedRevision,
          appliedRevision,
          createdAt: Date.now(),
        });
      }

      results.push({
        opId: op.opId,
        status,
        reason: reason ?? null,
        appliedSequence: status === "ack" ? strategy.sequence : null,
        expectedSequence: op.expectedSequence ?? null,
        appliedRevision: appliedRevision ?? null,
        expectedRevision: op.expectedRevision ?? null,
        latestSequence: strategy.sequence,
        latestRevision: latestRevision ?? null,
        latestPayload: latestPayload ?? null,
      });
    }

    return {
      strategyPublicId: strategy.publicId,
      sequence: strategy.sequence,
      results,
    };
  },
});
