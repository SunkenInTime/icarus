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
import { isSafeFileNameId } from "./lib/fileNameIds";
import { serializeAssetForViewer } from "./lib/imageAssets";
import schema from "./schema";
import { modules } from "./test.setup";

// The desktop app saves a cloud strategy's images as
// `<strategy publicId>/<image publicId><extension>`. These tests pin that
// nobody can make those names reach outside that folder, or end in anything
// but an image type, on the computers of the people they share with.

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const duplicateStrategy = makeFunctionReference<"mutation">(
  "strategies:duplicate",
);
const generateUploadUrl = makeFunctionReference<"action">(
  "images:generateUploadUrl",
);
const completeUpload = makeFunctionReference<"action">("images:completeUpload");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const strategyPublicId = "6d0f1c1e-3a43-4a8e-9a55-2f4b8c7d9e10";
const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

const unsafeIds = [
  "..\\..\\..\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\x",
  "../../.config/autostart/x",
  "C:\\Users\\Public\\x",
  "C:x",
  "/etc/x",
  "..",
  ".",
  "",
  "a\u0000b",
  "x".repeat(201),
];

async function createHarness(): Promise<{ t: RootHarness; owner: Harness }> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity({
    issuer: "https://file-names.test",
    subject: "owner",
    tokenIdentifier: "file-names|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  return { t, owner };
}

async function seedStrategy(owner: Harness, publicId = strategyPublicId) {
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId,
    name: "File names",
    mapData: "ascent",
    initialPagePublicId: `${publicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

/// R2 answers a completion's HEAD with the bytes the client uploaded.
function mockR2(contentType: string) {
  const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) =>
    init?.method === "HEAD"
      ? new Response(null, {
          status: 200,
          headers: { "content-type": contentType, "content-length": "68" },
        })
      : new Response(null, { status: 204 }),
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "file-names-account";
  process.env.R2_BUCKET = "file-names-bucket";
  process.env.R2_ACCESS_KEY_ID = "file-names-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "file-names-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://assets.file-names.test";
  process.env.R2_S3_ENDPOINT = "https://file-names.r2.test";
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("image file names", () => {
  test("every id a shipped build makes is a safe file name; path-like ids are not", () => {
    for (const id of [
      strategyPublicId,
      `${strategyPublicId}~cp1~0b5f8d3a-1c2e-4f6a-8b9c-0d1e2f3a4b5c`,
      "image_1",
      "my image (2)",
      "a..b",
    ]) {
      expect(isSafeFileNameId(id), id).toBe(true);
    }
    for (const id of unsafeIds) {
      expect(isSafeFileNameId(id), JSON.stringify(id)).toBe(false);
    }
  });

  test("an upload can't start under an id that would leave the images folder", async () => {
    const { owner } = await createHarness();
    await seedStrategy(owner);
    for (const assetPublicId of unsafeIds) {
      await expect(
        owner.action(generateUploadUrl, {
          ...protocol,
          strategyPublicId,
          assetPublicId,
          mimeType: "image/png",
          fileExtension: ".png",
        }),
        JSON.stringify(assetPublicId),
      ).rejects.toThrow(/file name/);
    }
  });

  test("a finished upload keeps an image extension, whatever the caller sends", async () => {
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const fetchMock = mockR2("image/png");
    const startUpload = async (assetPublicId: string) =>
      (await owner.action(generateUploadUrl, {
        ...protocol,
        strategyPublicId,
        assetPublicId,
        mimeType: "image/png",
        fileExtension: ".png",
      })) as { uploadId: string };

    const renamed = await startUpload("renamed");
    await expect(
      owner.action(completeUpload, {
        ...protocol,
        strategyPublicId,
        assetPublicId: "renamed",
        uploadId: renamed.uploadId,
        fileExtension: ".bat",
        mimeType: "image/png",
      }),
    ).rejects.toThrow(/size or MIME/);
    // Refused like any bad upload: the object goes, and the row says failed.
    expect(
      fetchMock.mock.calls.some(([, init]) => init?.method === "DELETE"),
    ).toBe(true);

    const honest = await startUpload("honest");
    await owner.action(completeUpload, {
      ...protocol,
      strategyPublicId,
      assetPublicId: "honest",
      uploadId: honest.uploadId,
      fileExtension: "png",
    });

    const rows = await t.run(
      async (ctx) => await ctx.db.query("imageAssets").collect(),
    );
    expect(
      rows.map(({ publicId, uploadStatus, fileExtension }) => ({
        publicId,
        uploadStatus,
        fileExtension,
      })),
    ).toEqual([
      { publicId: "renamed", uploadStatus: "failed", fileExtension: ".png" },
      { publicId: "honest", uploadStatus: "active", fileExtension: ".png" },
    ]);
  });

  test("a legacy completion can't name an id or extension that isn't an image file", async () => {
    const { owner } = await createHarness();
    await seedStrategy(owner);
    await expect(
      owner.action(completeUpload, {
        ...protocol,
        strategyPublicId,
        assetPublicId: "..\\..\\x",
        provider: "convex",
        fileExtension: ".png",
      }),
    ).rejects.toThrow(/file name/);
    await expect(
      owner.action(completeUpload, {
        ...protocol,
        strategyPublicId,
        assetPublicId: "legacy",
        provider: "convex",
        fileExtension: ".bat",
      }),
    ).rejects.toThrow(/Unsupported image extension/);
  });

  test("a strategy can't be created or duplicated under an id that would leave the app's folder", async () => {
    const { owner } = await createHarness();
    for (const publicId of unsafeIds) {
      await expect(
        seedStrategy(owner, publicId),
        JSON.stringify(publicId),
      ).rejects.toThrow(/file name/);
    }
    await seedStrategy(owner);
    await expect(
      owner.mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "..\\..\\copy",
        name: "Copy",
      }),
    ).rejects.toThrow(/file name/);
  });

  test("a row that isn't a safe image file is never handed out to download", async () => {
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const served = await t.run(async (ctx) => {
      const strategy = (await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .unique())!;
      const now = Date.now();
      const row = (publicId: string, fileExtension: string | undefined) => ({
        publicId,
        provider: "r2" as const,
        strategyId: strategy._id,
        objectKey: `strategies/${publicId}`,
        uploadStatus: "active" as const,
        fileExtension,
        createdAt: now,
        updatedAt: now,
      });
      const ids = [
        await ctx.db.insert("imageAssets", row("fine", ".png")),
        await ctx.db.insert("imageAssets", row("script", ".bat")),
        await ctx.db.insert("imageAssets", row("..\\..\\x", ".png")),
        // Rows from before extensions were recorded have none.
        await ctx.db.insert("imageAssets", row("legacy", undefined)),
        // An image whose upload hasn't arrived stays "on its way".
        await ctx.db.insert("imageAssets", {
          publicId: "placeholder",
          strategyId: strategy._id,
          uploadStatus: "pending",
          createdAt: now,
          updatedAt: now,
        }),
      ];
      return await Promise.all(
        ids.map(async (id) =>
          serializeAssetForViewer(ctx, (await ctx.db.get(id))!),
        ),
      );
    });
    expect(
      served.map(({ publicId, uploadStatus, url }) => ({
        publicId,
        uploadStatus,
        hasUrl: url !== null,
      })),
    ).toEqual([
      { publicId: "fine", uploadStatus: "active", hasUrl: true },
      { publicId: "script", uploadStatus: "failed", hasUrl: false },
      { publicId: "..\\..\\x", uploadStatus: "failed", hasUrl: false },
      { publicId: "legacy", uploadStatus: "active", hasUrl: true },
      { publicId: "placeholder", uploadStatus: "pending", hasUrl: false },
    ]);
  });
});
