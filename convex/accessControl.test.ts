import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const updateFolder = makeFunctionReference<"mutation">("folders:update");
const listFolderTree = makeFunctionReference<"query">("folders:listTree");
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const updateStrategy = makeFunctionReference<"mutation">("strategies:update");
const moveStrategy = makeFunctionReference<"mutation">("strategies:move");
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const listStrategies = makeFunctionReference<"query">(
  "strategies:listForFolder",
);
const getStrategyShell = makeFunctionReference<"query">("strategy:getShell");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const addPage = makeFunctionReference<"mutation">("pages:add");
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const revokeShare = makeFunctionReference<"mutation">("shares:revoke");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

function identity(subject: "a" | "b" | "c") {
  return {
    issuer: "https://access-control.test",
    subject,
    tokenIdentifier: `access-control|${subject}`,
    name: `User ${subject.toUpperCase()}`,
  };
}

async function createHarness(): Promise<{
  t: RootHarness;
  a: Harness;
  b: Harness;
  c: Harness;
}> {
  const t = convexTest(schema, modules);
  const a = t.withIdentity(identity("a"));
  const b = t.withIdentity(identity("b"));
  const c = t.withIdentity(identity("c"));
  await Promise.all([
    a.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    }),
    b.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    }),
    c.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    }),
  ]);
  return { t, a, b, c };
}

async function seedStrategy(
  owner: Harness,
  strategyPublicId: string,
  pagePublicId: string,
  folderPublicId?: string,
) {
  await owner.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId: strategyPublicId,
    name: "A private Strategy",
    mapData: "ascent",
    folderPublicId,
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

describe("A/B/C access boundary", () => {
  test("a private Strategy stays hidden until a link is redeemed", async () => {
    const { a, b, c } = await createHarness();
    const strategyPublicId = "private-strategy";
    const initialPagePublicId = "private-page";
    await seedStrategy(a, strategyPublicId, initialPagePublicId);

    await expect(
      b.query(listStrategies, { scope: "shared" }),
    ).resolves.toEqual([]);
    await expect(
      c.query(listStrategies, { scope: "shared" }),
    ).resolves.toEqual([]);
    await expect(
      b.query(getStrategyShell, { strategyPublicId }),
    ).rejects.toThrow("Forbidden");
    await expect(
      c.query(getFullSnapshot, { strategyPublicId }),
    ).rejects.toThrow("Forbidden");

    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: "strategy-viewer-token",
      role: "viewer",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "strategy-viewer-token",
    });

    await expect(
      b.query(getStrategyShell, { strategyPublicId }),
    ).resolves.toMatchObject({
      header: { publicId: strategyPublicId, role: "viewer" },
      pages: [{ publicId: initialPagePublicId }],
    });
    await expect(
      b.query(getFullSnapshot, { strategyPublicId }),
    ).resolves.toMatchObject({
      header: { publicId: strategyPublicId, role: "viewer" },
      pages: [{ publicId: initialPagePublicId }],
    });
    await expect(
      b.mutation(updateStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        name: "Viewer must not write",
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      b.mutation(addPage, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        pagePublicId: "viewer-page",
        name: "Viewer page",
        sortIndex: 1,
        isAttack: false,
      }),
    ).rejects.toThrow("Forbidden");

    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: "strategy-editor-token",
      role: "editor",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "strategy-editor-token",
    });
    await expect(
      b.mutation(updateStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        name: "Edited by B",
      }),
    ).resolves.toMatchObject({ ok: true, revision: 1 });
    await expect(
      b.mutation(addPage, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 1,
        pagePublicId: "editor-page",
        name: "Added by B",
        sortIndex: 1,
        isAttack: false,
      }),
    ).resolves.toMatchObject({ ok: true, revision: 2 });
    await expect(
      a.query(getFullSnapshot, { strategyPublicId }),
    ).resolves.toMatchObject({
      header: { name: "Edited by B", revision: 2, role: "owner" },
      pages: [
        { publicId: initialPagePublicId },
        { publicId: "editor-page" },
      ],
    });

    await a.mutation(revokeShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: "strategy-editor-token",
    });
    await expect(
      c.mutation(redeemShare, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        token: "strategy-editor-token",
      }),
    ).rejects.toThrow("Share link revoked");
    await expect(
      b.mutation(updateStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 2,
        name: "B keeps redeemed access",
      }),
    ).resolves.toMatchObject({ ok: true, revision: 3 });
  });

  test("folder roles inherit through descendants without granting ownership", async () => {
    const { a, b, c } = await createHarness();
    const rootFolderPublicId = "shared-root";
    const childFolderPublicId = "shared-child";
    const strategyPublicId = "nested-strategy";

    await a.mutation(createFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      publicId: rootFolderPublicId,
      name: "A root",
    });
    await a.mutation(createFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      publicId: childFolderPublicId,
      name: "A child",
      parentFolderPublicId: rootFolderPublicId,
    });
    await seedStrategy(
      a,
      strategyPublicId,
      "nested-page",
      childFolderPublicId,
    );

    await expect(
      b.query(listFolderTree, { scope: "shared" }),
    ).resolves.toEqual([]);
    await expect(
      b.query(getStrategyShell, { strategyPublicId }),
    ).rejects.toThrow("Forbidden");

    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "folder",
      targetPublicId: rootFolderPublicId,
      token: "folder-viewer-token",
      role: "viewer",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "folder-viewer-token",
    });

    await expect(
      b.query(listFolderTree, { scope: "shared" }),
    ).resolves.toMatchObject([
      { publicId: rootFolderPublicId, role: "viewer" },
      {
        publicId: childFolderPublicId,
        parentFolderPublicId: rootFolderPublicId,
        role: "viewer",
      },
    ]);
    await expect(
      b.query(listStrategies, {
        folderPublicId: childFolderPublicId,
        scope: "shared",
      }),
    ).resolves.toMatchObject([
      { publicId: strategyPublicId, role: "viewer" },
    ]);
    await expect(
      b.mutation(updateStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        name: "Viewer must not write",
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      b.mutation(updateFolder, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        folderPublicId: childFolderPublicId,
        name: "Viewer must not rename",
      }),
    ).rejects.toThrow("Forbidden");

    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "folder",
      targetPublicId: rootFolderPublicId,
      token: "folder-editor-token",
      role: "editor",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "folder-editor-token",
    });
    await expect(
      b.mutation(updateStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        name: "Inherited editor write",
      }),
    ).resolves.toMatchObject({ ok: true, revision: 1 });
    await expect(
      b.mutation(updateFolder, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        folderPublicId: rootFolderPublicId,
        name: "Editors are not owners",
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      b.mutation(createShare, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        targetType: "folder",
        targetPublicId: rootFolderPublicId,
        token: "editor-cannot-reshare",
        role: "viewer",
      }),
    ).rejects.toThrow("Forbidden");

    await a.mutation(revokeShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "folder",
      targetPublicId: rootFolderPublicId,
      token: "folder-editor-token",
    });
    await expect(
      c.mutation(redeemShare, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        token: "folder-editor-token",
      }),
    ).rejects.toThrow("Share link revoked");
    await expect(
      c.query(listFolderTree, { scope: "shared" }),
    ).resolves.toEqual([]);
    await expect(
      b.mutation(updateStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 1,
        name: "Redeemed editor remains durable",
      }),
    ).resolves.toMatchObject({ ok: true, revision: 2 });
  });

  test("only the owner can move a directly shared Strategy", async () => {
    const { a, b } = await createHarness();
    const sourceFolderPublicId = "direct-move-source";
    const targetFolderPublicId = "direct-move-target";
    const strategyPublicId = "directly-shared-strategy";

    await a.mutation(createFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      publicId: sourceFolderPublicId,
      name: "Source",
    });
    await a.mutation(createFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      publicId: targetFolderPublicId,
      name: "Target",
    });
    await seedStrategy(
      a,
      strategyPublicId,
      "directly-shared-page",
      sourceFolderPublicId,
    );
    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: "direct-move-editor-token",
      role: "editor",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "direct-move-editor-token",
    });

    await expect(
      b.mutation(moveStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        folderPublicId: targetFolderPublicId,
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      a.query(listStrategies, {
        folderPublicId: sourceFolderPublicId,
        scope: "owned",
      }),
    ).resolves.toMatchObject([
      { publicId: strategyPublicId, revision: 0 },
    ]);

    await expect(
      a.mutation(moveStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
        folderPublicId: targetFolderPublicId,
      }),
    ).resolves.toMatchObject({ ok: true, revision: 1 });
    await expect(
      a.query(listStrategies, {
        folderPublicId: targetFolderPublicId,
        scope: "owned",
      }),
    ).resolves.toMatchObject([
      { publicId: strategyPublicId, revision: 1 },
    ]);
  });

  test("an inherited folder editor cannot move a Strategy out of the share", async () => {
    const { a, b } = await createHarness();
    const sharedFolderPublicId = "inherited-move-source";
    const strategyPublicId = "inherited-editor-strategy";

    await a.mutation(createFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      publicId: sharedFolderPublicId,
      name: "Shared source",
    });
    await seedStrategy(
      a,
      strategyPublicId,
      "inherited-editor-page",
      sharedFolderPublicId,
    );
    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "folder",
      targetPublicId: sharedFolderPublicId,
      token: "inherited-move-editor-token",
      role: "editor",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "inherited-move-editor-token",
    });

    await expect(
      b.mutation(moveStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      b.query(listStrategies, {
        folderPublicId: sharedFolderPublicId,
        scope: "shared",
      }),
    ).resolves.toMatchObject([
      { publicId: strategyPublicId, role: "editor", revision: 0 },
    ]);
  });

  test("deleting a Strategy removes its access records", async () => {
    const { t, a, b } = await createHarness();
    const strategyPublicId = "deleted-strategy";
    await seedStrategy(a, strategyPublicId, "deleted-page");
    await a.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: "deleted-strategy-token",
      role: "editor",
    });
    await b.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: "deleted-strategy-token",
    });

    await a.mutation(deleteStrategy, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      expectedRevision: 0,
    });

    const accessRecordCounts = await t.run(async (ctx) => ({
      collaborators: (await ctx.db.query("strategyCollaborators").collect())
        .length,
      shareLinks: (await ctx.db.query("shareLinks").collect()).length,
    }));
    expect(accessRecordCounts).toEqual({ collaborators: 0, shareLinks: 0 });
  });
});
