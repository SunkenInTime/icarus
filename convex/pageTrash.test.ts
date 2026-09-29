import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, describe, expect, test, vi } from "vitest";
import type { DataModel, Id } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import { PAGE_TRASH_RETENTION_MS } from "./lib/entities";
import { UNKNOWN_DISPLAY_NAME } from "./lib/profile";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const duplicateStrategy = makeFunctionReference<"mutation">(
  "strategies:duplicate",
);
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const listStrategies = makeFunctionReference<"query">(
  "strategies:listForFolder",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getShell = makeFunctionReference<"query">("strategy:getShell");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const listPages = makeFunctionReference<"query">("pages:listForStrategy");
const addPageLegacy = makeFunctionReference<"mutation">("pages:add");
const deletePageLegacy = makeFunctionReference<"mutation">("pages:delete");
const renamePageLegacy = makeFunctionReference<"mutation">("pages:rename");
const reorderPagesLegacy = makeFunctionReference<"mutation">("pages:reorder");
const restorePage = makeFunctionReference<"mutation">("pages:restore");
const listTrashed = makeFunctionReference<"query">("pages:listTrashed");
const listElementsForPage = makeFunctionReference<"query">(
  "elements:listForPage",
);
const listElementsForStrategy = makeFunctionReference<"query">(
  "elements:listForStrategy",
);
const listLineupsForPage = makeFunctionReference<"query">(
  "lineups:listForPage",
);
const listLineupsForStrategy = makeFunctionReference<"query">(
  "lineups:listForStrategy",
);
const purgeTrashedPages = makeFunctionReference<"mutation">(
  "maintenance:purgeTrashedPages",
);
const purgeDeletedPageOrphans = makeFunctionReference<"mutation">(
  "maintenance:purgeDeletedPageOrphans",
);
const listReferencedAssetIds = makeFunctionReference<"query">(
  "images:listReferencedAssetIds",
);
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type OpResult = Record<string, unknown>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategyPublicId = "trash-strategy";
const pageA = "trash-page-a";
const pageB = "trash-page-b";
const pageC = "trash-page-c";
const day = 24 * 60 * 60 * 1000;

function identity(subject: string) {
  return {
    issuer: "https://page-trash.test",
    subject,
    tokenIdentifier: `page-trash|${subject}`,
    name: subject,
  };
}

function agentPayload(type: string) {
  return {
    kind: "agent" as const,
    payloadVersion: 1,
    data: { type, elementType: "agent" },
  };
}

function textPayload(text: string) {
  return {
    kind: "text" as const,
    payloadVersion: 1,
    data: { text, elementType: "text" },
  };
}

function imagePayload(assetPublicId: string) {
  return {
    kind: "image" as const,
    payloadVersion: 1,
    data: { id: assetPublicId, elementType: "image" },
  };
}

const lineupRows = [
  {
    lineupPublicId: "lineupOrigin:o",
    payload: {
      kind: "lineupOrigin" as const,
      payloadVersion: 1,
      data: { id: "o", agent: { id: "agent-o", type: "sova", lineUpID: "o" } },
    },
  },
  {
    lineupPublicId: "lineupLanding:l",
    payload: {
      kind: "lineupLanding" as const,
      payloadVersion: 1,
      data: { id: "l", ability: { id: "ability-l" } },
    },
  },
  {
    lineupPublicId: "lineupLink:k",
    payload: {
      kind: "lineupLink" as const,
      payloadVersion: 1,
      data: { id: "k", originId: "o", landingId: "l", images: [{ id: "k-shot" }] },
    },
  },
];

/** A ConvexError's code (convex-test passes its data as JSON text). */
function errorCode(error: unknown): unknown {
  const data = (error as { data?: unknown }).data;
  return (typeof data === "string" ? JSON.parse(data) : data)?.code;
}

async function expectCode(promise: Promise<unknown>, code: string) {
  const error = await promise.then(
    () => null,
    (caught: unknown) => caught,
  );
  expect(error).not.toBeNull();
  expect(errorCode(error)).toBe(code);
}

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
}> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  await owner.mutation(ensureCurrentUser, protocol);
  return { t, owner };
}

async function member(
  t: RootHarness,
  owner: Harness,
  subject: string,
  role: "viewer" | "editor",
): Promise<Harness> {
  const user = t.withIdentity(identity(subject));
  await user.mutation(ensureCurrentUser, protocol);
  const token = `${subject}-${role}-token`;
  await owner.mutation(createShare, {
    ...protocol,
    targetType: "strategy",
    targetPublicId: strategyPublicId,
    token,
    role,
  });
  await user.mutation(redeemShare, { ...protocol, token });
  return user;
}

let opCounter = 0;

/// Sends [ops] as a client that restores deleted pages does, or, with
/// [oldClient], as one from before the trash.
async function apply(
  user: Harness,
  ops: Array<Record<string, unknown>>,
  { oldClient = false }: { oldClient?: boolean } = {},
): Promise<OpResult[]> {
  const result = (await user.mutation(applyBatch, {
    ...protocol,
    strategyPublicId,
    clientId: "client",
    ops: ops.map((op) => ({ opId: `op-${++opCounter}`, ...op })),
    ...(oldClient ? {} : { checkTrashedPageDeletes: true }),
  })) as { results: OpResult[] };
  return result.results;
}

async function strategyRevision(user: Harness): Promise<number> {
  const shell = (await user.query(getShell, { strategyPublicId })) as {
    header: { revision: number };
  };
  return shell.header.revision;
}

async function livePageIds(user: Harness): Promise<string[]> {
  const shell = (await user.query(getShell, { strategyPublicId })) as {
    pages: Array<{ publicId: string }>;
  };
  return shell.pages.map((page) => page.publicId);
}

/// A strategy of three pages. B, the one the tests delete, holds a text, an
/// agent, an image and a whole lineup; A holds an agent.
async function seed(owner: Harness) {
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Trash",
    mapData: "ascent",
    initialPagePublicId: pageA,
    initialPageName: "Page 1",
    initialPageIsAutoNamed: true,
    initialPageIsAttack: true,
  });
  let revision = await strategyRevision(owner);
  for (const [pagePublicId, name, isAutoNamed, isAttack, sortIndex] of [
    [pageB, "Page 2", true, false, 1],
    [pageC, "Retake", false, true, 2],
  ] as const) {
    await apply(owner, [
      {
        type: "page.add",
        pagePublicId,
        payload: { name, isAutoNamed, isAttack },
        sortIndex,
        expectedStrategyRevision: revision,
      },
    ]);
    revision += 1;
  }
  const results = await apply(owner, [
    {
      type: "element.add",
      elementPublicId: "a-agent",
      pagePublicId: pageA,
      payload: agentPayload("sova"),
      sortIndex: 0,
    },
    {
      type: "element.add",
      elementPublicId: "b-text",
      pagePublicId: pageB,
      payload: textPayload("hold B"),
      sortIndex: 0,
    },
    {
      type: "element.add",
      elementPublicId: "b-agent",
      pagePublicId: pageB,
      payload: agentPayload("jett"),
      sortIndex: 1,
    },
    {
      type: "element.add",
      elementPublicId: "b-image",
      pagePublicId: pageB,
      payload: imagePayload("b-image"),
      sortIndex: 2,
    },
    ...lineupRows.map((row, index) => ({
      type: "lineup.add",
      lineupPublicId: row.lineupPublicId,
      pagePublicId: pageB,
      payload: row.payload,
      sortIndex: index,
    })),
  ]);
  expect(results.map((result) => result.status)).toEqual(
    results.map(() => "applied"),
  );
}

async function deleteB(owner: Harness) {
  const [result] = await apply(owner, [
    {
      type: "page.delete",
      pagePublicId: pageB,
      expectedStrategyRevision: await strategyRevision(owner),
    },
  ]);
  expect(result).toMatchObject({ status: "applied" });
}

async function pageRow(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) =>
    ctx.db
      .query("pages")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .first(),
  );
}

async function rowsOnPage(t: RootHarness, pageId: Id<"pages">) {
  return await t.run(async (ctx) => ({
    elements: await ctx.db
      .query("elements")
      .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
      .collect(),
    lineups: await ctx.db
      .query("lineups")
      .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
      .collect(),
    contents: await ctx.db
      .query("pageContents")
      .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
      .collect(),
    references: (await ctx.db.query("assetReferences").collect()).filter(
      (reference) => reference.pageId === pageId,
    ),
  }));
}

async function agentSummary(t: RootHarness): Promise<string[]> {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .first();
    const summary = await ctx.db
      .query("strategyAgentSummaries")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy!._id))
      .unique();
    return summary?.agentTypes ?? [];
  });
}

afterEach(() => {
  vi.useRealTimers();
});

describe("page trash", () => {
  test("deleting a page moves it to the trash: its rows stay, every read hides it", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    const library = async () =>
      (
        (await owner.query(listStrategies, {})) as Array<{
          publicId: string;
          attackLabel: string;
        }>
      ).find((entry) => entry.publicId === strategyPublicId)?.attackLabel;
    expect(await library()).toBe("Mixed");
    expect(await agentSummary(t)).toEqual(["sova", "jett"]);

    await deleteB(owner);

    const trashed = await pageRow(t, pageB);
    expect(trashed?.deletedAt).toEqual(expect.any(Number));
    const kept = await rowsOnPage(t, trashed!._id);
    expect(kept.elements).toHaveLength(3);
    expect(kept.lineups).toHaveLength(3);
    expect(kept.contents).toHaveLength(1);
    expect(kept.references.map((reference) => reference.assetPublicId).sort())
      .toEqual(["b-image", "k-shot"]);

    const shell = (await owner.query(getShell, { strategyPublicId })) as {
      pages: Array<{ publicId: string; sortIndex: number; name: string }>;
    };
    expect(shell.pages).toMatchObject([
      { publicId: pageA, sortIndex: 0, name: "Page 1" },
      { publicId: pageC, sortIndex: 1, name: "Retake" },
    ]);
    expect(
      ((await owner.query(listPages, { strategyPublicId })) as Array<{
        publicId: string;
      }>).map((page) => page.publicId),
    ).toEqual([pageA, pageC]);
    const full = (await owner.query(getFullSnapshot, {
      strategyPublicId,
    })) as {
      pages: Array<{ publicId: string }>;
      elements: Array<{ publicId: string }>;
      lineups: unknown[];
      assets: unknown[];
    };
    expect(full.pages.map((page) => page.publicId)).toEqual([pageA, pageC]);
    expect(full.elements.map((element) => element.publicId)).toEqual([
      "a-agent",
    ]);
    expect(full.lineups).toEqual([]);
    for (const read of [getPageSnapshot, listElementsForPage, listLineupsForPage]) {
      await expectCode(
        owner.query(read, { strategyPublicId, pagePublicId: pageB }),
        "NOT_FOUND",
      );
    }
    expect(
      ((await owner.query(listElementsForStrategy, {
        strategyPublicId,
      })) as Array<{ publicId: string }>).map((element) => element.publicId),
    ).toEqual(["a-agent"]);
    expect(
      await owner.query(listLineupsForStrategy, { strategyPublicId }),
    ).toEqual([]);
    // The library and folder tree read only live pages.
    expect(await library()).toBe("Attack");
    expect(await agentSummary(t)).toEqual(["sova"]);
  });

  test("an old client's pages:delete trashes the page the same way", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);

    await owner.mutation(deletePageLegacy, {
      ...protocol,
      strategyPublicId,
      pagePublicId: pageB,
      expectedRevision: await strategyRevision(owner),
    });

    const trashed = await pageRow(t, pageB);
    expect(trashed?.deletedAt).toEqual(expect.any(Number));
    expect((await rowsOnPage(t, trashed!._id)).elements).toHaveLength(3);
    expect(await livePageIds(owner)).toEqual([pageA, pageC]);
    expect(await agentSummary(t)).toEqual(["sova"]);
    // Deleting it again changes nothing.
    await expect(
      owner.mutation(deletePageLegacy, {
        ...protocol,
        strategyPublicId,
        pagePublicId: pageB,
        expectedRevision: await strategyRevision(owner),
      }),
    ).resolves.toMatchObject({ ok: true, reused: true });
  });

  test("a page in the trash refuses every change with PAGE_DELETED and keeps its rows as they were", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);
    const trashed = await pageRow(t, pageB);
    const before = await rowsOnPage(t, trashed!._id);
    const revision = await strategyRevision(owner);

    const results = await apply(owner, [
      {
        type: "element.add",
        elementPublicId: "b-new",
        pagePublicId: pageB,
        payload: textPayload("new"),
        sortIndex: 3,
      },
      {
        type: "element.patch",
        elementPublicId: "b-text",
        pagePublicId: pageB,
        payload: textPayload("edited"),
        expectedElementRevision: 1,
      },
      {
        type: "element.reorder",
        elementPublicId: "b-text",
        pagePublicId: pageB,
        sortIndex: 9,
        expectedElementRevision: 1,
      },
      {
        type: "element.delete",
        elementPublicId: "b-agent",
        pagePublicId: pageB,
        expectedElementRevision: 1,
      },
      // Moving content off the trashed page, or onto it.
      {
        type: "element.patch",
        elementPublicId: "b-image",
        pagePublicId: pageA,
        expectedElementRevision: 1,
      },
      {
        type: "element.patch",
        elementPublicId: "a-agent",
        pagePublicId: pageB,
        expectedElementRevision: 1,
      },
      {
        type: "lineup.add",
        lineupPublicId: "lineupLanding:l2",
        pagePublicId: pageB,
        payload: {
          kind: "lineupLanding",
          payloadVersion: 1,
          data: { id: "l2", ability: { id: "ability-l2" } },
        },
        sortIndex: 3,
      },
      {
        type: "lineup.patch",
        lineupPublicId: "lineupLink:k",
        pagePublicId: pageB,
        payload: {
          ...lineupRows[2]!.payload,
          data: { ...lineupRows[2]!.payload.data, name: "edited" },
        },
        expectedLineupRevision: 1,
      },
      {
        type: "lineup.delete",
        lineupPublicId: "lineupLink:k",
        pagePublicId: pageB,
        expectedLineupRevision: 1,
      },
      {
        type: "pageContent.patch",
        pagePublicId: pageB,
        settings: { agentSize: 40, abilitySize: 30, useNeutralTeamColors: true },
        expectedPageContentRevision: 1,
      },
      {
        type: "page.patch",
        pagePublicId: pageB,
        payload: { name: "Renamed" },
        expectedPageRevision: trashed!.revision,
      },
      {
        type: "page.reorder",
        pagePublicId: pageB,
        sortIndex: 0,
        expectedStrategyRevision: revision,
      },
      {
        type: "page.add",
        pagePublicId: pageB,
        payload: { name: "Page 2", isAutoNamed: true, isAttack: false },
        sortIndex: 1,
        expectedStrategyRevision: revision,
      },
    ]);
    for (const result of results) {
      expect(result).toMatchObject({
        status: "failed",
        code: "PAGE_DELETED",
        message: "This page was deleted",
      });
    }

    // Deleting it again is already done.
    expect(
      await apply(owner, [
        {
          type: "page.delete",
          pagePublicId: pageB,
          expectedStrategyRevision: revision,
        },
      ]),
    ).toMatchObject([{ status: "noop" }]);
    await expectCode(
      owner.mutation(renamePageLegacy, {
        ...protocol,
        strategyPublicId,
        pagePublicId: pageB,
        name: "Renamed",
        expectedRevision: trashed!.revision,
      }),
      "NOT_FOUND",
    );
    await expectCode(
      owner.mutation(addPageLegacy, {
        ...protocol,
        strategyPublicId,
        expectedRevision: revision,
        pagePublicId: pageB,
        name: "Page 2",
        isAutoNamed: true,
        sortIndex: 1,
        isAttack: false,
      }),
      "PAGE_DELETED",
    );

    const after = await rowsOnPage(t, trashed!._id);
    expect(after).toEqual(before);
    expect(await pageRow(t, pageB)).toEqual(trashed);
    expect(await strategyRevision(owner)).toBe(revision);
  });

  test("restoring brings the page back at its place with everything on it; a refused change lands when sent again", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    const snapshotBefore = await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageB,
    });
    await deleteB(owner);
    const edit = {
      type: "element.patch",
      elementPublicId: "b-text",
      pagePublicId: pageB,
      payload: textPayload("edited while trashed"),
      expectedElementRevision: 1,
    };
    const [refused] = await apply(owner, [{ opId: "edit-1", ...edit }]);
    expect(refused).toMatchObject({ status: "failed", code: "PAGE_DELETED" });
    const revision = await strategyRevision(owner);

    await expect(
      owner.mutation(restorePage, {
        ...protocol,
        strategyPublicId,
        pagePublicId: pageB,
      }),
    ).resolves.toEqual({ ok: true, revision: revision + 1 });

    expect(await livePageIds(owner)).toEqual([pageA, pageB, pageC]);
    expect(
      await owner.query(getPageSnapshot, {
        strategyPublicId,
        pagePublicId: pageB,
      }),
    ).toEqual(snapshotBefore);
    expect((await pageRow(t, pageB))?.deletedAt).toBeUndefined();
    expect(await agentSummary(t)).toEqual(["sova", "jett"]);
    // The same op id replays what the server answered it; the change sent
    // again under a new id lands on the restored page.
    expect(await apply(owner, [{ opId: "edit-1", ...edit }])).toMatchObject([
      { status: "failed", code: "PAGE_DELETED" },
    ]);
    expect(await apply(owner, [{ opId: "edit-2", ...edit }])).toMatchObject([
      { status: "applied", appliedRevision: 2 },
    ]);

    // Restoring a live page changes nothing.
    await expect(
      owner.mutation(restorePage, {
        ...protocol,
        strategyPublicId,
        pagePublicId: pageB,
      }),
    ).resolves.toEqual({ ok: true, reused: true, revision: revision + 1 });
  });

  test("a restored page goes last when fewer pages are left than its old place, and auto-names follow the order", async () => {
    const { owner } = await createHarness();
    await seed(owner);
    await apply(owner, [
      {
        type: "page.delete",
        pagePublicId: pageC,
        expectedStrategyRevision: await strategyRevision(owner),
      },
    ]);
    await deleteB(owner);
    expect(await livePageIds(owner)).toEqual([pageA]);

    await owner.mutation(restorePage, {
      ...protocol,
      strategyPublicId,
      pagePublicId: pageC,
    });
    await owner.mutation(restorePage, {
      ...protocol,
      strategyPublicId,
      pagePublicId: pageB,
    });

    const shell = (await owner.query(getShell, { strategyPublicId })) as {
      pages: Array<{ publicId: string; sortIndex: number; name: string }>;
    };
    expect(shell.pages).toMatchObject([
      { publicId: pageA, sortIndex: 0, name: "Page 1" },
      { publicId: pageB, sortIndex: 1, name: "Page 2" },
      { publicId: pageC, sortIndex: 2, name: "Retake" },
    ]);
  });

  test("anyone who can delete a page can restore it, and no one else", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    const viewer = await member(t, owner, "viewer", "viewer");
    const editor = await member(t, owner, "editor", "editor");
    const stranger = t.withIdentity(identity("stranger"));
    await stranger.mutation(ensureCurrentUser, protocol);
    await deleteB(editor);
    const args = { ...protocol, strategyPublicId, pagePublicId: pageB };

    await expectCode(viewer.mutation(restorePage, args), "FORBIDDEN");
    await expectCode(stranger.mutation(restorePage, args), "FORBIDDEN");
    await expect(editor.mutation(restorePage, args)).resolves.toMatchObject({
      ok: true,
    });
    expect(await livePageIds(viewer)).toEqual([pageA, pageB, pageC]);
  });

  test("a page never in this strategy cannot be restored", async () => {
    const { owner } = await createHarness();
    await seed(owner);
    await expectCode(
      owner.mutation(restorePage, {
        ...protocol,
        strategyPublicId,
        pagePublicId: "never-existed",
      }),
      "NOT_FOUND",
    );
  });

  test("an old client's delete of content on a trashed page gets the no-op it got when the content was purged", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);
    const trashed = await pageRow(t, pageB);
    const before = await rowsOnPage(t, trashed!._id);

    const results = await apply(
      owner,
      [
        {
          type: "element.delete",
          elementPublicId: "b-agent",
          pagePublicId: pageB,
          expectedElementRevision: 1,
        },
        {
          type: "lineup.delete",
          lineupPublicId: "lineupLink:k",
          pagePublicId: pageB,
          expectedLineupRevision: 1,
        },
        // Anything that adds or changes content is still refused.
        {
          type: "element.patch",
          elementPublicId: "b-text",
          pagePublicId: pageB,
          payload: textPayload("edited"),
          expectedElementRevision: 1,
        },
      ],
      { oldClient: true },
    );

    expect(results).toMatchObject([
      { status: "noop" },
      { status: "noop" },
      { status: "failed", code: "PAGE_DELETED" },
    ]);
    // Nothing on the page changed: restoring it brings it back whole.
    expect(await rowsOnPage(t, trashed!._id)).toEqual(before);
  });

  test("a replayed rejection shows no current copy of content in the trash", async () => {
    const { owner } = await createHarness();
    await seed(owner);
    const stale = {
      opId: "stale-edit",
      type: "element.patch",
      elementPublicId: "b-text",
      pagePublicId: pageB,
      payload: textPayload("stale"),
      expectedElementRevision: 7,
    };
    expect(await apply(owner, [stale])).toMatchObject([
      { status: "rejected", current: { revision: 1 } },
    ]);
    await deleteB(owner);

    // The answer was lost; the same op is sent again.
    const [replayed] = await apply(owner, [stale]);
    expect(replayed).toMatchObject({ status: "rejected" });
    expect(replayed).not.toHaveProperty("current");
  });

  test("a trashed page is kept for the whole retention, then cannot be restored and is purged with everything on it", async () => {
    vi.useFakeTimers();
    const { t, owner } = await createHarness();
    await seed(owner);
    // More content than one purge run takes, so the purge reschedules.
    await apply(
      owner,
      Array.from({ length: 20 }, (_, index) => ({
        type: "element.add",
        elementPublicId: `b-extra-${index}`,
        pagePublicId: pageB,
        payload: textPayload(`extra ${index}`),
        sortIndex: 10 + index,
      })),
    );
    await deleteB(owner);
    const trashed = await pageRow(t, pageB);
    const liveA = await pageRow(t, pageA);
    const aRows = await rowsOnPage(t, liveA!._id);
    // A client holding an upload for one of the page's images keeps it
    // while the page can be restored.
    expect(
      await owner.query(listReferencedAssetIds, { strategyPublicId }),
    ).toEqual(["b-image", "k-shot"]);

    vi.setSystemTime(Date.now() + PAGE_TRASH_RETENTION_MS - day);
    await t.mutation(purgeTrashedPages, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await pageRow(t, pageB)).toEqual(trashed);
    expect((await rowsOnPage(t, trashed!._id)).elements).toHaveLength(23);

    vi.setSystemTime(Date.now() + 2 * day);
    await expectCode(
      owner.mutation(restorePage, {
        ...protocol,
        strategyPublicId,
        pagePublicId: pageB,
      }),
      "NOT_FOUND",
    );
    await t.mutation(purgeTrashedPages, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await pageRow(t, pageB)).toBeNull();
    expect(await rowsOnPage(t, trashed!._id)).toEqual({
      elements: [],
      lineups: [],
      contents: [],
      references: [],
    });
    expect(await rowsOnPage(t, liveA!._id)).toEqual(aRows);
    expect(await livePageIds(owner)).toEqual([pageA, pageC]);
    expect(
      await owner.query(listReferencedAssetIds, { strategyPublicId }),
    ).toEqual([]);
  });

  test("the orphan purge scheduled by older deletes leaves a page that still has its row alone", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);
    const trashed = await pageRow(t, pageB);
    const before = await rowsOnPage(t, trashed!._id);

    await t.mutation(purgeDeletedPageOrphans, {
      pageId: trashed!._id,
      strategyId: trashed!.strategyId,
    });

    expect(await rowsOnPage(t, trashed!._id)).toEqual(before);
  });

  test("the last live page cannot be deleted, whatever is in the trash", async () => {
    const { owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);
    await apply(owner, [
      {
        type: "page.delete",
        pagePublicId: pageC,
        expectedStrategyRevision: await strategyRevision(owner),
      },
    ]);

    expect(
      await apply(owner, [
        {
          type: "page.delete",
          pagePublicId: pageA,
          expectedStrategyRevision: await strategyRevision(owner),
        },
      ]),
    ).toMatchObject([{ status: "failed", code: "INVALID_OP" }]);
    await expect(
      owner.mutation(deletePageLegacy, {
        ...protocol,
        strategyPublicId,
        pagePublicId: pageA,
        expectedRevision: await strategyRevision(owner),
      }),
    ).rejects.toThrow("Cannot delete last page");
  });

  test("old clients' reorder and add see only live pages", async () => {
    const { owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);

    // An old client lists the live pages it was shown.
    await owner.mutation(reorderPagesLegacy, {
      ...protocol,
      strategyPublicId,
      orderedPagePublicIds: [pageC, pageA],
      expectedRevision: await strategyRevision(owner),
    });
    expect(await livePageIds(owner)).toEqual([pageC, pageA]);

    await owner.mutation(addPageLegacy, {
      ...protocol,
      strategyPublicId,
      expectedRevision: await strategyRevision(owner),
      pagePublicId: "legacy-added",
      name: "Legacy",
      sortIndex: 9,
      isAttack: true,
    });
    await apply(owner, [
      {
        type: "page.add",
        pagePublicId: "op-added",
        payload: { name: "Op", isAttack: true },
        sortIndex: 9,
        expectedStrategyRevision: await strategyRevision(owner),
      },
    ]);
    const shell = (await owner.query(getShell, { strategyPublicId })) as {
      pages: Array<{ publicId: string; sortIndex: number }>;
    };
    expect(shell.pages).toMatchObject([
      { publicId: pageC, sortIndex: 0 },
      { publicId: pageA, sortIndex: 1 },
      { publicId: "legacy-added", sortIndex: 2 },
      { publicId: "op-added", sortIndex: 3 },
    ]);

    // Restored into that order, B takes its old place, second.
    await owner.mutation(restorePage, {
      ...protocol,
      strategyPublicId,
      pagePublicId: pageB,
    });
    expect(await livePageIds(owner)).toEqual([
      pageC,
      pageB,
      pageA,
      "legacy-added",
      "op-added",
    ]);
  });

  test("duplicating a strategy leaves its trashed pages behind", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);

    await owner.mutation(duplicateStrategy, {
      ...protocol,
      sourceStrategyPublicId: strategyPublicId,
      publicId: "trash-copy",
      name: "Trash (Copy)",
    });

    const copy = (await owner.query(getFullSnapshot, {
      strategyPublicId: "trash-copy",
    })) as {
      pages: Array<{ name: string }>;
      elements: Array<{ payload: { kind: string } }>;
      lineups: unknown[];
    };
    expect(copy.pages.map((page) => page.name)).toEqual(["Page 1", "Retake"]);
    expect(copy.elements.map((element) => element.payload.kind)).toEqual([
      "agent",
    ]);
    expect(copy.lineups).toEqual([]);
    const copyPageCount = await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "trash-copy"))
        .first();
      return (
        await ctx.db
          .query("pages")
          .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy!._id))
          .collect()
      ).length;
    });
    expect(copyPageCount).toBe(2);
  });

  test("deleting the strategy leaves its trashed pages to the trash purge", async () => {
    vi.useFakeTimers();
    const { t, owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);
    const trashed = await pageRow(t, pageB);

    await owner.mutation(deleteStrategy, {
      ...protocol,
      strategyPublicId,
      expectedRevision: await strategyRevision(owner),
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    // Live pages go now, one scheduled purge each; the trash waits.
    expect(await pageRow(t, pageA)).toBeNull();
    expect(await pageRow(t, pageB)).not.toBeNull();

    vi.setSystemTime(Date.now() + PAGE_TRASH_RETENTION_MS + 1);
    await t.mutation(purgeTrashedPages, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await pageRow(t, pageB)).toBeNull();
    expect(await rowsOnPage(t, trashed!._id)).toEqual({
      elements: [],
      lineups: [],
      contents: [],
      references: [],
    });
  });
});

describe("Recently deleted", () => {
  test("lists the strategy's restorable pages, newest first, with who deleted each", async () => {
    vi.useFakeTimers();
    const { t, owner } = await createHarness();
    await seed(owner);
    const editor = await member(t, owner, "editor", "editor");
    await deleteB(owner);
    const deletedB = Date.now();
    vi.setSystemTime(deletedB + day);
    // An old client's delete records its deleter too.
    await editor.mutation(deletePageLegacy, {
      ...protocol,
      strategyPublicId,
      pagePublicId: pageC,
      expectedRevision: await strategyRevision(editor),
    });

    const trashed = await owner.query(listTrashed, { strategyPublicId });
    expect(trashed).toEqual([
      {
        publicId: pageC,
        name: "Retake",
        deletedAt: deletedB + day,
        restorableUntil: deletedB + day + PAGE_TRASH_RETENTION_MS,
        deletedByName: "editor",
        deletedByYou: false,
      },
      {
        publicId: pageB,
        name: "Page 2",
        deletedAt: deletedB,
        restorableUntil: deletedB + PAGE_TRASH_RETENTION_MS,
        deletedByName: "owner",
        deletedByYou: true,
      },
    ]);
    expect((await pageRow(t, pageB))?.deletedBy).toEqual(expect.any(String));

    // Restored, a page leaves the list and forgets who deleted it.
    await owner.mutation(restorePage, {
      ...protocol,
      strategyPublicId,
      pagePublicId: pageB,
    });
    expect(
      (await owner.query(listTrashed, { strategyPublicId })).map(
        (page: { publicId: string }) => page.publicId,
      ),
    ).toEqual([pageC]);
    expect((await pageRow(t, pageB))?.deletedBy).toBeUndefined();
  });

  test("a deleter who is not known shows no name", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    const editor = await member(t, owner, "editor", "editor");
    await deleteB(editor);
    await apply(owner, [
      {
        type: "page.delete",
        pagePublicId: pageC,
        expectedStrategyRevision: await strategyRevision(owner),
      },
    ]);
    // B as trashed before deleters were recorded; C's deleter has no name.
    const b = await pageRow(t, pageB);
    await t.run(async (ctx) => {
      await ctx.db.patch(b!._id, { deletedBy: undefined });
      const owners = await ctx.db.query("users").collect();
      for (const user of owners) {
        if (user.displayName === "owner") {
          await ctx.db.patch(user._id, { displayName: UNKNOWN_DISPLAY_NAME });
        }
      }
    });

    expect(
      (await editor.query(listTrashed, { strategyPublicId })).map(
        (page: { publicId: string; deletedByName: string | null }) => [
          page.publicId,
          page.deletedByName,
        ],
      ),
    ).toEqual(
      expect.arrayContaining([
        [pageB, null],
        [pageC, null],
      ]),
    );
  });

  test("a page past its time in the trash is not listed", async () => {
    vi.useFakeTimers();
    const { owner } = await createHarness();
    await seed(owner);
    await deleteB(owner);

    vi.setSystemTime(Date.now() + PAGE_TRASH_RETENTION_MS - 1);
    expect(await owner.query(listTrashed, { strategyPublicId })).toHaveLength(
      1,
    );
    vi.setSystemTime(Date.now() + 2);
    expect(await owner.query(listTrashed, { strategyPublicId })).toEqual([]);
  });

  test("only those who can restore a page see the list", async () => {
    const { t, owner } = await createHarness();
    await seed(owner);
    const viewer = await member(t, owner, "viewer", "viewer");
    const stranger = t.withIdentity(identity("stranger"));
    await stranger.mutation(ensureCurrentUser, protocol);
    await deleteB(owner);

    await expectCode(
      viewer.query(listTrashed, { strategyPublicId }),
      "FORBIDDEN",
    );
    await expectCode(
      stranger.query(listTrashed, { strategyPublicId }),
      "FORBIDDEN",
    );
  });
});
