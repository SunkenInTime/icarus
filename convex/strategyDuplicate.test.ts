import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { lineupsPayload, oneLineupPayload } from "./testContent.helpers";
import { modules } from "./test.setup";
import { pageCopyRoot } from "./lib/pageCopyId";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
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
const addPage = makeFunctionReference<"mutation">("pages:add");
const deletePage = makeFunctionReference<"mutation">("pages:delete");
const purgeOldTombstones = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const listImages = makeFunctionReference<"query">("images:listForStrategy");
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const source = "duplicate-source";
const firstPage = "duplicate-source-page-1";
const secondPage = "duplicate-source-page-2";
const settings = { agentSize: 40, abilitySize: 30, useNeutralTeamColors: true };

function identity(subject: string) {
  return {
    issuer: "https://duplicate.test",
    subject,
    tokenIdentifier: `duplicate|${subject}`,
    name: `User ${subject}`,
  };
}

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
  other: Harness;
}> {
  const t = convexTest(schema, modules);
  // A deployment whose reference backfill has run, as every one will be.
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  const other = t.withIdentity(identity("other"));
  await owner.mutation(ensureCurrentUser, protocol);
  await other.mutation(ensureCurrentUser, protocol);
  return { t, owner, other };
}

// One lineup group holding one lineup. The group, its lineup and its
// landing share one id, as a landing made with its lineup does.
const seedLineupData = {
  id: "item-1",
  origins: [
    { id: "origin-1", agent: { type: "sova", lineUpID: "origin-1" } },
  ],
  landings: [
    { id: "item-1", ability: { type: "shock_dart", lineUpID: "item-1" } },
  ],
  links: [
    {
      id: "item-1",
      originId: "origin-1",
      landingId: "item-1",
      name: "Shock dart",
      notes: "Two bounces",
      images: [{ id: "lineup-image" }],
    },
  ],
};

/// A two-page strategy with a placed image, a lineup with an image, an agent,
/// and one deleted element, backed by active R2 asset rows.
async function seedSource(t: RootHarness, owner: Harness): Promise<void> {
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: source,
    name: "Split A execute",
    mapData: "split",
    initialPagePublicId: firstPage,
    initialPageName: "Setup",
    initialPageIsAutoNamed: false,
    initialPageIsAttack: true,
    initialPageSettings: settings,
    themeProfileId: "theme-1",
  });
  await owner.mutation(addPage, {
    ...protocol,
    strategyPublicId: source,
    pagePublicId: secondPage,
    name: "Retake",
    sortIndex: 1,
    isAttack: false,
    expectedRevision: 0,
  });
  // Uploads land before the content that shows them, as on a device that
  // placed the images online.
  await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", source))
      .unique();
    const now = Date.now();
    for (const publicId of ["placed-image", "lineup-image"]) {
      await ctx.db.insert("imageAssets", {
        publicId,
        provider: "r2",
        strategyId: strategy!._id,
        uploadAttemptPublicId: `${publicId}-attempt`,
        objectKey: `strategies/${source}/${publicId}.png`,
        uploadStatus: "active",
        fileExtension: ".png",
        mimeType: "image/png",
        width: 64,
        height: 32,
        byteSize: 100,
        uploadedAt: now,
        createdAt: now,
        updatedAt: now,
      });
    }
  });
  await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId: source,
    clientId: "seed",
    ops: [
      {
        opId: "add-image",
        type: "element.add",
        elementPublicId: "placed-image",
        pagePublicId: firstPage,
        payload: {
          kind: "image",
          payloadVersion: 1,
          data: { id: "placed-image", elementType: "image", scale: 2 },
        },
        sortIndex: 3,
      },
      {
        opId: "add-agent",
        type: "element.add",
        elementPublicId: "placed-agent",
        pagePublicId: secondPage,
        payload: {
          kind: "agent",
          payloadVersion: 1,
          data: { id: "placed-agent", type: "jett" },
        },
        sortIndex: 1,
      },
      {
        opId: "add-removed",
        type: "element.add",
        elementPublicId: "removed-text",
        pagePublicId: firstPage,
        payload: {
          kind: "text",
          payloadVersion: 1,
          data: { id: "removed-text", text: "gone" },
        },
        sortIndex: 4,
      },
      {
        opId: "remove-text",
        type: "element.delete",
        elementPublicId: "removed-text",
        pagePublicId: firstPage,
        expectedElementRevision: 1,
      },
      // One lineup group showing an image.
      {
        opId: "add-lineup",
        type: "lineup.add",
        lineupPublicId: "item-1",
        pagePublicId: secondPage,
        payload: {
          kind: "lineups",
          payloadVersion: 1,
          data: seedLineupData,
        },
        sortIndex: 0,
      },
    ],
  });
}

async function duplicate(
  user: Harness,
  publicId = "duplicate-copy",
  extra: { folderPublicId?: string; sourceStrategyPublicId?: string } = {},
) {
  return await user.mutation(duplicateStrategy, {
    ...protocol,
    sourceStrategyPublicId: source,
    publicId,
    name: "Split A execute (Copy)",
    ...extra,
  });
}

type ImageRow = { publicId: string; uploadStatus: string; url: string | null };

async function imageUrls(user: Harness, strategyPublicId: string) {
  const images = (await user.query(listImages, {
    strategyPublicId,
  })) as ImageRow[];
  return Object.fromEntries(images.map((image) => [image.publicId, image.url]));
}

function mockR2Deletes() {
  const fetchMock = vi.fn(
    async (_input: RequestInfo | URL, _init?: RequestInit) =>
      new Response(null, { status: 204 }),
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function deletedKeys(fetchMock: ReturnType<typeof mockR2Deletes>): string[] {
  return fetchMock.mock.calls
    .map((call) => new URL(String(call[0])).pathname)
    .sort();
}

async function deleteAndSweep(
  t: RootHarness,
  owner: Harness,
  strategyPublicId: string,
) {
  const revision = await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    return strategy!.revision;
  });
  await owner.mutation(deleteStrategy, {
    ...protocol,
    strategyPublicId,
    expectedRevision: revision,
  });
  await t.finishAllScheduledFunctions(vi.runAllTimers);
}

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "duplicate-account";
  process.env.R2_BUCKET = "duplicate-bucket";
  process.env.R2_ACCESS_KEY_ID = "duplicate-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "duplicate-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://media.duplicate.test";
  process.env.R2_S3_ENDPOINT = "https://duplicate.r2.test";
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("strategies:duplicate", () => {
  test("copies keep their roots, so items copied between pages still pair", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    // The agent on page 2 was copied back to page 1, as the app copies.
    const agentCopy = "placed-agent~cp1~6f1c2d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f";
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "copy-agent",
      ops: [
        {
          opId: "add-agent-copy",
          type: "element.add",
          elementPublicId: agentCopy,
          pagePublicId: firstPage,
          payload: {
            kind: "agent",
            payloadVersion: 1,
            data: { id: agentCopy, type: "jett" },
          },
          sortIndex: 5,
        },
      ],
    });

    await duplicate(owner);

    type Row = Record<string, any>;
    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
    })) as { elements: Row[]; lineups: Row[] };
    const agents = copy.elements.filter((row) => row.elementType === "agent");
    expect(agents).toHaveLength(2);
    // Both agents in the copy are copies of the same root, under new ids.
    expect(agents.map((row) => pageCopyRoot(row.publicId))).toEqual([
      "placed-agent",
      "placed-agent",
    ]);
    expect(new Set(agents.map((row) => row.publicId)).size).toBe(2);
    for (const agent of agents) {
      expect([agentCopy, "placed-agent"]).not.toContain(agent.publicId);
      expect(agent.payload.data.id).toBe(agent.publicId);
    }
    const image = copy.elements.find((row) => row.elementType === "image")!;
    expect(pageCopyRoot(image.publicId)).toBe("placed-image");
    // Lineups keep their roots too.
    const lineup = copy.lineups[0]!;
    expect(pageCopyRoot(lineup.publicId)).toBe("item-1");
    expect(pageCopyRoot(lineup.payload.data.origins[0].id)).toBe("origin-1");
  });

  test("copies pages, live content, and images under fresh ids", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);

    await expect(duplicate(owner)).resolves.toEqual({ ok: true });

    type Row = Record<string, any>;
    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
    })) as { header: Row; pages: Row[]; elements: Row[]; lineups: Row[] };
    expect(copy.header).toMatchObject({
      name: "Split A execute (Copy)",
      mapData: "split",
      themeProfileId: "theme-1",
      role: "owner",
    });
    const pages = [...copy.pages].sort((a, b) => a.sortIndex - b.sortIndex);
    expect(pages).toMatchObject([
      {
        name: "Setup",
        isAutoNamed: false,
        isAttack: true,
        sortIndex: 0,
        settings,
      },
      { name: "Retake", isAttack: false, sortIndex: 1 },
    ]);
    const [copyFirstPage, copySecondPage] = pages.map((page) => page.publicId);
    expect([firstPage, secondPage]).not.toContain(copyFirstPage);
    expect([firstPage, secondPage]).not.toContain(copySecondPage);

    // The deleted text element is not copied.
    expect(copy.elements).toHaveLength(2);
    const image = copy.elements.find((row) => row.elementType === "image")!;
    expect(image).toMatchObject({ pagePublicId: copyFirstPage, sortIndex: 3 });
    expect(image.publicId).not.toBe("placed-image");
    expect(image.payload.data).toEqual({
      id: image.publicId,
      elementType: "image",
      scale: 2,
    });

    const agent = copy.elements.find((row) => row.elementType === "agent")!;
    expect(agent.pagePublicId).toBe(copySecondPage);
    expect(agent.publicId).not.toBe("placed-agent");
    expect(agent.payload.data).toEqual({ id: agent.publicId, type: "jett" });

    expect(copy.lineups).toHaveLength(1);
    const lineup = copy.lineups[0]!;
    expect(lineup.pagePublicId).toBe(copySecondPage);
    expect(lineup.payload.kind).toBe("lineups");
    // Fresh ids, still shared where the source shared them (the group, its
    // lineup and its landing keep one id), with each link naming its ends'
    // new ids and each marker following its spot.
    const { id, origins } = lineup.payload.data;
    const originId = origins[0].id;
    expect(lineup.publicId).toBe(id);
    expect(id).not.toBe("item-1");
    expect(originId).not.toBe("origin-1");
    expect(originId).not.toBe(id);
    expect(lineup.payload.data).toEqual({
      id,
      origins: [{ id: originId, agent: { type: "sova", lineUpID: originId } }],
      landings: [{ id, ability: { type: "shock_dart", lineUpID: id } }],
      links: [
        {
          id,
          originId,
          landingId: id,
          name: "Shock dart",
          notes: "Two bounces",
          images: [{ id: "lineup-image" }],
        },
      ],
    });

    expect(await imageUrls(owner, "duplicate-copy")).toEqual({
      [image.publicId]:
        `https://media.duplicate.test/strategies/${source}/placed-image.png`,
      "lineup-image":
        `https://media.duplicate.test/strategies/${source}/lineup-image.png`,
    });

    const summaries = (await owner.query(listStrategies, {})) as Array<{
      publicId: string;
    }>;
    expect(summaries.map((entry) => entry.publicId).sort()).toEqual([
      "duplicate-copy",
      source,
    ]);

    // Copies are new references to the same bytes, never new upload intents.
    const copiedRows = await t.run(async (ctx) => {
      const copyRow = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "duplicate-copy"))
        .unique();
      return await ctx.db
        .query("imageAssets")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", copyRow!._id))
        .collect();
    });
    expect(copiedRows).toHaveLength(2);
    for (const row of copiedRows) {
      expect(row.uploadAttemptPublicId).toBeUndefined();
      expect(row).toMatchObject({
        provider: "r2",
        uploadStatus: "active",
        mimeType: "image/png",
        width: 64,
        height: 32,
      });
    }
  });

  test("deleting the original keeps the copy's images, then deleting the copy frees them", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await duplicate(owner);
    const urlsBefore = await imageUrls(owner, "duplicate-copy");

    await deleteAndSweep(t, owner, source);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(await imageUrls(owner, "duplicate-copy")).toEqual(urlsBefore);

    await deleteAndSweep(t, owner, "duplicate-copy");

    expect(deletedKeys(fetchMock)).toEqual([
      `/duplicate-bucket/strategies/${source}/lineup-image.png`,
      `/duplicate-bucket/strategies/${source}/placed-image.png`,
    ]);
    expect(
      await t.run(async (ctx) => await ctx.db.query("imageAssets").collect()),
    ).toEqual([]);
  });

  test("a lineup group copies whole under new ids, with its shared spots, details and images, and outlives the original", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", source))
        .unique();
      const now = Date.now();
      for (const publicId of ["link-image", "fan-out-image"]) {
        await ctx.db.insert("imageAssets", {
          publicId,
          provider: "r2",
          strategyId: strategy!._id,
          uploadAttemptPublicId: `${publicId}-attempt`,
          objectKey: `strategies/${source}/${publicId}.png`,
          uploadStatus: "active",
          fileExtension: ".png",
          mimeType: "image/png",
          width: 64,
          height: 32,
          byteSize: 100,
          uploadedAt: now,
          createdAt: now,
          updatedAt: now,
        });
      }
    });
    // Two lineups from different origins into one landing (fan-in), and a
    // third from the first one's origin to another landing (fan-out): one
    // group. The shared landing takes the first lineup's id, as a landing
    // made with its lineup does, and the group takes it too. A second group
    // on the page holds one lineup.
    const group = lineupsPayload("link-a", {
      origins: [
        { id: "origin-a", position: { dx: 10, dy: 10 } },
        { id: "origin-b", agentType: "brimstone", position: { dx: 20, dy: 20 } },
      ],
      landings: [
        { id: "link-a", position: { dx: 300, dy: 300 } },
        { id: "landing-c", position: { dx: 500, dy: 500 } },
      ],
      links: [
        {
          id: "link-a",
          originId: "origin-a",
          landingId: "link-a",
          name: "From heaven",
          notes: "Run and throw",
          images: [{ id: "link-image", fileExtension: ".png" }],
        },
        {
          id: "link-b",
          originId: "origin-b",
          landingId: "link-a",
          name: "From mid",
          youtubeLink: "https://youtu.be/b",
        },
        {
          id: "link-c",
          originId: "origin-a",
          landingId: "landing-c",
          name: "Fan out",
          images: [{ id: "fan-out-image", fileExtension: ".png" }],
        },
      ],
    });
    const lone = oneLineupPayload("lone", { name: "Lone" });
    const added = (await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "shared-spots",
      ops: [group, lone].map((payload, index) => ({
        opId: `add-${payload.data.id}`,
        type: "lineup.add",
        lineupPublicId: payload.data.id,
        pagePublicId: firstPage,
        payload,
        sortIndex: 10 + index,
      })),
    })) as { results: Array<{ status: string }> };
    expect(added.results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);

    await duplicate(owner);
    await deleteAndSweep(t, owner, source);

    type Row = {
      publicId: string;
      pagePublicId: string;
      sortIndex: number;
      payload: {
        kind: string;
        payloadVersion: number;
        data: Record<string, any>;
      };
    };
    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
    })) as {
      pages: Array<{ publicId: string; sortIndex: number }>;
      lineups: Row[];
    };
    // These sit on the first page (the seed's group is on the second).
    const copyFirstPage = [...copy.pages].sort(
      (a, b) => a.sortIndex - b.sortIndex,
    )[0]!.publicId;
    const copied = copy.lineups
      .filter((row) => row.pagePublicId === copyFirstPage)
      .sort((a, b) => a.sortIndex - b.sortIndex);
    expect(copied).toHaveLength(2);
    const [copiedGroup, copiedLone] = copied as [Row, Row];

    // Read the new ids off the copy, in the source's order.
    const newIdOf = new Map<string, string>();
    const remember = (sourceId: string, copyId: string) => {
      // One source id always becomes one copy id.
      expect(newIdOf.get(sourceId) ?? copyId).toBe(copyId);
      newIdOf.set(sourceId, copyId);
    };
    for (const [sourcePayload, row] of [
      [group, copiedGroup],
      [lone, copiedLone],
    ] as const) {
      const data = row.payload.data;
      expect(row.publicId).toBe(data.id);
      remember(sourcePayload.data.id, data.id);
      for (const field of ["origins", "landings", "links"] as const) {
        expect(data[field]).toHaveLength(sourcePayload.data[field].length);
        sourcePayload.data[field].forEach((entry, index) =>
          remember(entry.id, data[field][index].id),
        );
      }
    }
    // Ids that were apart stay apart, and none is reused from the source.
    const sourceIds = [...newIdOf.keys()].sort();
    const copyIds = [...newIdOf.values()];
    expect(sourceIds).toEqual([
      "landing-c",
      "link-a",
      "link-b",
      "link-c",
      "lone",
      "lone-landing",
      "lone-origin",
      "origin-a",
      "origin-b",
    ]);
    expect(new Set(copyIds).size).toBe(copyIds.length);
    for (const copyId of copyIds) expect(sourceIds).not.toContain(copyId);

    // Each copy is its source row under the new ids: each link naming its
    // ends' new ids, each marker following its spot, every place, detail
    // and image as it was.
    const renamed = (payload: typeof group) => {
      const id = (old: string) => newIdOf.get(old)!;
      return {
        ...payload,
        data: {
          id: id(payload.data.id),
          origins: payload.data.origins.map((origin) => ({
            ...origin,
            id: id(origin.id),
            agent: { ...origin.agent, lineUpID: id(origin.id) },
          })),
          landings: payload.data.landings.map((landing) => ({
            ...landing,
            id: id(landing.id),
            ability: { ...landing.ability, lineUpID: id(landing.id) },
          })),
          links: payload.data.links.map((link) => ({
            ...link,
            id: id(link.id),
            originId: id(link.originId),
            landingId: id(link.landingId),
          })),
        },
      };
    };
    expect(copiedGroup.payload).toEqual(renamed(group));
    expect(copiedLone.payload).toEqual(renamed(lone));
    // Fan-in and fan-out survive: both lineups into the shared landing name
    // one new id, still the group's and the first lineup's, and both
    // lineups from the shared origin name one new id.
    const links = copiedGroup.payload.data.links;
    expect(links[1].landingId).toBe(links[0].landingId);
    expect(links[0].landingId).toBe(copiedGroup.publicId);
    expect(links[0].id).toBe(copiedGroup.publicId);
    expect(links[2].originId).toBe(links[0].originId);

    // The copy's lineup images are its own references, one per image across
    // every link, and survived the original.
    expect(fetchMock).not.toHaveBeenCalled();
    const urls = await imageUrls(owner, "duplicate-copy");
    expect(urls["link-image"]).toEqual(expect.stringContaining("link-image.png"));
    expect(urls["fan-out-image"]).toEqual(
      expect.stringContaining("fan-out-image.png"),
    );
    const lineupReferences = await t.run(async (ctx) => {
      const copyRow = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "duplicate-copy"))
        .unique();
      return (await ctx.db.query("assetReferences").collect())
        .filter(
          (reference) =>
            reference.strategyId === copyRow!._id &&
            reference.lineupId !== undefined,
        )
        .map((reference) => reference.assetPublicId)
        .sort();
    });
    expect(lineupReferences).toEqual([
      "fan-out-image",
      "lineup-image",
      "link-image",
    ]);

    await deleteAndSweep(t, owner, "duplicate-copy");
    expect(deletedKeys(fetchMock)).toEqual(
      expect.arrayContaining([
        `/duplicate-bucket/strategies/${source}/link-image.png`,
        `/duplicate-bucket/strategies/${source}/fan-out-image.png`,
      ]),
    );
  });

  test("an image whose tombstone is purged is reclaimed once nothing shows it", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await duplicate(owner);

    // The copy's placed image (its own asset row, sharing the source's bytes).
    type Row = Record<string, any>;
    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
    })) as { pages: Row[]; elements: Row[] };
    const copyImage = copy.elements.find((row) => row.elementType === "image")!;
    const copyImagePage = copyImage.pagePublicId as string;

    // Delete the copy's image element, leaving a tombstone.
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
      clientId: "copy-editor",
      ops: [
        {
          opId: "delete-copy-image",
          type: "element.delete",
          elementPublicId: copyImage.publicId,
          pagePublicId: copyImagePage,
          expectedElementRevision: 1,
        },
      ],
    });
    // 31 days later the tombstone is purged.
    vi.setSystemTime(Date.now() + 31 * 24 * 60 * 60 * 1000);
    await t.mutation(purgeOldTombstones, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    // Then the copy's page and the original go.
    const copyRevision = await t.run(async (ctx) => {
      const row = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "duplicate-copy"))
        .unique();
      return row!.revision;
    });
    await owner.mutation(deletePage, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
      pagePublicId: copyImagePage,
      expectedRevision: copyRevision,
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    await deleteAndSweep(t, owner, source);

    // The copy keeps no live row for the image, and its bytes are deleted
    // once no row points at them.
    const copyRows = await t.run(async (ctx) =>
      (await ctx.db.query("imageAssets").collect()).filter(
        (row) =>
          row.publicId === copyImage.publicId && row.uploadStatus !== "deleted",
      ),
    );
    expect(copyRows).toEqual([]);
    expect(deletedKeys(fetchMock)).toContain(
      `/duplicate-bucket/strategies/${source}/placed-image.png`,
    );
  });

  test("a purged tombstone keeps an image a recent tombstone may still restore", async () => {
    vi.useFakeTimers();
    mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    const day = 24 * 60 * 60 * 1000;
    const activeRows = async () =>
      (await t.run(async (ctx) => await ctx.db.query("imageAssets").collect()))
        .filter((row) => row.publicId === "placed-image")
        .map((row) => row.uploadStatus);

    // The placed image is deleted; a month later a lineup shows the same
    // image and is deleted too, so undo could still restore it.
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "editor",
      ops: [
        {
          opId: "delete-placed",
          type: "element.delete",
          elementPublicId: "placed-image",
          pagePublicId: firstPage,
          expectedElementRevision: 1,
        },
      ],
    });
    vi.setSystemTime(Date.now() + 31 * day);
    const showing = oneLineupPayload("late-link", {
      images: [{ id: "placed-image" }],
    });
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "editor",
      ops: [
        {
          opId: "add-late-link",
          type: "lineup.add",
          lineupPublicId: "late-link",
          pagePublicId: firstPage,
          payload: showing,
          sortIndex: 9,
        },
        {
          opId: "delete-late-link",
          type: "lineup.delete",
          lineupPublicId: "late-link",
          pagePublicId: firstPage,
          expectedLineupRevision: 1,
        },
      ],
    });

    // Purging the old element tombstone keeps the image: the lineup's
    // tombstone is still inside its retention window.
    await t.mutation(purgeOldTombstones, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await activeRows()).toEqual(["active"]);

    // Once that tombstone is purged too, the image is reclaimed.
    vi.setSystemTime(Date.now() + 31 * day);
    await t.mutation(purgeOldTombstones, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await activeRows()).not.toContain("active");
  });

  test("deleting the copy leaves the original's images alone", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    const urlsBefore = await imageUrls(owner, source);
    await duplicate(owner);

    await deleteAndSweep(t, owner, "duplicate-copy");

    expect(fetchMock).not.toHaveBeenCalled();
    expect(await imageUrls(owner, source)).toEqual(urlsBefore);
  });

  test("a copy of a copy is one more reference to the same bytes", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await duplicate(owner, "copy-1");
    await owner.mutation(duplicateStrategy, {
      ...protocol,
      sourceStrategyPublicId: "copy-1",
      publicId: "copy-2",
      name: "copy of copy",
    });

    await deleteAndSweep(t, owner, source);
    await deleteAndSweep(t, owner, "copy-1");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(Object.values(await imageUrls(owner, "copy-2"))).toHaveLength(2);

    await deleteAndSweep(t, owner, "copy-2");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("a legacy Convex-storage image survives the original's deletion", async () => {
    vi.useFakeTimers();
    mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    const storageId = await t.run(async (ctx) => {
      const id = await ctx.storage.store(new Blob(["legacy"]));
      const rows = await ctx.db
        .query("imageAssets")
        .withIndex("by_publicId", (q) => q.eq("publicId", "placed-image"))
        .collect();
      await ctx.db.patch(rows[0]!._id, {
        provider: "convex",
        objectKey: undefined,
        storageId: id,
      });
      return id;
    });
    await duplicate(owner);

    await deleteAndSweep(t, owner, source);

    await expect(
      t.run(async (ctx) => (await ctx.storage.get(storageId)) !== null),
    ).resolves.toBe(true);
    const copyUrls = await imageUrls(owner, "duplicate-copy");
    expect(Object.keys(copyUrls)).toHaveLength(2);
    expect(Object.values(copyUrls).every((url) => url !== null)).toBe(true);

    await deleteAndSweep(t, owner, "duplicate-copy");
    await expect(
      t.run(async (ctx) => (await ctx.storage.get(storageId)) === null),
    ).resolves.toBe(true);
  });

  test("images the source cannot show are not copied", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await t.run(async (ctx) => {
      const rows = await ctx.db.query("imageAssets").collect();
      const placed = rows.find((row) => row.publicId === "placed-image")!;
      const lineup = rows.find((row) => row.publicId === "lineup-image")!;
      await ctx.db.patch(placed._id, { uploadStatus: "failed" });
      await ctx.db.patch(lineup._id, { uploadStatus: "deleted" });
    });

    await duplicate(owner);

    expect(await imageUrls(owner, "duplicate-copy")).toEqual({});
  });

  test("an image still uploading refuses the duplicate until it lands", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    const setPlacedStatus = async (uploadStatus: "pending" | "active") =>
      await t.run(async (ctx) => {
        const [placed] = await ctx.db
          .query("imageAssets")
          .withIndex("by_publicId", (q) => q.eq("publicId", "placed-image"))
          .collect();
        await ctx.db.patch(placed!._id, { uploadStatus });
      });
    await setPlacedStatus("pending");

    await expect(duplicate(owner)).rejects.toThrow("still uploading");
    const strategies = await t.run(
      async (ctx) => await ctx.db.query("strategies").collect(),
    );
    expect(strategies.map((row) => row.publicId)).toEqual([source]);

    await setPlacedStatus("active");
    await expect(duplicate(owner)).resolves.toEqual({ ok: true });
    expect(Object.keys(await imageUrls(owner, "duplicate-copy"))).toHaveLength(
      2,
    );
  });

  test("a retried duplicate reuses the copy it already made", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);

    await expect(duplicate(owner)).resolves.toEqual({ ok: true });
    await expect(duplicate(owner)).resolves.toEqual({ ok: true, reused: true });

    const counts = await t.run(async (ctx) => ({
      strategies: (await ctx.db.query("strategies").collect()).length,
      pages: (await ctx.db.query("pages").collect()).length,
      assets: (await ctx.db.query("imageAssets").collect()).length,
    }));
    expect(counts).toEqual({ strategies: 2, pages: 4, assets: 4 });
  });

  test("lands in the caller's folder, or their library root from someone else's", async () => {
    const { t, owner, other } = await createHarness();
    await seedSource(t, owner);
    await owner.mutation(createFolder, {
      ...protocol,
      publicId: "owner-folder",
      name: "Executes",
    });

    await duplicate(owner, "in-folder", { folderPublicId: "owner-folder" });
    const inFolder = (await owner.query(listStrategies, {
      folderPublicId: "owner-folder",
    })) as Array<{ publicId: string }>;
    expect(inFolder.map((entry) => entry.publicId)).toEqual(["in-folder"]);

    await other.mutation(createFolder, {
      ...protocol,
      publicId: "other-folder",
      name: "Not yours",
    });
    // Duplicating while browsing a folder someone shared with you.
    await expect(
      duplicate(owner, "from-shared-folder", {
        folderPublicId: "other-folder",
      }),
    ).resolves.toEqual({ ok: true });
    const atRoot = (await owner.query(listStrategies, {})) as Array<{
      publicId: string;
    }>;
    expect(atRoot.map((entry) => entry.publicId)).toContain(
      "from-shared-folder",
    );
    await expect(
      other.query(listStrategies, { folderPublicId: "other-folder" }),
    ).resolves.toEqual([]);
  });
});

describe("images placed before their upload", () => {
  const createUploadIntent = makeFunctionReference<"mutation">(
    "images:createR2UploadIntent",
  );
  const markUploadActive = makeFunctionReference<"mutation">(
    "images:markR2UploadActive",
  );
  const markStaleUploads = makeFunctionReference<"mutation">(
    "images:markStaleImageUploadsDeleted",
  );

  async function placeImage(owner: Harness, elementPublicId: string) {
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: `place-${elementPublicId}`,
          type: "element.add",
          elementPublicId,
          pagePublicId: firstPage,
          payload: {
            kind: "image",
            payloadVersion: 1,
            data: { id: elementPublicId, elementType: "image" },
          },
          sortIndex: 9,
        },
      ],
    });
  }

  async function rowsFor(t: RootHarness, publicId: string) {
    return await t.run(
      async (ctx) =>
        await ctx.db
          .query("imageAssets")
          .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
          .collect(),
    );
  }

  async function statusFor(user: Harness, publicId: string) {
    const images = (await user.query(listImages, {
      strategyPublicId: source,
    })) as ImageRow[];
    return images.find((image) => image.publicId === publicId) ?? null;
  }

  async function upload(owner: Harness, publicId: string) {
    const intent = (await owner.mutation(createUploadIntent, {
      strategyPublicId: source,
      assetPublicId: publicId,
      objectKey: `strategies/${source}/${publicId}.png`,
      uploadAttemptPublicId: `${publicId}-attempt`,
      mimeType: "image/png",
      fileExtension: ".png",
    })) as { uploadId: string };
    return intent.uploadId;
  }

  test("a duplicate waits for an image whose upload has not started, then copies it", async () => {
    const { t, owner, other } = await createHarness();
    await seedSource(t, owner);
    await owner.mutation(createShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: source,
      token: "late-editor",
      role: "editor",
    });
    await other.mutation(redeemShare, { ...protocol, token: "late-editor" });

    await placeImage(owner, "late-image");

    // Another device sees an image on its way, not a missing one.
    expect(await statusFor(other, "late-image")).toMatchObject({
      uploadStatus: "pending",
      url: null,
    });
    await expect(duplicate(other, "too-early")).rejects.toThrow(
      "still uploading",
    );

    const uploadId = await upload(owner, "late-image");
    const rows = await rowsFor(t, "late-image");
    expect(rows).toHaveLength(1);
    expect(rows[0]!._id).toBe(uploadId);
    await owner.mutation(markUploadActive, {
      strategyPublicId: source,
      assetPublicId: "late-image",
      uploadId,
      byteSize: 100,
      mimeType: "image/png",
      fileExtension: ".png",
    });

    expect((await statusFor(other, "late-image"))?.url).toBe(
      `https://media.duplicate.test/strategies/${source}/late-image.png`,
    );
    await expect(duplicate(other, "after-upload")).resolves.toEqual({
      ok: true,
    });
    const copyUrls = await imageUrls(other, "after-upload");
    expect(Object.values(copyUrls)).toContain(
      `https://media.duplicate.test/strategies/${source}/late-image.png`,
    );
  });

  test("an upload that never comes is swept, and the image reads as unavailable", async () => {
    vi.useFakeTimers();
    mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "never-uploaded");
    expect(await statusFor(owner, "never-uploaded")).toMatchObject({
      uploadStatus: "pending",
    });

    await owner.mutation(markStaleUploads, { staleBefore: Date.now() + 1 });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await rowsFor(t, "never-uploaded")).toEqual([]);
    expect(await statusFor(owner, "never-uploaded")).toBeNull();

    // Moving the image does not bring the spinner back.
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: "move-never-uploaded",
          type: "element.reorder",
          elementPublicId: "never-uploaded",
          pagePublicId: firstPage,
          sortIndex: 10,
          expectedElementRevision: 1,
        },
      ],
    });
    expect(await rowsFor(t, "never-uploaded")).toEqual([]);

    // With nothing on its way, the copy goes ahead without it.
    await expect(duplicate(owner)).resolves.toEqual({ ok: true });
  });

  test("deleting the image clears its placeholder", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "removed-image");
    expect(await rowsFor(t, "removed-image")).toHaveLength(1);

    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: "remove-removed-image",
          type: "element.delete",
          elementPublicId: "removed-image",
          pagePublicId: firstPage,
          expectedElementRevision: 1,
        },
      ],
    });

    expect(await rowsFor(t, "removed-image")).toEqual([]);
  });

  async function deleteImage(owner: Harness, elementPublicId: string) {
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: `delete-${elementPublicId}`,
          type: "element.delete",
          elementPublicId,
          pagePublicId: firstPage,
          expectedElementRevision: 1,
        },
      ],
    });
  }

  async function restoreImage(owner: Harness, elementPublicId: string) {
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: `restore-${elementPublicId}`,
          type: "element.add",
          elementPublicId,
          pagePublicId: firstPage,
          payload: {
            kind: "image",
            payloadVersion: 1,
            data: { id: elementPublicId, elementType: "image" },
          },
          sortIndex: 9,
          expectedElementRevision: 2,
        },
      ],
    });
  }

  test("undoing a fresh delete expects the image again", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "undone-image");
    await deleteImage(owner, "undone-image");
    expect(await rowsFor(t, "undone-image")).toEqual([]);

    // Its upload may still be coming from the device that placed it.
    await restoreImage(owner, "undone-image");

    expect(await statusFor(owner, "undone-image")).toMatchObject({
      uploadStatus: "pending",
    });
  });

  test("undoing the delete of an image placed over a day ago adds no placeholder", async () => {
    vi.useFakeTimers();
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "old-image");
    await deleteImage(owner, "old-image");

    vi.setSystemTime(Date.now() + 25 * 60 * 60 * 1000);
    await restoreImage(owner, "old-image");

    // Any upload would have landed or been swept by now; it reads as
    // unavailable at once instead of spinning for another day.
    expect(await rowsFor(t, "old-image")).toEqual([]);
  });

  test("undoing a delete keeps using an image that was uploaded", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);

    // placed-image is uploaded (seeded active); deleting leaves its row.
    await deleteImage(owner, "placed-image");
    await restoreImage(owner, "placed-image");

    const rows = await rowsFor(t, "placed-image");
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ uploadStatus: "active" });
  });

  test("deleting an image keeps the placeholder while a lineup still shows it", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "link-late-image");
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: "link-shows-shared",
          type: "lineup.add",
          lineupPublicId: "link-shows-shared",
          pagePublicId: firstPage,
          payload: oneLineupPayload("link-shows-shared", {
            images: [{ id: "link-late-image", fileExtension: ".png" }],
          }),
          sortIndex: 2,
        },
      ],
    });
    expect(await rowsFor(t, "link-late-image")).toHaveLength(1);

    await deleteImage(owner, "link-late-image");

    expect(await statusFor(owner, "link-late-image")).toMatchObject({
      uploadStatus: "pending",
    });
    await expect(duplicate(owner)).rejects.toThrow("still uploading");
  });

  test("a lineup added later in the same batch keeps a deleted image's placeholder", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "pending-a");
    await placeImage(owner, "pending-b");

    // One batch: delete A, add a lineup that shows B, then delete placed B.
    const response = (await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: "delete-a",
          type: "element.delete",
          elementPublicId: "pending-a",
          pagePublicId: firstPage,
          expectedElementRevision: 1,
        },
        {
          opId: "link-shows-b",
          type: "lineup.add",
          lineupPublicId: "shows-b",
          pagePublicId: firstPage,
          payload: oneLineupPayload("shows-b", {
            images: [{ id: "pending-b", fileExtension: ".png" }],
          }),
          sortIndex: 5,
        },
        {
          opId: "delete-b",
          type: "element.delete",
          elementPublicId: "pending-b",
          pagePublicId: firstPage,
          expectedElementRevision: 1,
        },
      ],
    })) as { results: Array<{ status: string }> };
    expect(response.results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);

    // A is shown by nothing: its placeholder goes. B is still shown by the
    // new lineup: its placeholder stays, so a duplicate waits for B.
    expect(await rowsFor(t, "pending-a")).toEqual([]);
    expect(await statusFor(owner, "pending-b")).toMatchObject({
      uploadStatus: "pending",
    });
    await expect(duplicate(owner)).rejects.toThrow("still uploading");
  });

  test("deleting several images in one batch checks lineups for each", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await placeImage(owner, "batch-shown");
    await placeImage(owner, "batch-alone");
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: "lineup-shows-batch",
          type: "lineup.add",
          lineupPublicId: "lineup-shows-batch",
          pagePublicId: firstPage,
          payload: oneLineupPayload("lineup-shows-batch", {
            images: [{ id: "batch-shown" }],
          }),
          sortIndex: 3,
        },
      ],
    });

    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: ["batch-shown", "batch-alone"].map((elementPublicId) => ({
        opId: `batch-delete-${elementPublicId}`,
        type: "element.delete",
        elementPublicId,
        pagePublicId: firstPage,
        expectedElementRevision: 1,
      })),
    });

    expect(await rowsFor(t, "batch-shown")).toHaveLength(1);
    expect(await rowsFor(t, "batch-alone")).toEqual([]);
  });

  test("a lineup's image referenced before its upload is expected too", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "slow-uploader",
      ops: [
        {
          opId: "late-link",
          type: "lineup.add",
          lineupPublicId: "late-link",
          pagePublicId: firstPage,
          payload: oneLineupPayload("late-link", {
            images: [{ id: "late-link-image", fileExtension: ".png" }],
          }),
          sortIndex: 1,
        },
      ],
    });

    expect(await statusFor(owner, "late-link-image")).toMatchObject({
      uploadStatus: "pending",
    });
    await expect(duplicate(owner)).rejects.toThrow("still uploading");
  });

  test("an image that already has bytes gets no placeholder", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    // Legacy rows carry no strategy id.
    await t.run(async (ctx) => {
      await ctx.db.insert("imageAssets", {
        publicId: "legacy-image",
        provider: "r2",
        objectKey: "legacy/legacy-image.png",
        uploadStatus: "active",
        createdAt: 1,
        updatedAt: 1,
      });
    });

    await placeImage(owner, "legacy-image");

    expect(await rowsFor(t, "legacy-image")).toHaveLength(1);
    expect((await statusFor(owner, "legacy-image"))?.url).toBe(
      "https://media.duplicate.test/legacy/legacy-image.png",
    );
  });
});

describe("strategies:duplicate access", () => {
  async function share(owner: Harness, user: Harness, role: string) {
    await owner.mutation(createShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: source,
      token: `${role}-token`,
      role,
    });
    await user.mutation(redeemShare, { ...protocol, token: `${role}-token` });
  }

  test("a stranger cannot duplicate", async () => {
    const { t, owner, other } = await createHarness();
    await seedSource(t, owner);
    await expect(duplicate(other)).rejects.toThrow("Forbidden");
  });

  test("a viewer cannot duplicate, matching the library's Duplicate action", async () => {
    const { t, owner, other } = await createHarness();
    await seedSource(t, owner);
    await share(owner, other, "viewer");
    await expect(duplicate(other)).rejects.toThrow("Forbidden");
  });

  test("an editor duplicates into their own library with working images", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner, other } = await createHarness();
    await seedSource(t, owner);
    await share(owner, other, "editor");

    await duplicate(other, "editor-copy");

    const owned = (await other.query(listStrategies, {
      scope: "owned",
    })) as Array<{ publicId: string; role: string }>;
    expect(owned).toMatchObject([{ publicId: "editor-copy", role: "owner" }]);
    await expect(
      owner.query(getFullSnapshot, {
        ...protocol,
        strategyPublicId: "editor-copy",
      }),
    ).rejects.toThrow("Forbidden");

    await deleteAndSweep(t, owner, source);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(Object.keys(await imageUrls(other, "editor-copy"))).toHaveLength(2);
  });

  test("a publicId another user owns is a conflict", async () => {
    const { t, owner, other } = await createHarness();
    await seedSource(t, owner);
    await other.mutation(createStrategy, {
      ...protocol,
      publicId: "taken",
      name: "Someone else's",
      mapData: "ascent",
      initialPagePublicId: "taken-page",
      initialPageName: "Page 1",
      initialPageIsAttack: true,
    });
    await expect(duplicate(owner, "taken")).rejects.toThrow(
      "Strategy publicId already exists",
    );
  });
});

describe('"+": a page added as a copy of another', () => {
  type Row = Record<string, any>;

  async function strategyRevision(t: RootHarness) {
    return await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", source))
        .unique();
      return strategy!.revision;
    });
  }

  /// Adds `pagePublicId` after page 2, copying `from`, as "+" does.
  async function addCopyOf(
    t: RootHarness,
    owner: Harness,
    from: string,
    pagePublicId: string,
    opId = `add-${pagePublicId}`,
  ) {
    const { results } = (await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "plus",
      ops: [
        {
          opId,
          type: "page.add",
          pagePublicId,
          payload: { name: "Page 3", isAutoNamed: true, isAttack: true },
          sortIndex: 2,
          expectedStrategyRevision: await strategyRevision(t),
          copyContentFromPagePublicId: from,
        },
      ],
    })) as { results: Row[] };
    return results[0]!;
  }

  async function snapshot(owner: Harness) {
    return (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: source,
      acceptsTrashedPagesLeftOut: true,
    })) as { pages: Row[]; elements: Row[]; lineups: Row[] };
  }

  /// The live rows on a page.
  const onPage = (rows: Row[], pagePublicId: string) =>
    rows.filter((row) => row.pagePublicId === pagePublicId && !row.deleted);

  test("copies the page's live items under copy ids as the page is added", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);

    expect(await addCopyOf(t, owner, firstPage, "copy-of-1")).toMatchObject({
      status: "applied",
    });
    expect(await addCopyOf(t, owner, secondPage, "copy-of-2")).toMatchObject({
      status: "applied",
    });

    const after = await snapshot(owner);
    expect(after.pages.map((page) => page.publicId)).toEqual(
      expect.arrayContaining(["copy-of-1", "copy-of-2"]),
    );
    // Page 1's image, without the text deleted before the copy.
    const [image, ...otherOnOne] = onPage(after.elements, "copy-of-1");
    expect(otherOnOne).toEqual([]);
    expect(pageCopyRoot(image!.publicId)).toBe("placed-image");
    expect(image!.publicId).not.toBe("placed-image");
    expect(image!.payload.data).toEqual({
      id: image!.publicId,
      elementType: "image",
      scale: 2,
    });
    expect(image!.sortIndex).toBe(3);
    // Page 2's agent and lineup group, its ids renamed together.
    const [agent] = onPage(after.elements, "copy-of-2");
    expect(pageCopyRoot(agent!.publicId)).toBe("placed-agent");
    expect(agent!.payload.data).toEqual({ id: agent!.publicId, type: "jett" });
    const [lineup, ...otherLineups] = onPage(after.lineups, "copy-of-2");
    expect(otherLineups).toEqual([]);
    const { id, origins } = lineup!.payload.data;
    expect(pageCopyRoot(id)).toBe("item-1");
    expect(lineup!.publicId).toBe(id);
    expect(pageCopyRoot(origins[0].id)).toBe("origin-1");
    expect(lineup!.payload.data.links).toEqual([
      {
        id,
        originId: origins[0].id,
        landingId: id,
        name: "Shock dart",
        notes: "Two bounces",
        images: [{ id: "lineup-image" }],
      },
    ]);
    // The pages copied from are as they were.
    expect(
      onPage(after.elements, firstPage).map((row) => row.publicId),
    ).toEqual(["placed-image"]);
    expect(onPage(after.lineups, secondPage).map((row) => row.publicId)).toEqual(
      ["item-1"],
    );

    // The placed image's copy shows the same bytes under its own asset row;
    // the lineup's image is the strategy's one asset.
    const placedUrl = `https://media.duplicate.test/strategies/${source}/placed-image.png`;
    expect(await imageUrls(owner, source)).toEqual({
      "placed-image": placedUrl,
      [image!.publicId]: placedUrl,
      "lineup-image": `https://media.duplicate.test/strategies/${source}/lineup-image.png`,
    });
    // The copy's rows are kept like any other: its image references, and
    // its lineup's agents and items.
    const kept = await t.run(async (ctx) => {
      const copiedLineup = (await ctx.db.query("lineups").collect()).find(
        (row) => row.publicId === id,
      )!;
      const copiedImage = (await ctx.db.query("elements").collect()).find(
        (row) => row.publicId === image!.publicId,
      )!;
      const references = await ctx.db.query("assetReferences").collect();
      return {
        imageReferences: references
          .filter((ref) => ref.elementId === copiedImage._id)
          .map((ref) => ref.assetPublicId),
        lineupReferences: references
          .filter((ref) => ref.lineupId === copiedLineup._id)
          .map((ref) => ref.assetPublicId),
        agents: (await ctx.db.query("lineupAgents").collect())
          .filter((row) => row.lineupId === copiedLineup._id)
          .map((row) => row.agentType),
        items: (await ctx.db.query("lineupItems").collect()).filter(
          (row) => row.lineupId === copiedLineup._id,
        ).length,
      };
    });
    expect(kept).toEqual({
      imageReferences: [image!.publicId],
      lineupReferences: ["lineup-image"],
      agents: ["sova"],
      items: 3,
    });
  });

  test("a retried add copies once", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);

    await addCopyOf(t, owner, secondPage, "copy-of-2", "plus-1");
    expect(
      await addCopyOf(t, owner, secondPage, "copy-of-2", "plus-1"),
    ).toMatchObject({ status: "noop" });

    const after = await snapshot(owner);
    expect(onPage(after.elements, "copy-of-2")).toHaveLength(1);
    expect(onPage(after.lineups, "copy-of-2")).toHaveLength(1);
  });

  test("an image still uploading is left out, and the rest copied", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await t.run(async (ctx) => {
      const [placed] = await ctx.db
        .query("imageAssets")
        .withIndex("by_publicId", (q) => q.eq("publicId", "placed-image"))
        .collect();
      await ctx.db.patch(placed!._id, { uploadStatus: "pending" });
    });
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "seed-text",
      ops: [
        {
          opId: "add-text",
          type: "element.add",
          elementPublicId: "kept-text",
          pagePublicId: firstPage,
          payload: {
            kind: "text",
            payloadVersion: 1,
            data: { id: "kept-text", text: "here" },
          },
          sortIndex: 5,
        },
      ],
    });

    expect(await addCopyOf(t, owner, firstPage, "copy-of-1")).toMatchObject({
      status: "applied",
    });

    const copied = onPage((await snapshot(owner)).elements, "copy-of-1");
    expect(copied.map((row) => pageCopyRoot(row.publicId))).toEqual([
      "kept-text",
    ]);
  });

  test("a page gone by the time the add lands leaves the new page empty", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    await owner.mutation(deletePage, {
      ...protocol,
      strategyPublicId: source,
      pagePublicId: secondPage,
      expectedRevision: await strategyRevision(t),
    });

    expect(await addCopyOf(t, owner, secondPage, "copy-of-2")).toMatchObject({
      status: "applied",
    });

    const after = await snapshot(owner);
    expect(after.pages.map((page) => page.publicId)).toContain("copy-of-2");
    expect(onPage(after.elements, "copy-of-2")).toEqual([]);
    expect(onPage(after.lineups, "copy-of-2")).toEqual([]);
  });

  test("a page too large to copy is refused, leaving nothing of the add", async () => {
    const { t, owner } = await createHarness();
    await seedSource(t, owner);
    // 18 rows of 700 KiB: past the copy's 12 MiB budget.
    await t.run(async (ctx) => {
      const page = await ctx.db
        .query("pages")
        .withIndex("by_publicId", (q) => q.eq("publicId", firstPage))
        .unique();
      const now = Date.now();
      for (let index = 0; index < 18; index += 1) {
        await ctx.db.insert("elements", {
          publicId: `big-${index}`,
          strategyId: page!.strategyId,
          pageId: page!._id,
          elementType: "drawing",
          payloadKind: "drawing",
          payloadVersion: 1,
          payload: {
            kind: "drawing",
            payloadVersion: 1,
            data: { id: `big-${index}`, points: "x".repeat(700 * 1024) },
          },
          sortIndex: 10 + index,
          revision: 1,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        });
      }
    });
    const revisionBefore = await strategyRevision(t);

    expect(await addCopyOf(t, owner, firstPage, "copy-of-1")).toMatchObject({
      status: "failed",
      code: "PAGE_TOO_LARGE_TO_COPY",
    });

    const after = await snapshot(owner);
    expect(after.pages.map((page) => page.publicId).sort()).toEqual(
      [firstPage, secondPage].sort(),
    );
    expect(after.pages.map((page) => page.sortIndex).sort()).toEqual([0, 1]);
    expect(await strategyRevision(t)).toBe(revisionBefore);
  });
});
