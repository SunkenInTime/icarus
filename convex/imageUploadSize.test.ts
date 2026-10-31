import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { beforeAll, describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import { getR2Config, presignR2PutUrl } from "./lib/r2";
import schema from "./schema";
import { modules } from "./test.setup";

// The image limit holds at the PUT because the upload URL is signed for one
// exact length. R2 refusing a wrong length was seen against the real bucket;
// these tests pin the two things that depends on: the length is in the
// signature, and no URL is handed out without one.

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const generateUploadUrl = makeFunctionReference<"action">(
  "images:generateUploadUrl",
);

const strategyPublicId = "4f1f2c6e-7a33-4d0b-8c11-9e0a5b6c7d80";
const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const maxImageBytes = 15 * 1024 * 1024;

async function createHarness(): Promise<{
  t: TestConvexForDataModelAndIdentity<DataModel>;
  owner: TestConvexForDataModel<DataModel>;
}> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity({
    issuer: "https://upload-size.test",
    subject: "owner",
    tokenIdentifier: "upload-size|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Upload size",
    mapData: "ascent",
    initialPagePublicId: `${strategyPublicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  return { t, owner };
}

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "upload-size-account";
  process.env.R2_BUCKET = "upload-size-bucket";
  process.env.R2_ACCESS_KEY_ID = "upload-size-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "upload-size-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://assets.upload-size.test";
  process.env.R2_S3_ENDPOINT = "https://upload-size.r2.test";
});

describe("image upload size", () => {
  test("the signature covers the upload's length", async () => {
    const signedFor = async (contentLength: number) =>
      new URL(
        (
          await presignR2PutUrl({
            config: getR2Config(),
            objectKey: "strategies/s/images/a/1.png",
            mimeType: "image/png",
            contentLength,
            now: new Date("2026-10-31T00:00:00.000Z"),
          })
        ).uploadUrl,
      ).searchParams;

    const small = await signedFor(100);
    expect(small.get("X-Amz-SignedHeaders")).toBe(
      "content-length;content-type;host",
    );
    expect(small.get("X-Amz-Signature")).not.toBe(
      (await signedFor(101)).get("X-Amz-Signature"),
    );
  });

  test("an upload with no exact size within the limit gets no URL", async () => {
    const { t, owner } = await createHarness();
    const start = (byteSize?: number) =>
      owner.action(generateUploadUrl, {
        ...protocol,
        strategyPublicId,
        assetPublicId: "picture",
        mimeType: "image/png",
        fileExtension: ".png",
        byteSize,
      });

    await expect(start()).rejects.toThrow(/state its size/);
    await expect(start(0)).rejects.toThrow(/state its size/);
    await expect(start(100.5)).rejects.toThrow(/state its size/);
    await expect(start(maxImageBytes + 1)).rejects.toThrow(/too large/);
    expect(
      await t.run((ctx) => ctx.db.query("imageAssets").collect()),
    ).toEqual([]);

    await expect(start(maxImageBytes)).resolves.toMatchObject({
      maxBytes: maxImageBytes,
    });
  });
});
