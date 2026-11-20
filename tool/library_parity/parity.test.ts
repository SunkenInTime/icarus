import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { readFileSync, writeFileSync } from "node:fs";
import { expect, test } from "vitest";
import schema from "../../convex/schema";
import { modules } from "../../convex/test.setup";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "../../convex/lib/cloudProtocol";
import { markAssetReferencesReady } from "../../convex/lib/assetReferences";
import { syncLineupItems } from "../../convex/lib/lineupItems";
import { normalizeComparableValue } from "../../convex/lib/canonicalValues";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

type Json = any;

function canon(value: Json): string {
  const numbers = (v: Json): Json =>
    Array.isArray(v)
      ? v.map(numbers)
      : v !== null && typeof v === "object"
        ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, numbers(x)]))
        : v;
  return JSON.stringify(normalizeComparableValue(numbers(value)));
}

test("applyOp matches convex/ops.ts", { timeout: 1_800_000 }, async () => {
  const scenarios: Json[] = JSON.parse(
    readFileSync(process.env.PARITY_IN!, "utf8"),
  );
  const report: Json[] = [];
  const outcomes: Record<string, number> = {};
  for (const scenario of scenarios) {
    const t = convexTest(schema, modules);
    const subject = `parity-${scenario.seed}`;
    const asUser = t.withIdentity({
      issuer: "https://parity.test",
      subject,
      tokenIdentifier: `parity|${subject}`,
      name: subject,
    });
    await asUser.mutation(ensureCurrentUser, protocol);
    const init = scenario.initial;
    await t.run(async (ctx) => {
      await markAssetReferencesReady(ctx);
      const user = (await ctx.db.query("users").collect())[0]!;
      const now = 1;
      const s = init.strategy;
      const strategyId = await ctx.db.insert("strategies", {
        publicId: s.publicId,
        ownerId: user._id,
        name: s.name,
        mapData: s.mapData,
        revision: s.revision,
        createdAt: now,
        updatedAt: now,
      });
      const pageIds: Record<string, Json> = {};
      for (const p of init.pages) {
        pageIds[p.publicId] = await ctx.db.insert("pages", {
          publicId: p.publicId,
          strategyId,
          name: p.name,
          ...(p.isAutoNamed === undefined ? {} : { isAutoNamed: p.isAutoNamed }),
          sortIndex: p.sortIndex,
          isAttack: p.isAttack,
          revision: p.revision,
          createdAt: now,
          updatedAt: now,
        });
      }
      for (const c of init.settings) {
        await ctx.db.insert("pageContents", {
          pageId: pageIds[c.pagePublicId],
          ...(c.settings === undefined ? {} : { settings: c.settings }),
          revision: c.revision,
          createdAt: now,
          updatedAt: now,
        });
      }
      for (const e of init.elements) {
        await ctx.db.insert("elements", {
          publicId: e.publicId,
          strategyId,
          pageId: pageIds[e.pagePublicId],
          elementType: e.payload.kind,
          payloadKind: e.payload.kind,
          payloadVersion: e.payload.payloadVersion,
          payload: e.payload,
          sortIndex: e.sortIndex,
          revision: e.revision,
          deleted: e.deleted,
          createdAt: now,
          updatedAt: now,
        });
      }
      for (const g of init.lineupGroups) {
        const row = {
          publicId: g.publicId,
          strategyId,
          pageId: pageIds[g.pagePublicId],
          payloadKind: "lineups" as const,
          payloadVersion: g.payload.payloadVersion,
          payload: g.payload,
          sortIndex: g.sortIndex,
          revision: g.revision,
          deleted: g.deleted,
          createdAt: now,
          updatedAt: now,
        };
        const id = await ctx.db.insert("lineups", row);
        await syncLineupItems(ctx, id, row);
      }
    });

    const dump = async () =>
      await t.run(async (ctx) => {
        const strategy = (await ctx.db.query("strategies").collect())[0]!;
        const pages = await ctx.db.query("pages").collect();
        const byId = new Map(pages.map((p) => [p._id, p.publicId]));
        const contents = await ctx.db.query("pageContents").collect();
        const elements = await ctx.db.query("elements").collect();
        const lineups = await ctx.db.query("lineups").collect();
        return {
          strategy: {
            publicId: strategy.publicId,
            name: strategy.name,
            mapData: strategy.mapData,
            themeProfileId: strategy.themeProfileId,
            themeOverridePalette: strategy.themeOverridePalette,
            revision: strategy.revision,
          },
          pages: pages.map((p) => ({
            publicId: p.publicId,
            strategyPublicId: strategy.publicId,
            name: p.name,
            isAutoNamed: p.isAutoNamed,
            sortIndex: p.sortIndex,
            isAttack: p.isAttack,
            revision: p.revision,
            deleted: p.deletedAt !== undefined,
          })),
          settings: contents.map((c) => ({
            pagePublicId: byId.get(c.pageId),
            settings: c.settings,
            revision: c.revision,
          })),
          elements: elements.map((e) => ({
            publicId: e.publicId,
            pagePublicId: byId.get(e.pageId),
            payload: e.payload,
            sortIndex: e.sortIndex,
            revision: e.revision,
            deleted: e.deleted,
          })),
          lineupGroups: lineups.map((g) => ({
            publicId: g.publicId,
            strategyPublicId: strategy.publicId,
            pagePublicId: byId.get(g.pageId),
            payload: g.payload,
            sortIndex: g.sortIndex,
            revision: g.revision,
            deleted: g.deleted,
          })),
        };
      });

    const keyed = (rows: Json) => {
      const out: Record<string, string> = {};
      out["strategy"] = canon(rows.strategy);
      for (const kind of ["pages", "elements", "lineupGroups"]) {
        for (const r of rows[kind]) out[`${kind}:${r.publicId}`] = canon(r);
      }
      for (const r of rows.settings) out[`settings:${r.pagePublicId}`] = canon(r);
      return out;
    };

    let mismatches = 0;
    for (let i = 0; i < scenario.ops.length; i++) {
      const op = scenario.ops[i];
      const predicted = scenario.predicted[i];
      let actual: Json;
      try {
        const result = await asUser.mutation(applyBatch, {
          ...protocol,
          strategyPublicId: init.strategy.publicId,
          clientId: "parity",
          ops: [op],
          checkTrashedPageDeletes: true,
          acceptsPictureIds: true,
          elementFieldLevel: 4,
        });
        const r = result.results[0];
        actual =
          r.status === "rejected"
            ? { status: "rejected", reason: r.reason }
            : r.status === "failed"
              ? { status: "failed", code: r.code }
              : { status: r.status };
      } catch (error) {
        actual = { status: "threw", message: String(error).slice(0, 200) };
      }
      const outcome = [op.type, actual.status, actual.reason ?? actual.code]
        .filter((part) => part !== undefined)
        .join(" ");
      outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;
      const want = { ...predicted };
      delete want.rows;
      const rowsNow = keyed(await dump());
      const rowsWant = keyed(predicted.rows);
      const rowDiff = [...new Set([...Object.keys(rowsNow), ...Object.keys(rowsWant)])]
        .filter((k) => rowsNow[k] !== rowsWant[k])
        .map((k) => ({ key: k, server: rowsNow[k], dart: rowsWant[k] }));
      if (canon(actual) !== canon(want) || rowDiff.length > 0) {
        mismatches++;
        report.push({ seed: scenario.seed, step: i, op, server: actual, dart: want, rowDiff });
        break;
      }
    }
    if (mismatches === 0) report.push({ seed: scenario.seed, ok: scenario.ops.length });
  }
  writeFileSync(
    process.env.PARITY_OUT!,
    JSON.stringify({ scenarios: report, outcomes }, null, 1),
  );
  expect(report.filter((r) => r.ok === undefined)).toEqual([]);
});
