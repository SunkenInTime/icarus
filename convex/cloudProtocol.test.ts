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
    "strategies:duplicate",
    {
      sourceStrategyPublicId: "strategy",
      publicId: "copy",
      name: "Strategy (Copy)",
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

// Every public read that returns element or lineup payloads, and the shell.
const publicPayloadQueries = [
  ["strategy:getShell", { strategyPublicId: "strategy" }],
  [
    "strategy:getFullSnapshot",
    { strategyPublicId: "strategy", acceptsTrashedPagesLeftOut: true },
  ],
  ["page:getSnapshot", { strategyPublicId: "strategy", pagePublicId: "page" }],
  [
    "elements:listForPage",
    { strategyPublicId: "strategy", pagePublicId: "page" },
  ],
  ["elements:listForStrategy", { strategyPublicId: "strategy" }],
  [
    "lineups:listForPage",
    { strategyPublicId: "strategy", pagePublicId: "page" },
  ],
  ["lineups:listForStrategy", { strategyPublicId: "strategy" }],
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

describe("public payload query protocol gate", () => {
  // A client from before a cutover sends no protocol on these reads; one on
  // an older protocol sends its own. Neither may see a row it cannot read.
  test.each(publicPayloadQueries)("%s rejects a missing protocol", async (
    identifier,
    args,
  ) => {
    const t = convexTest(schema, modules);
    const query = makeFunctionReference<"query">(identifier);

    const error = await captureError(t.query(query, args));

    expect(error).not.toBeNull();
    expect(String(error)).toContain("clientProtocolVersion");
  });

  test.each(publicPayloadQueries)("%s rejects an old protocol canonically", async (
    identifier,
    args,
  ) => {
    const t = convexTest(schema, modules);
    const query = makeFunctionReference<"query">(identifier);

    const error = await captureError(
      t.query(query, {
        ...args,
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION - 1,
      }),
    );

    expectUpgradeRequired(error);
  });

  test.each(publicPayloadQueries)(
    "%s rejects an unknown future protocol canonically",
    async (identifier, args) => {
      const t = convexTest(schema, modules);
      const query = makeFunctionReference<"query">(identifier);

      const error = await captureError(
        t.query(query, {
          ...args,
          clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION + 1,
        }),
      );

      expectUpgradeRequired(error);
    },
  );

  test.each(publicPayloadQueries)("%s answers the current protocol", async (
    identifier,
    args,
  ) => {
    const t = convexTest(schema, modules);
    const owner = t.withIdentity({
      issuer: "https://cloud-protocol.test",
      subject: "owner",
      tokenIdentifier: "cloud-protocol|owner",
      name: "owner",
    });
    const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
    await owner.mutation(
      makeFunctionReference<"mutation">("users:ensureCurrentUser"),
      protocol,
    );
    await owner.mutation(
      makeFunctionReference<"mutation">("strategies:createWithInitialPage"),
      {
        ...protocol,
        publicId: "strategy",
        name: "Strategy",
        mapData: "ascent",
        initialPagePublicId: "page",
        initialPageName: "Page 1",
        initialPageIsAttack: true,
      },
    );
    const query = makeFunctionReference<"query">(identifier);

    await expect(
      owner.query(query, { ...args, ...protocol }),
    ).resolves.toBeDefined();
  });
});

describe("the protocol check a refused client asks", () => {
  const ping = makeFunctionReference<"query">("health:ping");

  test("the connection health check sends no protocol and is answered", async () => {
    const t = convexTest(schema, modules);
    await expect(t.query(ping, {})).resolves.toBe("ok");
  });

  test("the current protocol is accepted", async () => {
    const t = convexTest(schema, modules);
    await expect(
      t.query(ping, { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION }),
    ).resolves.toBe("ok");
  });

  test("an old protocol is refused canonically", async () => {
    const t = convexTest(schema, modules);
    expectUpgradeRequired(
      await captureError(
        t.query(ping, {
          clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION - 1,
        }),
      ),
    );
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
