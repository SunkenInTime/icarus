import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import { mutation } from "./lib/functions";
import {
  ContentChangedWithoutRevision,
  changedWithoutRevision,
} from "./revisionGuard.setup";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

type Row = Record<string, unknown>;
type Invoked = { _handler: (ctx: unknown, args: unknown) => Promise<unknown> };

async function seeded() {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity({
    issuer: "https://revision-guard.test",
    subject: "owner",
    tokenIdentifier: "revision-guard|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: "guarded",
    name: "Guarded",
    mapData: "ascent",
    initialPagePublicId: "guarded-page",
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId: "guarded",
    clientId: "guard",
    ops: [
      {
        opId: "add",
        type: "element.add",
        elementPublicId: "agent",
        pagePublicId: "guarded-page",
        payload: {
          kind: "agent",
          payloadVersion: 1,
          data: { id: "agent", type: "jett", position: { dx: 1, dy: 2 } },
        },
        sortIndex: 0,
      },
    ],
  });
  const element = await t.run(
    async (ctx) => (await ctx.db.query("elements").first()) as Row,
  );
  return { t, element };
}

function writing(change: (row: Row) => Row): Invoked {
  return mutation({
    args: {},
    handler: async (ctx, args: { id: string; row: Row }) => {
      await ctx.db.patch(args.id as never, change(args.row) as never);
    },
  }) as unknown as Invoked;
}

describe("the revision guard every convex test runs under", () => {
  test("refuses a write that moves an element without raising its revision", async () => {
    const { t, element } = await seeded();
    const sneaky = writing(() => ({ sortIndex: 7 }));
    await expect(
      t.run((ctx) => sneaky._handler(ctx, { id: element._id, row: element })),
    ).rejects.toThrow(ContentChangedWithoutRevision);
  });

  test("lets the same write through when it raises the revision", async () => {
    const { t, element } = await seeded();
    const honest = writing((row) => ({
      sortIndex: 7,
      revision: (row.revision as number) + 1,
    }));
    await t.run((ctx) =>
      honest._handler(ctx, { id: element._id, row: element }),
    );
    const after = await t.run(
      async (ctx) => (await ctx.db.get(element._id as never)) as Row,
    );
    expect(after.sortIndex).toBe(7);
  });

  test("checks every field the client's row digest covers", () => {
    const before: Row = {
      pageId: "p",
      sortIndex: 0,
      deleted: false,
      elementType: "agent",
      payloadKind: "agent",
      payload: { kind: "agent", payloadVersion: 1, data: { a: 1 } },
      revision: 3,
      createdAt: 10,
    };
    const changed: Row = {
      pageId: "q",
      sortIndex: 1,
      deleted: true,
      elementType: "text",
      payloadKind: "text",
      payload: { kind: "agent", payloadVersion: 1, data: { a: 2 } },
    };
    for (const field of [
      "pageId",
      "sortIndex",
      "deleted",
      "elementType",
      "payloadKind",
      "payload",
    ]) {
      expect(
        changedWithoutRevision(before, { ...before, [field]: changed[field] }),
      ).toEqual([field]);
    }
    expect(
      changedWithoutRevision(before, { ...before, updatedAt: 99 }),
    ).toEqual([]);
    expect(
      changedWithoutRevision(before, {
        ...before,
        sortIndex: 5,
        revision: 4,
      }),
    ).toEqual([]);
  });

  test("refuses any write that lowers a row's revision", () => {
    const before: Row = { sortIndex: 0, revision: 3, createdAt: 10 };
    expect(changedWithoutRevision(before, { ...before, revision: 2 })).toEqual([
      "revision",
    ]);
    expect(
      changedWithoutRevision(before, {
        ...before,
        sortIndex: 4,
        revision: 1,
        createdAt: 11,
      }),
    ).toEqual(["revision"]);
  });

  test("refuses a real write that lowers the revision and nothing else", async () => {
    const { t, element } = await seeded();
    const lowering = writing((row) => ({
      revision: (row.revision as number) - 1,
    }));
    await expect(
      t.run((ctx) => lowering._handler(ctx, { id: element._id, row: element })),
    ).rejects.toThrow(/lowered its revision/);
  });
});
