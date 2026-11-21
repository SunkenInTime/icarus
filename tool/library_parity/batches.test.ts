import { convexTest } from "convex-test";
import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import schema from "../../convex/schema";
import { modules } from "../../convex/test.setup";
import {
  syncElementAssetReferences,
  syncLineupAssetReferences,
} from "../../convex/lib/assetReferences";
import { syncLineupItems } from "../../convex/lib/lineupItems";
import {
  refreshStrategyAgentSummary,
  syncLineupAgents,
} from "../../convex/lib/strategyAgentSummary";
import { canonical, outcomeOf, rowDifferences, unsafeNumbers } from "./compare.mjs";
import {
  applyBatch,
  dump,
  ensureCurrentUser,
  predictedRows,
  protocol,
  seed,
  type Json,
} from "./convexWorld";

const replaysMustReach = {
  applied: 40,
  noop: 5,
  rejected: 20,
  failed: 10,
};

const checksStrategyRevision = new Set([
  "strategy.patch",
  "page.add",
  "page.delete",
  "page.reorder",
]);

function nextBatch(ops: Json[], from: number, size: number): Json[] {
  if (checksStrategyRevision.has(ops[from].type)) return [ops[from]];
  const batch = [ops[from]];
  while (
    batch.length < size &&
    from + batch.length < ops.length &&
    !checksStrategyRevision.has(ops[from + batch.length].type)
  ) {
    batch.push(ops[from + batch.length]);
  }
  return batch;
}

function seededRandom(seed: number): () => number {
  let state = (seed + 0x9e3779b9) >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let x = Math.imul(state ^ (state >>> 15), 1 | state);
    x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

function replayAnswer(first: Json, includeWasApplied: boolean): Json {
  switch (first.status) {
    case "applied":
      return {
        status: "noop",
        currentRevision: first.appliedRevision,
        ...(includeWasApplied ? { wasApplied: true } : {}),
      };
    case "noop":
      return { status: "noop", currentRevision: first.currentRevision };
    case "rejected":
      return { status: "rejected", reason: first.reason };
    case "failed":
      return { status: "failed", code: first.code, message: first.message };
  }
  throw new Error(`unknown answer ${first.status}`);
}

function replayedAs(answer: Json): Json {
  switch (answer.status) {
    case "noop":
      return {
        status: "noop",
        currentRevision: answer.currentRevision,
        ...(answer.wasApplied === undefined ? {} : { wasApplied: answer.wasApplied }),
      };
    case "rejected":
      return { status: "rejected", reason: answer.reason };
    case "failed":
      return { status: "failed", code: answer.code, message: answer.message };
  }
  return { status: answer.status };
}

async function derivedRows(t: Json): Promise<string> {
  return await t.run(async (ctx: Json) =>
    canonical({
      assetReferences: await ctx.db.query("assetReferences").collect(),
      lineupAgents: await ctx.db.query("lineupAgents").collect(),
      lineupItems: await ctx.db.query("lineupItems").collect(),
      agentSummaries: (await ctx.db.query("strategyAgentSummaries").collect()).map(
        ({ updatedAt: _, ...row }: Json) => row,
      ),
    }),
  );
}

async function rebuildDerivedRows(t: Json): Promise<void> {
  await t.run(async (ctx: Json) => {
    for (const element of await ctx.db.query("elements").collect()) {
      await syncElementAssetReferences(ctx, element._id, element);
    }
    for (const lineup of await ctx.db.query("lineups").collect()) {
      await syncLineupAssetReferences(ctx, lineup._id, lineup);
      await syncLineupAgents(ctx, lineup._id, lineup);
      await syncLineupItems(ctx, lineup._id, lineup);
    }
    for (const strategy of await ctx.db.query("strategies").collect()) {
      await refreshStrategyAgentSummary(ctx, strategy._id);
    }
  });
}

test(
  "ops sent in batches and sent again answer as the model and their first answers say",
  { timeout: 3_600_000 },
  async () => {
    const scenarios: Json[] = JSON.parse(
      readFileSync(process.env.PARITY_IN!, "utf8"),
    );
    const problems: string[] = [];
    const replays: Record<string, number> = {};
    for (const scenario of scenarios) {
      if (unsafeNumbers(scenario).length > 0) continue;
      const random = seededRandom(scenario.seed);
      const t = convexTest(schema, modules);
      const subject = `batches-${scenario.seed}`;
      const asUser = t.withIdentity({
        issuer: "https://parity.test",
        subject,
        tokenIdentifier: `parity|${subject}`,
        name: subject,
      });
      await asUser.mutation(ensureCurrentUser, protocol);
      await seed(t, scenario.initial);
      await rebuildDerivedRows(t);
      const send = (ops: Json[], includeWasApplied: boolean) =>
        asUser.mutation(applyBatch, {
          ...protocol,
          strategyPublicId: scenario.initial.strategy.publicId,
          clientId: "batches",
          ops,
          checkTrashedPageDeletes: true,
          acceptsPictureIds: true,
          elementFieldLevel: 4,
          includeWasApplied,
        });
      const sent: { ops: Json[]; results: Json[] }[] = [];
      let step = 0;
      while (step < scenario.ops.length && problems.length === 0) {
        const ops = nextBatch(scenario.ops, step, 1 + Math.floor(random() * 3));
        const at = `seed ${scenario.seed}, steps ${step}-${step + ops.length - 1}`;
        const answer = await send(ops, false);
        ops.forEach((op: Json, index: number) => {
          const server = outcomeOf(answer.results[index]);
          const model = { ...scenario.predicted[step + index], rows: undefined };
          if (answer.results[index].opId !== op.opId || canonical(server) !== canonical(model)) {
            problems.push(`${at}: ${op.type} answered ${canonical(server)}, the model ${canonical(model)}`);
          }
        });
        step += ops.length;
        const rows = rowDifferences(
          await dump(t),
          predictedRows(scenario.predicted[step - 1].rows),
        );
        if (rows.length > 0) problems.push(`${at}: rows differ from the model: ${canonical(rows)}`);
        sent.push({ ops, results: answer.results });

        if (random() < 0.25) {
          const earlier = sent[Math.floor(random() * sent.length)]!;
          const includeWasApplied = random() < 0.5;
          const before = canonical(await dump(t));
          const derivedBefore = await derivedRows(t);
          const again = await send(earlier.ops, includeWasApplied);
          earlier.results.forEach((first: Json, index: number) => {
            replays[first.status] = (replays[first.status] ?? 0) + 1;
            const want = replayAnswer(first, includeWasApplied);
            const got = replayedAs(again.results[index]);
            if (canonical(got) !== canonical(want)) {
              problems.push(`${at}: ${earlier.ops[index].type} sent again answered ${canonical(got)}, its first answer says ${canonical(want)}`);
            }
          });
          if (canonical(await dump(t)) !== before || (await derivedRows(t)) !== derivedBefore) {
            problems.push(`${at}: sending a batch again changed rows`);
          }
        }

        const derived = await derivedRows(t);
        await rebuildDerivedRows(t);
        if ((await derivedRows(t)) !== derived) {
          problems.push(`${at}: derived rows differ from a rebuild from the content rows`);
        }
      }
    }
    expect(problems).toEqual([]);
    for (const [status, least] of Object.entries(replaysMustReach)) {
      expect(replays[status] ?? 0, `replays of ${status} ops`).toBeGreaterThanOrEqual(least);
    }
  },
);
