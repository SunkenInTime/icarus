import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { readFileSync, writeFileSync } from "node:fs";
import { expect, test } from "vitest";
import schema from "../../convex/schema";
import { modules } from "../../convex/test.setup";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "../../convex/lib/cloudProtocol";
import { markAssetReferencesReady } from "../../convex/lib/assetReferences";
import { syncLineupItems } from "../../convex/lib/lineupItems";
import {
  answerProblems,
  canonical,
  outcomeName,
  outcomeOf,
  rowDifferences,
  unsafeNumbers,
} from "./compare.mjs";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

type Json = any;

function predictedRows(rows: Json): Json {
  return { ...rows, strategies: [rows.strategy], strategy: undefined };
}

async function seed(t: Json, init: Json): Promise<void> {
  await t.run(async (ctx: Json) => {
    await markAssetReferencesReady(ctx);
    const user = (await ctx.db.query("users").collect())[0]!;
    const now = 1;
    const folderIds: Record<string, Json> = {};
    for (const folder of init.folders) {
      folderIds[folder.publicId] = await ctx.db.insert("folders", {
        publicId: folder.publicId,
        ownerId: user._id,
        name: folder.name,
        ...(folder.parentFolderPublicId === undefined
          ? {}
          : { parentFolderId: folderIds[folder.parentFolderPublicId] }),
        ...Object.fromEntries(
          [
            "iconId",
            "iconCodePoint",
            "iconFontFamily",
            "iconFontPackage",
            "color",
            "customColorValue",
          ]
            .filter((key) => folder[key] !== undefined)
            .map((key) => [key, folder[key]]),
        ),
        createdAt: now,
        updatedAt: now,
      });
    }
    const s = init.strategy;
    const strategyId = await ctx.db.insert("strategies", {
      publicId: s.publicId,
      ownerId: user._id,
      ...(s.folderPublicId === undefined
        ? {}
        : { folderId: folderIds[s.folderPublicId] }),
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
}

async function dump(t: Json): Promise<Json> {
  return await t.run(async (ctx: Json) => {
    const strategies = await ctx.db.query("strategies").collect();
    const folders = await ctx.db.query("folders").collect();
    const folderById = new Map(folders.map((f: Json) => [f._id, f.publicId]));
    const strategyById = new Map(
      strategies.map((s: Json) => [s._id, s.publicId]),
    );
    const pages = await ctx.db.query("pages").collect();
    const pageById = new Map(pages.map((p: Json) => [p._id, p.publicId]));
    const contents = await ctx.db.query("pageContents").collect();
    const elements = await ctx.db.query("elements").collect();
    const lineups = await ctx.db.query("lineups").collect();
    return {
      strategies: strategies.map((s: Json) => ({
        publicId: s.publicId,
        folderPublicId: s.folderId === undefined ? undefined : folderById.get(s.folderId),
        name: s.name,
        mapData: s.mapData,
        themeProfileId: s.themeProfileId,
        themeOverridePalette: s.themeOverridePalette,
        revision: s.revision,
      })),
      folders: folders.map((f: Json) => ({
        publicId: f.publicId,
        name: f.name,
        parentFolderPublicId:
          f.parentFolderId === undefined ? undefined : folderById.get(f.parentFolderId),
        iconId: f.iconId,
        iconCodePoint: f.iconCodePoint,
        iconFontFamily: f.iconFontFamily,
        iconFontPackage: f.iconFontPackage,
        color: f.color,
        customColorValue: f.customColorValue,
      })),
      pages: pages.map((p: Json) => ({
        publicId: p.publicId,
        strategyPublicId: strategyById.get(p.strategyId),
        name: p.name,
        isAutoNamed: p.isAutoNamed,
        sortIndex: p.sortIndex,
        isAttack: p.isAttack,
        revision: p.revision,
        deleted: p.deletedAt !== undefined,
      })),
      settings: contents.map((c: Json) => ({
        pagePublicId: pageById.get(c.pageId),
        settings: c.settings,
        revision: c.revision,
      })),
      elements: elements.map((e: Json) => ({
        publicId: e.publicId,
        pagePublicId: pageById.get(e.pageId),
        payload: e.payload,
        sortIndex: e.sortIndex,
        revision: e.revision,
        deleted: e.deleted,
      })),
      lineupGroups: lineups.map((g: Json) => ({
        publicId: g.publicId,
        strategyPublicId: strategyById.get(g.strategyId),
        pagePublicId: pageById.get(g.pageId),
        payload: g.payload,
        sortIndex: g.sortIndex,
        revision: g.revision,
        deleted: g.deleted,
      })),
    };
  });
}

async function compare(
  scenario: Json,
  subject: string,
  outcomes: Record<string, number>,
): Promise<Json> {
  const entry: Json = {
    seed: scenario.seed,
    name: scenario.name,
    steps: scenario.steps,
    opsInFile: scenario.ops.length,
    compared: 0,
  };
  const unsafe = unsafeNumbers(scenario);
  if (unsafe.length > 0) {
    entry.difference = { step: 0, problem: "numbers JavaScript cannot hold", paths: unsafe.slice(0, 5) };
    return entry;
  }
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity({
    issuer: "https://parity.test",
    subject,
    tokenIdentifier: `parity|${subject}`,
    name: subject,
  });
  await asUser.mutation(ensureCurrentUser, protocol);
  await seed(t, scenario.initial);
  const servers: Json[] = [];
  for (let step = 0; step < scenario.ops.length; step++) {
    const op = scenario.ops[step];
    const predicted = scenario.predicted[step];
    let result: Json;
    try {
      result = await asUser.mutation(applyBatch, {
        ...protocol,
        strategyPublicId: scenario.initial.strategy.publicId,
        clientId: "parity",
        ops: [op],
        checkTrashedPageDeletes: true,
        acceptsPictureIds: true,
        elementFieldLevel: 4,
      });
    } catch (error) {
      entry.difference = {
        step,
        op,
        problem: "the server threw",
        error: error instanceof Error ? `${error.message}\n${error.stack}` : String(error),
      };
      return entry;
    }
    const answer = answerProblems(op, result);
    if (answer.length > 0) {
      entry.difference = { step, op, problem: answer.join("; "), result };
      return entry;
    }
    const server = outcomeOf(result.results[0]);
    servers.push(server);
    const dart = { ...predicted, rows: undefined };
    const name = outcomeName(op.type, server);
    outcomes[name] = (outcomes[name] ?? 0) + 1;
    const held = await dump(t);
    const unreadable = unsafeNumbers(held);
    if (unreadable.length > 0) {
      entry.difference = {
        step,
        op,
        problem: "the server holds numbers JavaScript cannot compare",
        paths: unreadable.slice(0, 5),
      };
      return entry;
    }
    const rows = rowDifferences(held, predictedRows(predicted.rows));
    if (canonical(server) !== canonical(dart) || rows.length > 0) {
      entry.difference = { step, op, server, dart, rows };
      return entry;
    }
    entry.compared += 1;
  }
  if (scenario.trashCase !== undefined) {
    const last = servers[servers.length - 1] ?? {};
    const refused = last.status === "failed" && last.code === "PAGE_DELETED";
    entry.trashCase = {
      ...scenario.trashCase,
      server: outcomeName(scenario.ops[scenario.ops.length - 1].type, last),
    };
    if (refused !== scenario.trashCase.needsTrashedPage) {
      entry.difference = {
        step: scenario.ops.length - 1,
        problem: refused
          ? "the server refused it as page deleted, and pagesRequiredLive names no trashed page"
          : "pagesRequiredLive names a trashed page, and the server did not refuse it as page deleted",
        trashCase: entry.trashCase,
      };
    }
  }
  if (scenario.expected !== undefined) {
    const unmet = storyProblems(scenario, servers, await dump(t));
    if (unmet.length > 0) {
      entry.difference = {
        step: scenario.ops.length - 1,
        problem: "the server did not do what the story expects",
        unmet,
      };
    }
  }
  return entry;
}

function storyProblems(scenario: Json, servers: Json[], held: Json): Json[] {
  const problems: Json[] = [];
  scenario.outcomes.forEach((wanted: Json, step: number) => {
    const server = servers[step] ?? {};
    const got = Object.fromEntries(Object.keys(wanted).map((key) => [key, server[key]]));
    if (canonical(got) !== canonical(wanted)) {
      problems.push({ step, story: wanted, server: got });
    }
  });
  const rows = [...held.elements, ...held.lineupGroups];
  for (const [id, fields] of Object.entries(scenario.expected)) {
    const row = rows.find((candidate: Json) => candidate.publicId === id);
    for (const [key, value] of Object.entries(fields as Record<string, Json>)) {
      const server = key === "@sortIndex" ? row?.sortIndex : row?.payload.data[key];
      if (canonical(server) !== canonical(value)) {
        problems.push({ key: `${id}.${key}`, story: value, server });
      }
    }
  }
  return problems;
}

test("applyOp matches convex/ops.ts", { timeout: 3_600_000 }, async () => {
  const scenarios: Json[] = JSON.parse(
    readFileSync(process.env.PARITY_IN!, "utf8"),
  );
  const report: Json[] = [];
  const outcomes: Record<string, number> = {};
  for (const scenario of scenarios) {
    report.push(await compare(scenario, `parity-${scenario.seed}`, outcomes));
  }
  writeFileSync(
    process.env.PARITY_OUT!,
    JSON.stringify({ scenarios: report, outcomes }, null, 1),
  );
  expect(report.filter((entry) => entry.difference !== undefined)).toEqual([]);
});

test.skipIf(process.env.PARITY_STORIES === undefined)(
  "the merge stories and merge seeds match convex/ops.ts and do what they say",
  { timeout: 3_600_000 },
  async () => {
    const scenarios: Json[] = JSON.parse(
      readFileSync(process.env.PARITY_STORIES!, "utf8"),
    );
    const report: Json[] = [];
    const outcomes: Record<string, number> = {};
    for (const [index, scenario] of scenarios.entries()) {
      report.push(await compare(scenario, `story-${index}`, outcomes));
    }
    writeFileSync(
      process.env.PARITY_STORIES_OUT!,
      JSON.stringify({ scenarios: report, outcomes }, null, 1),
    );
    expect(report.filter((entry) => entry.difference !== undefined)).toEqual([]);
  },
);
