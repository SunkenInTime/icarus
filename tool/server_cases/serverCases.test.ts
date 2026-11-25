import { convexTest, type TestConvexForDataModel } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  afterAll,
  afterEach,
  beforeEach,
  describe,
  expect,
  test,
  vi,
} from "vitest";
import type { DataModel } from "../../convex/_generated/dataModel";
import { markAssetReferencesReady } from "../../convex/lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "../../convex/lib/cloudProtocol";
import schema from "../../convex/schema";
import { modules } from "../../convex/test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const purgeOldTombstones = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);

type Json = Record<string, unknown>;
type Step =
  | { create: true }
  | { recreate: true }
  | { purge: true }
  | { send: Json[]; strategyLife?: string; expect: Json[] }
  | { send: Json[]; strategyLife: string; refused: string; currentLife: string };
type Case = { name: string; steps: Step[] };

const cases = JSON.parse(
  readFileSync(
    resolve(__dirname, "../../packages/icarus_library/test/server_cases.json"),
    "utf8",
  ),
) as Case[];

const recording = process.env.SERVER_CASES_RECORD;
const recorded: Json[] = [];

afterAll(() => {
  if (recording !== undefined) {
    writeFileSync(recording, JSON.stringify(recorded, null, 2));
  }
});

const strategyPublicId = "case-strategy";
const start = Date.UTC(2026, 10, 24, 12, 0, 0);
const day = 24 * 60 * 60 * 1000;

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(start);
});

afterEach(() => {
  vi.useRealTimers();
});

class Lives {
  private readonly names = new Map<number, string>();
  private readonly numbers = new Map<string, number>();

  name(life: number): string {
    let name = this.names.get(life);
    if (name === undefined) {
      name = `L${this.names.size}`;
      this.names.set(life, name);
      this.numbers.set(name, life);
    }
    return name;
  }

  number(name: string): number {
    const life = this.numbers.get(name);
    if (life === undefined) throw new Error(`${name} has not been seen yet`);
    return life;
  }
}

function normalized(result: Json, lives: Lives): Json {
  const out: Json = {};
  for (const [key, value] of Object.entries(result)) {
    if (key === "current" && value !== null && typeof value === "object") {
      const current = value as Json;
      out.current = {
        type: current.type,
        revision: current.revision,
        ...(typeof current.life === "number"
          ? { life: lives.name(current.life) }
          : {}),
        value: current.value,
      };
    } else if (key.endsWith("Life") && typeof value === "number") {
      out[key] = lives.name(value);
    } else {
      out[key] = value;
    }
  }
  return out;
}

async function create(me: TestConvexForDataModel<DataModel>) {
  await me.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId: strategyPublicId,
    name: "Case",
    mapData: "ascent",
    initialPagePublicId: "p",
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

describe("the stand-in server in packages/icarus_library/test/cloud_server.dart answers these cases as ops:applyBatch does", () => {
  for (const { name, steps } of cases) {
    test(name, async () => {
      const t = convexTest(schema, modules);
      const me = t.withIdentity({
        issuer: "https://cases.test",
        subject: "me",
        tokenIdentifier: "cases|me",
        name: "me",
      });
      await me.mutation(ensureCurrentUser, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      });
      const lives = new Lives();
      for (const step of steps) {
        vi.setSystemTime(Date.now() + 1000);
        if ("create" in step) {
          await create(me);
        } else if ("recreate" in step) {
          const revision = await t.run(
            async (ctx) =>
              (await ctx.db
                .query("strategies")
                .withIndex("by_publicId", (q) =>
                  q.eq("publicId", strategyPublicId),
                )
                .first())!.revision,
          );
          await me.mutation(deleteStrategy, {
            clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
            strategyPublicId,
            expectedRevision: revision,
          });
          vi.setSystemTime(Date.now() + 60_000);
          await create(me);
        } else if ("purge" in step) {
          await t.run(markAssetReferencesReady);
          vi.setSystemTime(Date.now() + 31 * day);
          await t.mutation(purgeOldTombstones, {});
          await t.finishAllScheduledFunctions(vi.runAllTimers);
        } else {
          const ops = step.send.map((op) =>
            typeof op.expectedLife === "string"
              ? { ...op, expectedLife: lives.number(op.expectedLife) }
              : op,
          );
          const sent = me.mutation(applyBatch, {
            clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
            strategyPublicId,
            clientId: "device",
            includeWasApplied: true,
            sendsLives: true,
            ...(step.strategyLife === undefined
              ? {}
              : { strategyLife: lives.number(step.strategyLife) }),
            ops,
          });
          if ("refused" in step) {
            const refused = await sent.then(
              () => "",
              (error: { data?: unknown }) => String(error.data),
            );
            const data = JSON.parse(refused);
            expect(data.code).toBe(step.refused);
            const held = await t.run(
              async (ctx) =>
                (await ctx.db
                  .query("strategies")
                  .withIndex("by_publicId", (q) =>
                    q.eq("publicId", strategyPublicId),
                  )
                  .first())!.createdAt,
            );
            expect(data.currentLife).toBe(held);
            expect(lives.name(data.currentLife)).toBe(step.currentLife);
          } else {
            const answer = (await sent) as { results: Json[] };
            const got = answer.results.map((result) => normalized(result, lives));
            if (recording !== undefined) {
              recorded.push({ name, step: steps.indexOf(step), got });
            } else {
              expect(got).toEqual(step.expect);
            }
          }
        }
      }
    });
  }
});
