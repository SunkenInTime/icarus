import { convexTest, type TestConvexForDataModel } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { countingContentWrites } from "./lib/functions";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const updateStrategy = makeFunctionReference<"mutation">("strategies:update");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const addPage = makeFunctionReference<"mutation">("pages:add");
const deletePage = makeFunctionReference<"mutation">("pages:delete");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const listContentVersions = makeFunctionReference<"query">(
  "strategy:listContentVersions",
);
const foldContentChanges = makeFunctionReference<"mutation">(
  "maintenance:foldContentChanges",
);

/// Folds every change row, as the cron does once they are a minute old.
async function foldAll(t: { mutation: Harness["mutation"] }) {
  vi.advanceTimersByTime(2 * 60 * 1000);
  await t.mutation(foldContentChanges, {});
}

type Harness = TestConvexForDataModel<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

function identity(subject: string) {
  return {
    issuer: "https://content-versions.test",
    subject,
    tokenIdentifier: `content-versions|${subject}`,
    name: `User ${subject}`,
  };
}

afterEach(() => {
  vi.useRealTimers();
});

async function createHarness() {
  // Deleting schedules cleanup; fake timers let a test run it to the end.
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  const other = t.withIdentity(identity("other"));
  await owner.mutation(ensureCurrentUser, protocol);
  await other.mutation(ensureCurrentUser, protocol);
  return { t, owner, other };
}

async function create(t: Harness, publicId: string) {
  await t.mutation(createStrategy, {
    ...protocol,
    publicId,
    name: publicId,
    mapData: "ascent",
    initialPagePublicId: `${publicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

type Snapshot = {
  header: { revision: number; role: string };
  contentVersion?: number;
};
type VersionAnswer =
  | {
      strategyPublicId: string;
      status: "found";
      header: Snapshot["header"];
      contentVersion: number;
    }
  | { strategyPublicId: string; status: "gone" };

async function fullRead(t: Harness, strategyPublicId: string) {
  return (await t.query(getFullSnapshot, {
    ...protocol,
    strategyPublicId,
    acceptsTrashedPagesLeftOut: true,
    acceptsPictureIds: true,
    includeContentVersion: true,
  })) as Snapshot;
}

async function versions(t: Harness, ...strategyPublicIds: string[]) {
  return (await t.query(listContentVersions, {
    ...protocol,
    strategyPublicIds,
  })) as VersionAnswer[];
}

async function addAgent(t: Harness, strategyPublicId: string, id: string) {
  const result = (await t.mutation(applyBatch, {
    ...protocol,
    strategyPublicId,
    clientId: "device",
    ops: [
      {
        opId: `add-${id}`,
        type: "element.add",
        elementPublicId: id,
        pagePublicId: `${strategyPublicId}-page`,
        sortIndex: 0,
        payload: {
          kind: "agent",
          payloadVersion: 1,
          data: {
            id,
            elementType: "agent",
            kind: "plain",
            type: "sova",
            position: { dx: 10, dy: 20 },
            isAlly: true,
            state: "none",
            weapon: "none",
            isDeleted: false,
            lineUpID: null,
          },
        },
      },
    ],
  })) as { results: Array<{ status: string }> };
  expect(result.results[0]!.status).toBe("applied");
}

describe("a strategy's content version", () => {
  test("starts at 0 and goes up once per transaction that writes content", async () => {
    const { owner } = await createHarness();
    await create(owner, "s");
    // Creating writes its first page: that is content too.
    const created = (await versions(owner, "s"))[0]!;
    expect(created).toMatchObject({ status: "found", contentVersion: 1 });

    await addAgent(owner, "s", "agent-1");
    expect((await versions(owner, "s"))[0]).toMatchObject({
      contentVersion: 2,
    });
    // The full read carries the same number, read in the same transaction.
    expect((await fullRead(owner, "s")).contentVersion).toBe(2);
  });

  test("folding keeps every version and leaves one row to read", async () => {
    const { t, owner } = await createHarness();
    await create(owner, "s");
    await addAgent(owner, "s", "agent-1");
    await addAgent(owner, "s", "agent-2");
    expect((await versions(owner, "s"))[0]).toMatchObject({
      contentVersion: 3,
    });
    await foldAll(t);
    expect((await versions(owner, "s"))[0]).toMatchObject({
      contentVersion: 3,
    });
    await addAgent(owner, "s", "agent-3");
    expect((await versions(owner, "s"))[0]).toMatchObject({
      contentVersion: 4,
    });
    expect(
      await t.run(async (ctx) => ({
        folded: (await ctx.db.query("strategyContentVersions").collect()).map(
          (row) => row.version,
        ),
        unfolded: (await ctx.db.query("strategyContentChanges").collect())
          .length,
      })),
    ).toEqual({ folded: [3], unfolded: 1 });
  });

  test("a change row younger than a minute is left to fold later", async () => {
    const { t, owner } = await createHarness();
    await create(owner, "s");
    await t.mutation(foldContentChanges, {});
    expect(
      (await t.run((ctx) => ctx.db.query("strategyContentChanges").collect()))
        .length,
    ).toBe(1);
  });

  test("only the strategy written moves", async () => {
    const { owner } = await createHarness();
    await create(owner, "a");
    await create(owner, "b");
    await addAgent(owner, "a", "agent-a");
    const [a, b] = await versions(owner, "a", "b");
    expect(a).toMatchObject({ contentVersion: 2 });
    expect(b).toMatchObject({ contentVersion: 1 });
  });

  test("a page added and deleted each count", async () => {
    const { owner } = await createHarness();
    await create(owner, "s");
    const revision = (await fullRead(owner, "s")).header.revision;
    await owner.mutation(addPage, {
      ...protocol,
      strategyPublicId: "s",
      expectedRevision: revision,
      pagePublicId: "s-page-2",
      name: "Page 2",
      sortIndex: 1,
      isAttack: true,
    });
    const afterAdd = (await versions(owner, "s"))[0] as {
      contentVersion: number;
      header: { revision: number };
    };
    await owner.mutation(deletePage, {
      ...protocol,
      strategyPublicId: "s",
      pagePublicId: "s-page-2",
      expectedRevision: afterAdd.header.revision,
    });
    const afterDelete = (await versions(owner, "s"))[0] as {
      contentVersion: number;
    };
    expect(afterAdd.contentVersion).toBeGreaterThan(1);
    expect(afterDelete.contentVersion).toBeGreaterThan(afterAdd.contentVersion);
  });

  test("a rename changes the header, not the content version", async () => {
    const { owner } = await createHarness();
    await create(owner, "s");
    const before = (await versions(owner, "s"))[0] as VersionAnswer & {
      status: "found";
    };
    await owner.mutation(updateStrategy, {
      ...protocol,
      strategyPublicId: "s",
      name: "renamed",
      expectedRevision: before.header.revision,
    });
    const after = (await versions(owner, "s"))[0] as VersionAnswer & {
      status: "found";
    };
    expect(after.contentVersion).toBe(before.contentVersion);
    expect(after.header).not.toEqual(before.header);
  });

  test("a deleted strategy is gone, and its count with it", async () => {
    const { t, owner } = await createHarness();
    await create(owner, "s");
    await addAgent(owner, "s", "agent-1");
    const revision = (await fullRead(owner, "s")).header.revision;
    await owner.mutation(deleteStrategy, {
      ...protocol,
      strategyPublicId: "s",
      expectedRevision: revision,
    });
    expect(await versions(owner, "s")).toEqual([
      { strategyPublicId: "s", status: "gone" },
    ]);
    // Its content goes in later transactions; folding drops what they wrote.
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    await foldAll(t);
    expect(
      await t.run(async (ctx) => [
        ...(await ctx.db.query("strategyContentVersions").collect()),
        ...(await ctx.db.query("strategyContentChanges").collect()),
      ]),
    ).toEqual([]);
  });
});

describe("listContentVersions", () => {
  test("someone who can't read the strategy only learns it is gone", async () => {
    const { owner, other } = await createHarness();
    await create(owner, "s");
    expect(await versions(other, "s", "missing")).toEqual([
      { strategyPublicId: "s", status: "gone" },
      { strategyPublicId: "missing", status: "gone" },
    ]);
  });

  test("a role change shows in the header", async () => {
    const { t, owner, other } = await createHarness();
    await create(owner, "s");
    const collaboratorId = await t.run(async (ctx) => {
      const strategy = (await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "s"))
        .first())!;
      const user = (await ctx.db.query("users").collect()).find(
        (row) => row.externalId === "content-versions|other",
      )!;
      return await ctx.db.insert("strategyCollaborators", {
        strategyId: strategy._id,
        userId: user._id,
        role: "viewer",
        createdAt: 0,
        updatedAt: 0,
      });
    });
    const asViewer = (await versions(other, "s"))[0] as VersionAnswer & {
      status: "found";
    };
    expect(asViewer.header.role).toBe("viewer");
    expect((await fullRead(other, "s")).header).toEqual(asViewer.header);

    await t.run((ctx) => ctx.db.patch(collaboratorId, { role: "editor" }));
    const asEditor = (await versions(other, "s"))[0] as VersionAnswer & {
      status: "found";
    };
    expect(asEditor.header.role).toBe("editor");
    expect(asEditor.contentVersion).toBe(asViewer.contentVersion);
  });

  test("asks about at most 100 strategies at once", async () => {
    const { owner } = await createHarness();
    const ids = Array.from({ length: 101 }, (_, i) => `s${i}`);
    await expect(versions(owner, ...ids)).rejects.toThrow(/at most 100/);
  });

  test("the full read leaves the version out unless asked", async () => {
    const { owner } = await createHarness();
    await create(owner, "s");
    const plain = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: "s",
      acceptsTrashedPagesLeftOut: true,
    })) as Record<string, unknown>;
    expect(plain).not.toHaveProperty("contentVersion");
  });
});

describe("the counting database", () => {
  /// Runs [handler] the way every mutation runs: through the wrapper.
  async function counted(
    t: Awaited<ReturnType<typeof createHarness>>["t"],
    handler: (ctx: MutationCtx) => Promise<void>,
  ) {
    const run = countingContentWrites(async (ctx) => await handler(ctx)) as (
      ctx: MutationCtx,
      args: object,
    ) => Promise<unknown>;
    await t.run(async (ctx) => {
      await run(ctx, {});
    });
  }

  async function pageOf(ctx: MutationCtx, strategyPublicId: string) {
    const strategy = (await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .first())!;
    return (await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .first())!;
  }

  test("counts a write made through ctx.db.table()", async () => {
    const { t, owner } = await createHarness();
    await create(owner, "s");
    await counted(t, async (ctx) => {
      const page = await pageOf(ctx, "s");
      // Not in MutationCtx's type, but there at run time.
      const db = ctx.db as unknown as {
        table(name: string): {
          patch(id: unknown, value: object): Promise<void>;
        };
      };
      await db.table("pages").patch(page._id, { name: "renamed" });
    });
    expect((await versions(owner, "s"))[0]).toMatchObject({
      contentVersion: 2,
    });
  });

  test("counts a row given to another strategy for both", async () => {
    const { t, owner } = await createHarness();
    await create(owner, "a");
    await create(owner, "b");
    await counted(t, async (ctx) => {
      const page = await pageOf(ctx, "a");
      const other = await pageOf(ctx, "b");
      await ctx.db.patch(page._id, { strategyId: other.strategyId });
    });
    const [a, b] = await versions(owner, "a", "b");
    expect(a).toMatchObject({ contentVersion: 2 });
    expect(b).toMatchObject({ contentVersion: 2 });
  });
});

describe("every mutation counts content writes", () => {
  test("no module defines one with the generated builders", () => {
    // A mutation defined with the generated `mutation`/`internalMutation`
    // would write content without counting it, and an offline copy of that
    // strategy would never learn of the change.
    const root = dirname(fileURLToPath(import.meta.url));
    const offenders: string[] = [];
    const visit = (directory: string) => {
      for (const entry of readdirSync(directory, { withFileTypes: true })) {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) {
          if (entry.name !== "_generated" && entry.name !== "node_modules") {
            visit(path);
          }
          continue;
        }
        if (!/\.ts$/.test(entry.name) || /\.test\.ts$/.test(entry.name)) {
          continue;
        }
        if (path.endsWith(join("lib", "functions.ts"))) continue;
        const source = readFileSync(path, "utf8");
        // The generated builders by name, the whole generated module, or
        // Convex's own builders underneath them.
        const bypasses = [
          /import\s*\{[^}]*(mutation|internalMutation)[^}]*\}\s*from\s*"[./]*_generated\/server"/,
          /import\s*\*\s*as\s+\w+\s+from\s*"[./]*_generated\/server"/,
          /(mutationGeneric|internalMutationGeneric)/,
        ];
        if (bypasses.some((pattern) => pattern.test(source))) {
          offenders.push(path);
        }
      }
    };
    visit(root);
    expect(offenders).toEqual([]);
  });
});
