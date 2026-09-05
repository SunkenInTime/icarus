import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const publicMutations = [
  ["folders:create", { publicId: "folder", name: "Folder" }],
  ["folders:update", { folderPublicId: "folder" }],
  ["folders:move", { folderPublicId: "folder" }],
  ["folders:delete", { folderPublicId: "folder" }],
  [
    "invites:create",
    { strategyPublicId: "strategy", token: "token", role: "viewer" },
  ],
  ["invites:redeem", { token: "token" }],
  ["invites:revoke", { strategyPublicId: "strategy", token: "token" }],
  [
    "ops:applyBatch",
    { strategyPublicId: "strategy", clientId: "client", ops: [] },
  ],
  [
    "pages:add",
    {
      strategyPublicId: "strategy",
      expectedRevision: 0,
      pagePublicId: "page",
      name: "Page",
      sortIndex: 0,
      isAttack: true,
    },
  ],
  [
    "pages:rename",
    {
      strategyPublicId: "strategy",
      pagePublicId: "page",
      name: "Page",
      expectedRevision: 0,
    },
  ],
  [
    "pages:delete",
    {
      strategyPublicId: "strategy",
      pagePublicId: "page",
      expectedRevision: 0,
    },
  ],
  [
    "pages:reorder",
    {
      strategyPublicId: "strategy",
      orderedPagePublicIds: [],
      expectedRevision: 0,
    },
  ],
  [
    "shares:create",
    {
      targetType: "strategy",
      targetPublicId: "strategy",
      token: "token",
      role: "viewer",
    },
  ],
  [
    "shares:revoke",
    { targetType: "strategy", targetPublicId: "strategy", token: "token" },
  ],
  ["shares:redeem", { token: "token" }],
  [
    "strategies:create",
    { publicId: "strategy", name: "Strategy", mapData: "ascent" },
  ],
  [
    "strategies:createWithInitialPage",
    {
      publicId: "strategy",
      name: "Strategy",
      mapData: "ascent",
      initialPagePublicId: "page",
      initialPageName: "Page 1",
      initialPageIsAttack: true,
    },
  ],
  [
    "strategies:update",
    { strategyPublicId: "strategy", expectedRevision: 0 },
  ],
  [
    "strategies:move",
    { strategyPublicId: "strategy", expectedRevision: 0 },
  ],
  [
    "strategies:delete",
    { strategyPublicId: "strategy", expectedRevision: 0 },
  ],
  ["users:ensureCurrentUser", {}],
] as const;

const publicWriteActions = [
  [
    "images:generateUploadUrl",
    {
      strategyPublicId: "strategy",
      assetPublicId: "asset",
      mimeType: "image/png",
      fileExtension: ".png",
    },
  ],
  [
    "images:completeUpload",
    { strategyPublicId: "strategy", assetPublicId: "asset" },
  ],
  [
    "images:deleteAssetRef",
    { strategyPublicId: "strategy", assetPublicId: "asset" },
  ],
] as const;

async function captureError(promise: Promise<unknown>) {
  return promise.then(
    () => null,
    (caught: unknown) => caught as { data?: unknown },
  );
}

function expectUpgradeRequired(error: { data?: unknown } | null): void {
  expect(error).not.toBeNull();
  expect(typeof error?.data).toBe("string");
  expect(JSON.parse(error?.data as string)).toEqual({
    code: "CLIENT_UPGRADE_REQUIRED",
    message: "Client upgrade required",
  });
}

describe("public cloud mutation protocol gate", () => {
  test.each(publicMutations)("%s rejects an old protocol canonically", async (
    identifier,
    args,
  ) => {
    const t = convexTest(schema, modules);
    const mutation = makeFunctionReference<"mutation">(identifier);
    const error = await t
      .mutation(mutation, {
        ...args,
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION - 1,
      })
      .then(
        () => null,
        (caught: unknown) => caught as { data?: unknown },
      );

    expect(error).not.toBeNull();
    expect(typeof error?.data).toBe("string");
    expect(JSON.parse(error?.data as string)).toEqual({
      code: "CLIENT_UPGRADE_REQUIRED",
      message: "Client upgrade required",
    });
  });

  test("a newer unknown protocol receives the same canonical error", async () => {
    const t = convexTest(schema, modules);
    const mutation = makeFunctionReference<"mutation">(
      "users:ensureCurrentUser",
    );
    const error = await t
      .mutation(mutation, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION + 1,
      })
      .then(
        () => null,
        (caught: unknown) => caught as { data?: unknown },
      );

    expect(JSON.parse(error?.data as string)).toEqual({
      code: "CLIENT_UPGRADE_REQUIRED",
      message: "Client upgrade required",
    });
  });
});

describe("public cloud write action protocol gate", () => {
  test.each(publicWriteActions)("%s rejects a missing protocol", async (
    identifier,
    args,
  ) => {
    const t = convexTest(schema, modules);
    const action = makeFunctionReference<"action">(identifier);

    const error = await captureError(t.action(action, args));

    expect(error).not.toBeNull();
  });

  test.each(publicWriteActions)("%s rejects an old protocol canonically", async (
    identifier,
    args,
  ) => {
    const t = convexTest(schema, modules);
    const action = makeFunctionReference<"action">(identifier);

    const error = await captureError(
      t.action(action, {
        ...args,
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION - 1,
      }),
    );

    expectUpgradeRequired(error);
  });

  test.each(publicWriteActions)(
    "%s rejects an unknown future protocol canonically",
    async (identifier, args) => {
      const t = convexTest(schema, modules);
      const action = makeFunctionReference<"action">(identifier);

      const error = await captureError(
        t.action(action, {
          ...args,
          clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION + 1,
        }),
      );

      expectUpgradeRequired(error);
    },
  );
});
