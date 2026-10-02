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
import { lineupPayload } from "./testContent.helpers";
import { modules } from "./test.setup";

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

const seedLineupData = {
  id: "item-1",
  name: "Shock dart",
  notes: "Two bounces",
  images: [{ id: "lineup-image" }],
  origin: {
    id: "origin-1",
    agent: { type: "sova", lineUpID: "origin-1" },
  },
  landing: {
    id: "item-1",
    ability: { type: "shock_dart", lineUpID: "item-1" },
  },
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
      // One lineup showing an image. Its landing shares the lineup's id, as
      // landings made with their lineup do.
      {
        opId: "add-lineup",
        type: "lineup.add",
        lineupPublicId: "item-1",
        pagePublicId: secondPage,
        payload: {
          kind: "lineup",
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
    expect(lineup.payload.kind).toBe("lineup");
    // Fresh ids, still shared where the source shared them (the landing
    // keeps the lineup's id), with each marker following its end.
    const { id, origin, landing } = lineup.payload.data;
    expect(lineup.publicId).toBe(id);
    expect(id).not.toBe("item-1");
    expect(origin.id).not.toBe("origin-1");
    expect(landing.id).toBe(id);
    expect(lineup.payload.data).toEqual({
      id,
      name: "Shock dart",
      notes: "Two bounces",
      images: [{ id: "lineup-image" }],
      origin: {
        id: origin.id,
        agent: { type: "sova", lineUpID: origin.id },
      },
      landing: {
        id,
        ability: { type: "shock_dart", lineUpID: id },
      },
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

  test("lineups that share spots copy with their sharing, details and image, and outlive the original", async () => {
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
      await ctx.db.insert("imageAssets", {
        publicId: "link-image",
        provider: "r2",
        strategyId: strategy!._id,
        uploadAttemptPublicId: "link-image-attempt",
        objectKey: `strategies/${source}/link-image.png`,
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
    });
    // Two lineups from different origins into one landing (fan-in), and a
    // third from the first one's origin to another landing (fan-out). The
    // shared landing takes the first lineup's id, as a landing made with its
    // lineup does.
    const rows = [
      lineupPayload("link-a", {
        originId: "origin-a",
        landingId: "link-a",
        name: "From heaven",
        notes: "Run and throw",
        images: [{ id: "link-image", fileExtension: ".png" }],
      }),
      lineupPayload("link-b", {
        originId: "origin-b",
        landingId: "link-a",
        name: "From mid",
      }),
      lineupPayload("link-c", {
        originId: "origin-a",
        landingId: "landing-c",
        name: "Fan out",
      }),
    ];
    const added = (await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: source,
      clientId: "shared-spots",
      ops: rows.map((payload, index) => ({
        opId: `add-${payload.data.id}`,
        type: "lineup.add",
        lineupPublicId: payload.data.id,
        pagePublicId: firstPage,
        payload,
        sortIndex: 10 + index,
      })),
    })) as { results: Array<{ status: string }> };
    expect(added.results.map((result) => result.status)).toEqual(
      rows.map(() => "applied"),
    );

    await duplicate(owner);
    await deleteAndSweep(t, owner, source);

    type Row = {
      publicId: string;
      pagePublicId: string;
      sortIndex: number;
      payload: { kind: string; data: Record<string, any> };
    };
    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: "duplicate-copy",
    })) as { pages: Array<{ publicId: string; sortIndex: number }>; lineups: Row[] };
    // These sit on the first page (the seed's lineup is on the second).
    const copyFirstPage = [...copy.pages].sort((a, b) => a.sortIndex - b.sortIndex)[0]!
      .publicId;
    const copied = copy.lineups
      .filter((row) => row.pagePublicId === copyFirstPage)
      .sort((a, b) => a.sortIndex - b.sortIndex);
    expect(copied.map((row) => row.payload.data.name)).toEqual([
      "From heaven",
      "From mid",
      "Fan out",
    ]);
    const oldIds = [
      "link-a",
      "link-b",
      "link-c",
      "origin-a",
      "origin-b",
      "landing-c",
    ];
    for (const row of copied) {
      const { id, origin, landing } = row.payload.data;
      // Each row is keyed by its new lineup id.
      expect(row.publicId).toBe(id);
      for (const newId of [id, origin.id, landing.id]) {
        expect(oldIds).not.toContain(newId);
      }
      // Each marker follows its end's new id.
      expect(origin.agent.lineUpID).toBe(origin.id);
      expect(landing.ability.lineUpID).toBe(landing.id);
    }
    const [heaven, mid, fanOut] = copied.map((row) => row.payload.data);
    // Fan-in survives: one new landing id, still the first lineup's id.
    expect(mid!.landing.id).toBe(heaven!.landing.id);
    expect(heaven!.landing.id).toBe(heaven!.id);
    // Fan-out survives: one new origin id for both lineups from it.
    expect(fanOut!.origin.id).toBe(heaven!.origin.id);
    // And spots that were apart stay apart.
    expect(mid!.origin.id).not.toBe(heaven!.origin.id);
    expect(fanOut!.landing.id).not.toBe(heaven!.landing.id);
    expect(new Set(copied.map((row) => row.publicId)).size).toBe(3);
    // Details and the image come along.
    expect(heaven).toMatchObject({
      notes: "Run and throw",
      youtubeLink: "",
      images: [{ id: "link-image", fileExtension: ".png" }],
    });
    expect(mid!.images).toEqual([]);

    // The copy's lineup image is its own reference and survived the
    // original.
    expect(fetchMock).not.toHaveBeenCalled();
    const urls = await imageUrls(owner, "duplicate-copy");
    expect(urls["link-image"]).toEqual(expect.stringContaining("link-image.png"));
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
    expect(lineupReferences).toEqual(["lineup-image", "link-image"]);

    await deleteAndSweep(t, owner, "duplicate-copy");
    expect(deletedKeys(fetchMock)).toContain(
      `/duplicate-bucket/strategies/${source}/link-image.png`,
    );
  });

  test("a duplicate copies each lineup row exactly, even where rows sharing a spot disagree on it", async () => {
    const { owner } = await createHarness();
    const exact = "exact-source";
    const exactPage = "exact-source-page";
    await owner.mutation(createStrategy, {
      ...protocol,
      publicId: exact,
      name: "Exact",
      mapData: "split",
      initialPagePublicId: exactPage,
      initialPageName: "Setup",
      initialPageIsAttack: true,
    });
    // A and B land in one spot but their rows hold it in different places;
    // A and C start from one origin, also held in different places. C's
    // landing shares C's id. Each row is drawn from its own copy, so the
    // duplicate must carry every row over as it is, whatever the new ids.
    const rows = [
      lineupPayload("lineup-a", {
        originId: "origin-a",
        landingId: "spot",
        originPosition: { dx: 10, dy: 10 },
        landingPosition: { dx: 300, dy: 300 },
        name: "A",
        notes: "Jump throw",
      }),
      lineupPayload("lineup-b", {
        originId: "origin-b",
        landingId: "spot",
        agentType: "brimstone",
        originPosition: { dx: 20, dy: 20 },
        landingPosition: { dx: 100, dy: 100 },
        name: "B",
        youtubeLink: "https://youtu.be/b",
      }),
      lineupPayload("lineup-c", {
        originId: "origin-a",
        landingId: "lineup-c",
        originPosition: { dx: 40, dy: 40 },
        landingPosition: { dx: 500, dy: 500 },
        name: "C",
      }),
    ];
    const added = (await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId: exact,
      clientId: "exact",
      ops: rows.map((payload, index) => ({
        opId: `add-${payload.data.id}`,
        type: "lineup.add",
        lineupPublicId: payload.data.id,
        pagePublicId: exactPage,
        payload,
        sortIndex: index,
      })),
    })) as { results: Array<{ status: string }> };
    expect(added.results.map((result) => result.status)).toEqual(
      rows.map(() => "applied"),
    );

    await owner.mutation(duplicateStrategy, {
      ...protocol,
      sourceStrategyPublicId: exact,
      publicId: "exact-copy",
      name: "Exact (Copy)",
    });
    type Row = { publicId: string; payload: { data: Record<string, any> } };
    const copied = (
      (await owner.query(getFullSnapshot, {
        ...protocol,
        strategyPublicId: "exact-copy",
      })) as { lineups: Row[] }
    ).lineups;
    expect(copied.map((row) => row.payload.data.name).sort()).toEqual([
      "A",
      "B",
      "C",
    ]);

    // Pair each source row with its copy and read off the new ids.
    const newIdOf = new Map<string, string>();
    const remember = (sourceId: string, copyId: string) => {
      // One source id always becomes one copy id.
      expect(newIdOf.get(sourceId) ?? copyId).toBe(copyId);
      newIdOf.set(sourceId, copyId);
    };
    const pairs = rows.map((sourcePayload) => {
      const copy = copied.find(
        (row) => row.payload.data.name === sourcePayload.data.name,
      )!;
      const data = copy.payload.data;
      expect(copy.publicId).toBe(data.id);
      remember(sourcePayload.data.id, data.id);
      remember(sourcePayload.data.origin.id, data.origin.id);
      remember(sourcePayload.data.landing.id, data.landing.id);
      return { sourcePayload, copy };
    });
    // Ids that were apart stay apart, and none is reused from the source.
    const sourceIds = [...newIdOf.keys()].sort();
    const copyIds = [...newIdOf.values()];
    expect(sourceIds).toEqual(
      ["lineup-a", "lineup-b", "lineup-c", "origin-a", "origin-b", "spot"],
    );
    expect(new Set(copyIds).size).toBe(copyIds.length);
    for (const copyId of copyIds) expect(sourceIds).not.toContain(copyId);

    // Each copy is its source row under the new ids, each marker following
    // its end, every place and detail as it was.
    for (const { sourcePayload, copy } of pairs) {
      const data = sourcePayload.data;
      const originId = newIdOf.get(data.origin.id)!;
      const landingId = newIdOf.get(data.landing.id)!;
      expect(copy.payload).toEqual({
        ...sourcePayload,
        data: {
          ...data,
          id: newIdOf.get(data.id)!,
          origin: {
            ...data.origin,
            id: originId,
            agent: { ...data.origin.agent, lineUpID: originId },
          },
          landing: {
            ...data.landing,
            id: landingId,
            ability: { ...data.landing.ability, lineUpID: landingId },
          },
        },
      });
    }
    // So the copy's shared spot disagrees exactly as the original's did.
    const [copyA, copyB] = pairs.map((pair) => pair.copy.payload.data);
    expect(copyA!.landing.id).toBe(copyB!.landing.id);
    expect(copyA!.landing.ability.position).toEqual({ dx: 300, dy: 300 });
    expect(copyB!.landing.ability.position).toEqual({ dx: 100, dy: 100 });
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
    const showing = lineupPayload("late-link", {
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
          payload: lineupPayload("link-shows-shared", {
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
          payload: lineupPayload("shows-b", {
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
          payload: lineupPayload("lineup-shows-batch", {
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
          payload: lineupPayload("late-link", {
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
