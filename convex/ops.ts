import { mutation } from "./_generated/server";
import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";
import { deleteImageAssetsForPage } from "./images";
import { assertStrategyRole } from "./lib/auth";
import {
  getElementByPublicId,
  getLineupByPublicId,
  getPageByPublicId,
  getStrategyByPublicId,
} from "./lib/entities";
import { strategyOpValidator } from "./lib/opTypes";

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

function parsePayload(payload: string | undefined): Record<string, unknown> {
  if (payload === undefined || payload.length === 0) {
    return {};
  }
  try {
    const parsed = JSON.parse(payload);
    if (typeof parsed === "object" && parsed !== null) {
      return parsed as Record<string, unknown>;
    }
  } catch (_) {
    // ignore, validated at call sites
  }
  return {};
}

export const applyBatch = mutation({
  args: {
    strategyPublicId: v.string(),
    clientId: v.string(),
    ops: v.array(strategyOpValidator),
  },
  handler: async (ctx, args) => {
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
        results.push({
          opId: op.opId,
          status: existingEvent.status,
          reason: existingEvent.reason ?? null,
          appliedSequence: existingEvent.appliedSequence ?? null,
          expectedSequence: existingEvent.expectedSequence ?? null,
          appliedRevision: existingEvent.appliedRevision ?? null,
          expectedRevision: existingEvent.expectedRevision ?? null,
          latestSequence: strategy.sequence,
          latestRevision: null,
          latestPayload: null,
        });
        continue;
      }
      let status: "ack" | "reject" = "ack";
      let reason: string | undefined;
      let appliedRevision: number | undefined;
      let latestRevision: number | undefined;
      let latestPayload: string | undefined;
      let eventPageId: Id<"pages"> | undefined;

      try {
        if (
          op.expectedSequence !== undefined &&
          op.expectedSequence !== strategy.sequence
        ) {
          status = "reject";
          reason = "sequence_mismatch";
        } else if (op.entityType === "strategy") {
          if (op.kind !== "patch") {
            throw new Error("Unsupported strategy op");
          }

          const payload = parsePayload(op.payload);
          const patch: Record<string, unknown> = {
            updatedAt: Date.now(),
          };
          if (typeof payload.name === "string") {
            patch.name = payload.name;
          }
          if (typeof payload.mapData === "string") {
            patch.mapData = payload.mapData;
          }
          if (typeof payload.themeProfileId === "string") {
            patch.themeProfileId = payload.themeProfileId;
          }
          if (payload.clearThemeProfileId === true) {
            patch.themeProfileId = undefined;
          }
          if (typeof payload.themeOverridePalette === "string") {
            patch.themeOverridePalette = payload.themeOverridePalette;
          }
          if (payload.clearThemeOverridePalette === true) {
            patch.themeOverridePalette = undefined;
          }

          await ctx.db.patch(strategy._id, patch);
          strategy = await incrementSequence(ctx, strategy);
        } else if (op.entityType === "page") {
          if (op.kind === "add") {
            const pagePublicId = op.pagePublicId;
            if (!pagePublicId) {
              throw new Error("Missing pagePublicId");
            }
            const payload = parsePayload(op.payload);
            const now = Date.now();
            const existingPage = await ctx.db
              .query("pages")
              .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
              .first();

            if (existingPage !== null) {
              if (existingPage.strategyId !== strategy._id) {
                throw new Error("Page strategy mismatch");
              }
              eventPageId = existingPage._id;

              await ctx.db.patch(existingPage._id, {
                name:
                  typeof payload.name === "string"
                    ? payload.name
                    : existingPage.name,
                sortIndex: op.sortIndex ?? existingPage.sortIndex,
                isAttack:
                  typeof payload.isAttack === "boolean"
                    ? payload.isAttack
                    : existingPage.isAttack,
                settings:
                  typeof payload.settings === "string"
                    ? payload.settings
                    : existingPage.settings,
                revision: existingPage.revision + 1,
                updatedAt: now,
              });
              appliedRevision = existingPage.revision + 1;
            } else {
              const insertedPageId = await ctx.db.insert("pages", {
                publicId: pagePublicId,
                strategyId: strategy._id,
                name: typeof payload.name === "string" ? payload.name : "Page",
                sortIndex: op.sortIndex ?? 0,
                isAttack: payload.isAttack === false ? false : true,
                settings:
                  typeof payload.settings === "string"
                    ? payload.settings
                    : undefined,
                revision: 1,
                createdAt: now,
                updatedAt: now,
              });
              eventPageId = insertedPageId;
              appliedRevision = 1;
            }

            strategy = await incrementSequence(ctx, strategy);
          } else {
            const pagePublicId = op.entityPublicId ?? op.pagePublicId;
            if (!pagePublicId) {
              throw new Error("Missing page id");
            }
            const page = await getPageByPublicId(ctx, pagePublicId);
            if (page.strategyId !== strategy._id) {
              throw new Error("Page strategy mismatch");
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
              const payload = parsePayload(op.payload);
              const patch: Record<string, unknown> = {
                revision: page.revision + 1,
                updatedAt: Date.now(),
              };
              if (typeof payload.name === "string") patch.name = payload.name;
              if (typeof payload.settings === "string") {
                patch.settings = payload.settings;
              }
              if (typeof payload.isAttack === "boolean") {
                patch.isAttack = payload.isAttack;
              }
              await ctx.db.patch(page._id, patch);
              appliedRevision = page.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "delete") {
              const elements = await ctx.db
                .query("elements")
                .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
                .collect();
              for (const element of elements) {
                await ctx.db.delete(element._id);
              }

              const lineups = await ctx.db
                .query("lineups")
                .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
                .collect();
              for (const lineup of lineups) {
                await ctx.db.delete(lineup._id);
              }

              await deleteImageAssetsForPage(ctx, page._id);
              await ctx.db.delete(page._id);
              appliedRevision = page.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "reorder") {
              await ctx.db.patch(page._id, {
                sortIndex: op.sortIndex ?? page.sortIndex,
                revision: page.revision + 1,
                updatedAt: Date.now(),
              });
              appliedRevision = page.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else {
              throw new Error("Unsupported page op");
            }
          }
        } else if (op.entityType === "element") {
          if (op.kind === "add") {
            const elementPublicId = op.entityPublicId;
            const pagePublicId = op.pagePublicId;
            if (!elementPublicId || !pagePublicId || !op.payload) {
              throw new Error("Missing add element args");
            }
            const page = await getPageByPublicId(ctx, pagePublicId);
            if (page.strategyId !== strategy._id) {
              throw new Error("Page strategy mismatch");
            }
            eventPageId = page._id;
            const payload = parsePayload(op.payload);
            const elementType =
              typeof payload.elementType === "string"
                ? payload.elementType
                : "generic";
            const now = Date.now();
            const existingElement = await ctx.db
              .query("elements")
              .withIndex("by_publicId", (q) => q.eq("publicId", elementPublicId))
              .first();

            if (existingElement !== null) {
              if (existingElement.strategyId !== strategy._id) {
                throw new Error("Element strategy mismatch");
              }
              await ctx.db.patch(existingElement._id, {
                pageId: page._id,
                elementType,
                payload: op.payload,
                sortIndex: op.sortIndex ?? existingElement.sortIndex,
                deleted: false,
                revision: existingElement.revision + 1,
                updatedAt: now,
              });
              appliedRevision = existingElement.revision + 1;
            } else {
              await ctx.db.insert("elements", {
                publicId: elementPublicId,
                strategyId: strategy._id,
                pageId: page._id,
                elementType,
                payload: op.payload,
                sortIndex: op.sortIndex ?? 0,
                revision: 1,
                deleted: false,
                createdAt: now,
                updatedAt: now,
              });
              appliedRevision = 1;
            }
            strategy = await incrementSequence(ctx, strategy);
          } else {
            if (!op.entityPublicId) {
              throw new Error("Missing entityPublicId");
            }
            const element = await getElementByPublicId(ctx, op.entityPublicId);
            if (element.strategyId !== strategy._id) {
              throw new Error("Element strategy mismatch");
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
              await ctx.db.patch(element._id, {
                deleted: true,
                revision: element.revision + 1,
                updatedAt: Date.now(),
              });
              appliedRevision = element.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "patch" || op.kind === "move") {
              const patch: Record<string, unknown> = {
                revision: element.revision + 1,
                updatedAt: Date.now(),
              };
              if (op.payload !== undefined) {
                patch.payload = op.payload;
              }
              if (op.sortIndex !== undefined) {
                patch.sortIndex = op.sortIndex;
              }
              if (op.pagePublicId !== undefined) {
                const page = await getPageByPublicId(ctx, op.pagePublicId);
                if (page.strategyId !== strategy._id) {
                  throw new Error("Page strategy mismatch");
                }
                patch.pageId = page._id;
                eventPageId = page._id;
              }

              await ctx.db.patch(element._id, patch);
              appliedRevision = element.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "reorder") {
              await ctx.db.patch(element._id, {
                sortIndex: op.sortIndex ?? element.sortIndex,
                revision: element.revision + 1,
                updatedAt: Date.now(),
              });
              appliedRevision = element.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else {
              throw new Error("Unsupported element op");
            }
          }
        } else if (op.entityType === "lineup") {
          if (op.kind === "add") {
            const lineupPublicId = op.entityPublicId;
            const pagePublicId = op.pagePublicId;
            if (!lineupPublicId || !pagePublicId || !op.payload) {
              throw new Error("Missing add lineup args");
            }
            const page = await getPageByPublicId(ctx, pagePublicId);
            if (page.strategyId !== strategy._id) {
              throw new Error("Page strategy mismatch");
            }
            eventPageId = page._id;
            const now = Date.now();
            const existingLineup = await ctx.db
              .query("lineups")
              .withIndex("by_publicId", (q) => q.eq("publicId", lineupPublicId))
              .first();

            if (existingLineup !== null) {
              if (existingLineup.strategyId !== strategy._id) {
                throw new Error("Lineup strategy mismatch");
              }
              await ctx.db.patch(existingLineup._id, {
                pageId: page._id,
                payload: op.payload,
                sortIndex: op.sortIndex ?? existingLineup.sortIndex,
                deleted: false,
                revision: existingLineup.revision + 1,
                updatedAt: now,
              });
              appliedRevision = existingLineup.revision + 1;
            } else {
              await ctx.db.insert("lineups", {
                publicId: lineupPublicId,
                strategyId: strategy._id,
                pageId: page._id,
                payload: op.payload,
                sortIndex: op.sortIndex ?? 0,
                revision: 1,
                deleted: false,
                createdAt: now,
                updatedAt: now,
              });
              appliedRevision = 1;
            }
            strategy = await incrementSequence(ctx, strategy);
          } else {
            if (!op.entityPublicId) {
              throw new Error("Missing entityPublicId");
            }
            const lineup = await getLineupByPublicId(ctx, op.entityPublicId);
            if (lineup.strategyId !== strategy._id) {
              throw new Error("Lineup strategy mismatch");
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
              await ctx.db.patch(lineup._id, {
                deleted: true,
                revision: lineup.revision + 1,
                updatedAt: Date.now(),
              });
              appliedRevision = lineup.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "patch" || op.kind === "move") {
              const patch: Record<string, unknown> = {
                revision: lineup.revision + 1,
                updatedAt: Date.now(),
              };
              if (op.payload !== undefined) {
                patch.payload = op.payload;
              }
              if (op.sortIndex !== undefined) {
                patch.sortIndex = op.sortIndex;
              }
              if (op.pagePublicId !== undefined) {
                const page = await getPageByPublicId(ctx, op.pagePublicId);
                if (page.strategyId !== strategy._id) {
                  throw new Error("Page strategy mismatch");
                }
                patch.pageId = page._id;
                eventPageId = page._id;
              }
              await ctx.db.patch(lineup._id, patch);
              appliedRevision = lineup.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else if (op.kind === "reorder") {
              await ctx.db.patch(lineup._id, {
                sortIndex: op.sortIndex ?? lineup.sortIndex,
                revision: lineup.revision + 1,
                updatedAt: Date.now(),
              });
              appliedRevision = lineup.revision + 1;
              strategy = await incrementSequence(ctx, strategy);
            } else {
              throw new Error("Unsupported lineup op");
            }
          }
        } else {
          throw new Error("Unsupported entityType");
        }
      } catch (error) {
        status = "reject";
        reason = error instanceof Error ? error.message : "unknown_error";
      }

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

