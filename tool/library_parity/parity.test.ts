import { convexTest } from "convex-test";
import { readFileSync, writeFileSync } from "node:fs";
import { expect, test } from "vitest";
import schema from "../../convex/schema";
import { modules } from "../../convex/test.setup";
import {
  answerProblems,
  canonical,
  outcomeName,
  outcomeOf,
  rowDifferences,
  unsafeNumbers,
} from "./compare.mjs";
import {
  applyBatch,
  dump,
  ensureCurrentUser,
  predictedRows,
  protocol,
  seed,
  type Json,
} from "./convexWorld";

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
