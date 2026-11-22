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

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getShell = makeFunctionReference<"query">("strategy:getShell");
const getPageList = makeFunctionReference<"query">("strategy:getPageList");

type Harness = TestConvexForDataModel<DataModel>;
type Who = "owner" | "editor" | "viewer" | "stranger";

type Descriptor = {
  publicId: string;
  strategyPublicId: string;
  name: string;
  isAutoNamed?: boolean;
  sortIndex: number;
  isAttack: boolean;
  revision: number;
  createdAt: number;
  updatedAt: number;
};

type ListedPage = Descriptor & {
  settings: Record<string, unknown> | null;
  contentRevision: number;
  contentCreatedAt: number;
  contentUpdatedAt: number;
};

type Header = { revision: number; role: string } & Record<string, unknown>;
type PageList = { header: Header; pages: ListedPage[] };
type Shell = { header: Header; pages: Descriptor[] };

const strategyPublicId = "page-list";
const firstPage = "page-list-page-1";
const settings = { agentSize: 40, abilitySize: 30, useNeutralTeamColors: true };
const otherSettings = {
  agentSize: 25,
  abilitySize: 45,
  useNeutralTeamColors: false,
};

let opCounter = 0;

async function createHarness(): Promise<{
  t: TestConvexForDataModelAndIdentity<DataModel>;
  users: Record<Who, Harness>;
}> {
  const t = convexTest(schema, modules);
  const users = Object.fromEntries(
    (["owner", "editor", "viewer", "stranger"] as const).map((who) => [
      who,
      t.withIdentity({
        issuer: "https://page-list.test",
        subject: who,
        tokenIdentifier: `page-list|${who}`,
        name: who,
      }),
    ]),
  ) as Record<Who, Harness>;
  for (const user of Object.values(users)) {
    await user.mutation(ensureCurrentUser, protocol);
  }
  await users.owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Page list",
    mapData: "ascent",
    initialPagePublicId: firstPage,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  for (const [token, role, who] of [
    ["edit-link", "editor", users.editor],
    ["view-link", "viewer", users.viewer],
  ] as const) {
    await users.owner.mutation(createShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token,
      role,
    });
    await who.mutation(redeemShare, { ...protocol, token });
  }
  return { t, users };
}

function pageList(who: Harness): Promise<PageList> {
  return who.query(getPageList, {
    ...protocol,
    strategyPublicId,
  }) as Promise<PageList>;
}

function shell(who: Harness): Promise<Shell> {
  return who.query(getShell, { ...protocol, strategyPublicId }) as Promise<Shell>;
}

async function apply(who: Harness, ops: Array<Record<string, unknown>>) {
  const { results } = (await who.mutation(applyBatch, {
    ...protocol,
    strategyPublicId,
    clientId: "client",
    checkTrashedPageDeletes: true,
    ops: ops.map((op) => ({ opId: `op-${++opCounter}`, ...op })),
  })) as { results: Array<{ status: string }> };
  for (const result of results) {
    expect(result).toMatchObject({ status: "applied" });
  }
}

async function addPage(who: Harness, pagePublicId: string, sortIndex: number) {
  const { header } = await pageList(who);
  await apply(who, [
    {
      type: "page.add",
      pagePublicId,
      payload: { name: pagePublicId, isAutoNamed: false, isAttack: false },
      sortIndex,
      expectedStrategyRevision: header.revision,
    },
  ]);
}

async function setSettings(
  who: Harness,
  pages: Record<string, Record<string, unknown>>,
  more: Array<Record<string, unknown>> = [],
) {
  const list = await pageList(who);
  await apply(who, [
    ...Object.entries(pages).map(([pagePublicId, pageSettings]) => ({
      type: "pageContent.patch",
      pagePublicId,
      settings: pageSettings,
      expectedPageContentRevision: list.pages.find(
        (page) => page.publicId === pagePublicId,
      )!.contentRevision,
    })),
    ...more,
  ]);
}

function settingsByPage(list: PageList) {
  return Object.fromEntries(
    list.pages.map((page) => [page.publicId, page.settings]),
  );
}

function withoutContent(page: ListedPage): Descriptor {
  const {
    settings: _settings,
    contentRevision: _revision,
    contentCreatedAt: _created,
    contentUpdatedAt: _updated,
    ...descriptor
  } = page;
  return descriptor;
}

describe("strategy:getPageList", () => {
  test("the owner, an editor and a viewer read the same pages, each with their own role", async () => {
    const { users } = await createHarness();
    const owner = await pageList(users.owner);
    const editor = await pageList(users.editor);
    const viewer = await pageList(users.viewer);

    expect(owner.header.role).toBe("owner");
    expect(editor.header.role).toBe("editor");
    expect(viewer.header.role).toBe("viewer");
    expect(editor.pages).toEqual(owner.pages);
    expect(viewer.pages).toEqual(owner.pages);
    expect(owner.header).toEqual((await shell(users.owner)).header);
    expect(viewer.header).toEqual((await shell(users.viewer)).header);
  });

  test("someone the strategy is not shared with is refused, as getShell refuses them", async () => {
    const { users } = await createHarness();
    await expect(shell(users.stranger)).rejects.toThrow("Forbidden");
    await expect(pageList(users.stranger)).rejects.toThrow("Forbidden");
  });

  test("a share link that was never redeemed reads what getShell reads, signed in or out", async () => {
    const { t, users } = await createHarness();
    const shareToken = "unredeemed-link";
    await users.owner.mutation(createShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: shareToken,
      role: "editor",
    });
    await addPage(users.owner, "page-2", 1);
    await setSettings(users.owner, { "page-2": settings });

    for (const who of [t, users.stranger]) {
      const withLink = { ...protocol, strategyPublicId, shareToken };
      const list = (await who.query(getPageList, withLink)) as PageList;
      const fromShell = (await who.query(getShell, withLink)) as Shell;
      expect(list.header).toEqual(fromShell.header);
      expect(list.header.role).toBe("viewer");
      expect(list.pages.map(withoutContent)).toEqual(fromShell.pages);
      expect(settingsByPage(list)).toEqual({
        [firstPage]: null,
        "page-2": settings,
      });

      const withoutLink = { ...protocol, strategyPublicId };
      const refusal = (query: typeof getShell) =>
        who.query(query, withoutLink).then(
          () => null,
          (error: Error) => error.message,
        );
      const shellRefusal = await refusal(getShell);
      expect(shellRefusal).not.toBeNull();
      expect(await refusal(getPageList)).toEqual(shellRefusal);
    }
  });

  test("a trashed page is left out, as getShell leaves it out", async () => {
    const { users } = await createHarness();
    await addPage(users.owner, "page-2", 1);
    await addPage(users.owner, "page-3", 2);
    const { header } = await pageList(users.owner);
    await apply(users.owner, [
      {
        type: "page.delete",
        pagePublicId: "page-2",
        expectedStrategyRevision: header.revision,
      },
    ]);

    const list = await pageList(users.owner);
    expect(list.pages.map((page) => page.publicId)).toEqual([
      firstPage,
      "page-3",
    ]);
    expect(list.pages.map(withoutContent)).toEqual(
      (await shell(users.owner)).pages,
    );
  });

  test("a page without settings lists null, and one with settings lists them at their revision", async () => {
    const { users } = await createHarness();
    await addPage(users.owner, "page-2", 1);
    const before = await pageList(users.owner);
    const second = before.pages.find((page) => page.publicId === "page-2")!;
    expect(before.pages.map((page) => page.settings)).toEqual([null, null]);

    await apply(users.owner, [
      {
        type: "pageContent.patch",
        pagePublicId: "page-2",
        settings,
        expectedPageContentRevision: second.contentRevision,
      },
    ]);

    const after = await pageList(users.owner);
    expect(after.pages[0]!.settings).toBeNull();
    expect(after.pages[1]).toMatchObject({
      publicId: "page-2",
      settings,
      contentRevision: second.contentRevision + 1,
    });
  });

  test("pages come in getShell's order, with getShell's fields", async () => {
    const { users } = await createHarness();
    await addPage(users.owner, "page-2", 1);
    await addPage(users.owner, "page-3", 2);
    const { header } = await pageList(users.owner);
    await apply(users.owner, [
      {
        type: "page.reorder",
        pagePublicId: "page-3",
        sortIndex: 0,
        expectedStrategyRevision: header.revision,
      },
    ]);

    const list = await pageList(users.owner);
    const fromShell = await shell(users.owner);
    expect(list.pages.map((page) => page.publicId)).toEqual([
      "page-3",
      firstPage,
      "page-2",
    ]);
    expect(list.pages.map(withoutContent)).toEqual(fromShell.pages);
    expect(list.header).toEqual(fromShell.header);
  });

  describe("one write changes the whole list at once", () => {
    test("adding a page", async () => {
      const { users } = await createHarness();
      const before = await pageList(users.owner);
      await addPage(users.owner, "page-2", 1);
      const after = await pageList(users.owner);

      expect(after.header.revision).toBe(before.header.revision + 1);
      expect(after.pages.slice(0, 1)).toEqual(before.pages);
      expect(after.pages[1]).toMatchObject({
        publicId: "page-2",
        sortIndex: 1,
        settings: null,
      });
    });

    test("reordering pages", async () => {
      const { users } = await createHarness();
      await addPage(users.owner, "page-2", 1);
      await setSettings(users.owner, {
        [firstPage]: settings,
        "page-2": otherSettings,
      });
      const before = await pageList(users.owner);
      await apply(users.owner, [
        {
          type: "page.reorder",
          pagePublicId: "page-2",
          sortIndex: 0,
          expectedStrategyRevision: before.header.revision,
        },
      ]);
      const after = await pageList(users.owner);

      expect(after.header.revision).toBe(before.header.revision + 1);
      expect(after.pages.map((page) => page.publicId)).toEqual([
        "page-2",
        firstPage,
      ]);
      expect(after.pages.map((page) => page.settings)).toEqual([
        otherSettings,
        settings,
      ]);
      expect(settingsByPage(after)).toEqual(settingsByPage(before));
    });

    test("changing two pages' settings and their order together", async () => {
      const { users } = await createHarness();
      await addPage(users.owner, "page-2", 1);
      await addPage(users.owner, "page-3", 2);
      const { header } = await pageList(users.owner);
      await setSettings(
        users.owner,
        { [firstPage]: otherSettings, "page-3": settings },
        [
          {
            type: "page.reorder",
            pagePublicId: "page-3",
            sortIndex: 0,
            expectedStrategyRevision: header.revision,
          },
        ],
      );
      const after = await pageList(users.owner);

      expect(after.pages.map((page) => page.publicId)).toEqual([
        "page-3",
        firstPage,
        "page-2",
      ]);
      expect(settingsByPage(after)).toEqual({
        "page-3": settings,
        [firstPage]: otherSettings,
        "page-2": null,
      });
    });

    test("changing a page's settings", async () => {
      const { users } = await createHarness();
      const before = await pageList(users.owner);
      await apply(users.owner, [
        {
          type: "pageContent.patch",
          pagePublicId: firstPage,
          settings,
          expectedPageContentRevision: before.pages[0]!.contentRevision,
        },
      ]);
      const after = await pageList(users.owner);

      expect(after.header).toEqual(before.header);
      expect(after.pages.map(withoutContent)).toEqual(
        before.pages.map(withoutContent),
      );
      expect(after.pages[0]).toMatchObject({
        settings,
        contentRevision: before.pages[0]!.contentRevision + 1,
      });
    });
  });
});
