import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import type { DataModel, Id } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import { PAGE_TRASH_RETENTION_MS } from "./lib/entities";
import schema from "./schema";
import { oneLineupPayload } from "./testContent.helpers";
import { modules } from "./test.setup";

// A device keeps an offline copy of a strategy (a full read) and skips
// reading it again while strategy:listContentVersions answers with the
// header and content version it stored. So for every mutation the server
// has: whenever it changes what strategy:getFullSnapshot returns to someone,
// that person's listContentVersions answer for the strategy changes too.
// If it ever does not, an offline copy silently goes stale.
//
// The ledger below names every mutation, with scenarios that run it against
// realistic data and check that promise for every strategy and both users,
// or with the reason it cannot change any full read. A mutation added
// without an entry fails the first test, so whoever adds one decides.

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

const mutationRef = (name: string) => makeFunctionReference<"mutation">(name);
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const listContentVersions = makeFunctionReference<"query">(
  "strategy:listContentVersions",
);
const listMembers = makeFunctionReference<"query">("shares:listMembers");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Row = Record<string, any>;

type World = {
  t: RootHarness;
  /// Owns "s", the strategy most scenarios work on.
  owner: Harness;
  /// A second person: a collaborator on "s" (or a folder it sits in) where
  /// a scenario shares it, and owner of "b", which no scenario should touch.
  other: Harness;
  /// What a scenario's setup hands to its run and checks.
  state: Row;
};

/// Calls the ledger entry's own mutation, as [caller].
type Mutate = (caller: Harness, args: Row) => Promise<any>;

type Scenario = {
  name: string;
  /// Whether the mutation must change someone's full read. A scenario that
  /// changes nothing proves nothing, so one that is meant to change a read
  /// fails when it doesn't; one that is not ([false]) must leave every read
  /// as it was, and says in [did] what it did instead.
  changesRead: boolean;
  setup?: (w: World) => Promise<void>;
  /// Setup's scheduled work runs before the reads are taken, unless the
  /// scenario runs that work itself.
  settleSetup?: false;
  /// Strategies the mutation creates: they are read before it too.
  creates?: string[];
  run: (w: World, mutate: Mutate) => Promise<unknown>;
  did?: (w: World) => Promise<void>;
  /// Every listContentVersions answer must stay as it was, not only those
  /// whose read stayed (a cache-only mutation like folding).
  answersUnchanged?: true;
};

type LedgerEntry = { exempt: string } | { scenarios: Scenario[] };

const S = "s";
const P1 = "s-p1";
const P2 = "s-p2";
const DAY_MS = 24 * 60 * 60 * 1000;
const COPY_UUID = "6f1c2d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f";

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "ledger-account";
  process.env.R2_BUCKET = "ledger-bucket";
  process.env.R2_ACCESS_KEY_ID = "ledger-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "ledger-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://media.ledger.test";
  process.env.R2_S3_ENDPOINT = "https://ledger.r2.test";
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function identity(subject: string) {
  return {
    issuer: "https://content-version-ledger.test",
    subject,
    tokenIdentifier: `ledger|${subject}`,
    name: `User ${subject}`,
  };
}

async function world(): Promise<World> {
  // Scheduled cleanup runs on fake timers; R2 deletes answer 204.
  vi.useFakeTimers();
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(null, { status: 204 })),
  );
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  const other = t.withIdentity(identity("other"));
  for (const user of [owner, other]) {
    await user.mutation(mutationRef("users:ensureCurrentUser"), protocol);
  }
  const w: World = { t, owner, other, state: {} };
  await createStrategy(other, "b");
  await apply(other, "b", [addElement("b-agent", "b-p1", agent("b-agent"))]);
  return w;
}

/// Runs every scheduled function, rescheduled ones included, to the end.
async function settle(w: World) {
  await w.t.finishAllScheduledFunctions(vi.runAllTimers);
}

// ---------------------------------------------------------------------------
// Content

let opCount = 0;
const nextOpId = () => `ledger-op-${++opCount}`;

function agent(id: string, dx = 10) {
  return {
    kind: "agent",
    payloadVersion: 1,
    data: {
      id,
      elementType: "agent",
      kind: "plain",
      type: "sova",
      position: { dx, dy: 20 },
      isAlly: true,
      state: "none",
      weapon: "none",
      isDeleted: false,
      lineUpID: null,
    },
  };
}

/// An image element; [assetId] names the picture it shows when that is
/// another image's (a copy keeps its original's picture).
function image(id: string, assetId?: string) {
  return {
    kind: "image",
    payloadVersion: 1,
    data: { id, scale: 1, ...(assetId === undefined ? {} : { assetId }) },
  };
}

function addElement(
  id: string,
  pagePublicId: string,
  payload: Row,
  sortIndex = 0,
  extra: Row = {},
) {
  return {
    opId: nextOpId(),
    type: "element.add",
    elementPublicId: id,
    pagePublicId,
    payload,
    sortIndex,
    ...extra,
  };
}

function addLineup(id: string, pagePublicId: string, sortIndex = 0) {
  return {
    opId: nextOpId(),
    type: "lineup.add",
    lineupPublicId: id,
    pagePublicId,
    payload: oneLineupPayload(id),
    sortIndex,
  };
}

function batchArgs(ops: Row[], strategyPublicId = S) {
  return { ...protocol, strategyPublicId, clientId: "ledger-device", ops };
}

function expectApplied(result: unknown) {
  for (const op of (result as { results: Row[] }).results) {
    expect(op).toMatchObject({ status: "applied" });
  }
  return result;
}

async function apply(user: Harness, strategyPublicId: string, ops: Row[]) {
  return expectApplied(
    await user.mutation(
      mutationRef("ops:applyBatch"),
      batchArgs(ops, strategyPublicId),
    ),
  );
}

async function createStrategy(
  user: Harness,
  publicId: string,
  extra: Row = {},
) {
  await user.mutation(mutationRef("strategies:createWithInitialPage"), {
    ...protocol,
    publicId,
    name: `Strategy ${publicId}`,
    mapData: "ascent",
    initialPagePublicId: `${publicId}-p1`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
    ...extra,
  });
}

async function insertAsset(
  w: World,
  strategyPublicId: string,
  publicId: string,
  fields: Row = {},
): Promise<Id<"imageAssets">> {
  const strategy = await strategyRow(w, strategyPublicId);
  return await w.t.run(async (ctx) => {
    const now = Date.now();
    return await ctx.db.insert("imageAssets", {
      publicId,
      provider: "r2",
      strategyId: strategy!._id,
      objectKey: `strategies/${strategyPublicId}/${publicId}.png`,
      uploadStatus: "active",
      fileExtension: ".png",
      mimeType: "image/png",
      byteSize: 100,
      uploadedAt: now,
      createdAt: now,
      updatedAt: now,
      ...fields,
    });
  });
}

/// The owner's strategy "s": two pages, two agents, an uploaded image, a
/// lineup and a deleted agent's tombstone, each written the way a client
/// writes them.
async function seed(w: World, extra: Row = {}) {
  await createStrategy(w.owner, S, extra);
  await insertAsset(w, S, "s-img");
  await apply(w.owner, S, [
    {
      opId: nextOpId(),
      type: "page.add",
      pagePublicId: P2,
      payload: { name: "Page 2", isAutoNamed: true, isAttack: false },
      sortIndex: 1,
      expectedStrategyRevision: await strategyRevision(w),
    },
  ]);
  await apply(w.owner, S, [
    addElement("s-agent", P1, agent("s-agent")),
    addElement("s-img", P1, image("s-img"), 1),
    addElement("s-agent-2", P2, agent("s-agent-2")),
    addElement("s-gone", P1, agent("s-gone"), 2),
    addLineup("s-lu", P1),
    addLineup("s-lu-2", P1, 1),
  ]);
  await apply(w.owner, S, [
    {
      opId: nextOpId(),
      type: "element.delete",
      elementPublicId: "s-gone",
      pagePublicId: P1,
      expectedElementRevision: 1,
    },
  ]);
}

async function createFolder(w: World, publicId: string, parent?: string) {
  await w.owner.mutation(mutationRef("folders:create"), {
    ...protocol,
    publicId,
    name: publicId,
    parentFolderPublicId: parent,
  });
}

async function createLink(
  w: World,
  targetType: "strategy" | "folder",
  targetPublicId: string,
  role: "viewer" | "editor",
  token = `${targetPublicId}-${role}`,
) {
  await w.owner.mutation(mutationRef("shares:create"), {
    ...protocol,
    targetType,
    targetPublicId,
    token,
    role,
  });
  return token;
}

/// The other user joins [targetPublicId] through a share link.
async function shareWithOther(
  w: World,
  targetType: "strategy" | "folder",
  targetPublicId: string,
  role: "viewer" | "editor",
) {
  const token = await createLink(w, targetType, targetPublicId, role);
  await w.other.mutation(mutationRef("shares:redeem"), { ...protocol, token });
  return token;
}

/// "s" seeded and shared with the other user at [role].
function seedShared(role: "viewer" | "editor") {
  return async (w: World) => {
    await seed(w);
    w.state.token = await shareWithOther(w, "strategy", S, role);
  };
}

/// Folder "team" shared with the other user at [role], holding "s".
function seedInSharedFolder(role: "viewer" | "editor") {
  return async (w: World) => {
    await createFolder(w, "team");
    w.state.token = await shareWithOther(w, "folder", "team", role);
    await seed(w, { folderPublicId: "team" });
  };
}

async function memberIdOf(
  w: World,
  targetType: "strategy" | "folder",
  targetPublicId: string,
): Promise<string> {
  const page = (await w.owner.query(listMembers, {
    targetType,
    targetPublicId,
  })) as { members: Row[] };
  return page.members[0]!.memberId as string;
}

// ---------------------------------------------------------------------------
// Rows

async function strategyRow(w: World, publicId: string) {
  return await w.t.run((ctx) =>
    ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .first(),
  );
}

async function strategyRevision(w: World, publicId = S) {
  return (await strategyRow(w, publicId))!.revision;
}

async function pageRow(w: World, publicId: string) {
  return await w.t.run((ctx) =>
    ctx.db
      .query("pages")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .first(),
  );
}

async function pageContentRevision(w: World, pagePublicId: string) {
  const page = await pageRow(w, pagePublicId);
  return await w.t.run(async (ctx) => {
    const content = await ctx.db
      .query("pageContents")
      .withIndex("by_pageId", (q) => q.eq("pageId", page!._id))
      .first();
    return content!.revision;
  });
}

async function elementRow(w: World, publicId: string) {
  return await w.t.run((ctx) =>
    ctx.db
      .query("elements")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .first(),
  );
}

async function elementRevision(w: World, publicId: string) {
  return (await elementRow(w, publicId))!.revision;
}

async function lineupRevision(w: World, publicId: string) {
  const rows = await w.t.run((ctx) => ctx.db.query("lineups").collect());
  return rows.find((row) => row.publicId === publicId)!.revision;
}

async function assetRows(w: World, publicId: string) {
  return await w.t.run((ctx) =>
    ctx.db
      .query("imageAssets")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .collect(),
  );
}

async function assetRow(w: World, id: Id<"imageAssets">) {
  return await w.t.run((ctx) => ctx.db.get(id));
}

async function linkId(w: World, token: string) {
  return await w.t.run(async (ctx) => {
    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", token))
      .first();
    return link!._id;
  });
}

// ---------------------------------------------------------------------------
// What each person sees

const READERS = ["owner", "other"] as const;
/// How a read fails for someone who can't read the strategy.
const UNREADABLE = /FORBIDDEN|NOT_FOUND|UNAUTHENTICATED|Forbidden|not found/i;

type Seen = { read: Row; answer: Row };

async function strategyIds(w: World): Promise<string[]> {
  const rows = await w.t.run((ctx) => ctx.db.query("strategies").collect());
  return rows.map((row) => row.publicId);
}

function errorText(error: unknown): string {
  const data = (error as { data?: unknown }).data;
  const code =
    data !== null && typeof data === "object"
      ? (data as { code?: unknown }).code
      : undefined;
  if (typeof code === "string") return code;
  return error instanceof Error ? error.message : String(error);
}

async function fullRead(user: Harness, strategyPublicId: string) {
  try {
    return (await user.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId,
      acceptsTrashedPagesLeftOut: true,
      acceptsPictureIds: true,
      includeContentVersion: true,
    })) as Row;
  } catch (error) {
    return { unreadable: errorText(error) };
  }
}

async function observe(w: World, ids: string[]) {
  const seen = new Map<string, Seen>();
  for (const reader of READERS) {
    const user = w[reader];
    const answers = (await user.query(listContentVersions, {
      ...protocol,
      strategyPublicIds: ids,
    })) as Row[];
    for (const [index, id] of ids.entries()) {
      seen.set(`${reader} reading ${id}`, {
        read: await fullRead(user, id),
        answer: answers[index]!,
      });
    }
  }
  return seen;
}

/// JSON with sorted keys, so equal values print equal.
function canonical(value: unknown): string {
  return JSON.stringify(value, (_key, child: unknown) =>
    child !== null && typeof child === "object" && !Array.isArray(child)
      ? Object.fromEntries(
          Object.entries(child as Row).sort(([a], [b]) => a.localeCompare(b)),
        )
      : child,
  );
}

/// The read as a copy holds it: whether it can be read at all, and if so
/// everything but the version it was stored with.
function readContent(read: Row): string {
  if ("unreadable" in read) return "unreadable";
  const { contentVersion: _version, ...content } = read;
  return canonical(content);
}

/// The read and the answer taken together must agree: a copy stores the
/// read's header and content version and compares them with the answer.
function disagreements(key: string, { read, answer }: Seen): string[] {
  if ("unreadable" in read) {
    const problems: string[] = [];
    if (!UNREADABLE.test(String(read.unreadable))) {
      problems.push(`${key}: the read failed unexpectedly: ${read.unreadable}`);
    }
    if (answer.status !== "gone") {
      problems.push(`${key}: unreadable, but the answer is ${canonical(answer)}`);
    }
    return problems;
  }
  if (
    answer.status !== "found" ||
    canonical(answer.header) !== canonical(read.header) ||
    answer.contentVersion !== read.contentVersion
  ) {
    return [
      `${key}: the read has ${canonical({
        header: read.header,
        contentVersion: read.contentVersion,
      })} but the answer is ${canonical(answer)}`,
    ];
  }
  return [];
}

async function check(identifier: string, scenario: Scenario) {
  const w = await world();
  await scenario.setup?.(w);
  if (scenario.settleSetup !== false) await settle(w);

  const ids = [
    ...new Set([...(await strategyIds(w)), ...(scenario.creates ?? [])]),
  ];
  const before = await observe(w, ids);
  const ref = mutationRef(identifier.replace(/\.js:/, ":"));
  await scenario.run(w, (caller, args) => caller.mutation(ref, args));
  const created = (await strategyIds(w)).filter((id) => !ids.includes(id));
  expect(created, "name the strategies a mutation creates in `creates`").toEqual(
    [],
  );
  const after = await observe(w, ids);

  const problems: string[] = [];
  const changed: string[] = [];
  for (const [key, was] of before) {
    const now = after.get(key)!;
    problems.push(...disagreements(key, was), ...disagreements(key, now));
    const answerMoved = canonical(was.answer) !== canonical(now.answer);
    if (readContent(was.read) !== readContent(now.read)) {
      changed.push(key);
      if (!answerMoved) {
        problems.push(
          `${key}: the full read changed, but listContentVersions still answers ${canonical(now.answer)}`,
        );
      }
    }
    if (scenario.answersUnchanged === true && answerMoved) {
      problems.push(
        `${key}: the answer moved from ${canonical(was.answer)} to ${canonical(now.answer)}`,
      );
    }
  }
  expect(problems).toEqual([]);
  if (scenario.changesRead) {
    expect(changed, "the scenario should change someone's full read").not.toEqual(
      [],
    );
  } else {
    expect(changed, "the scenario should leave every full read as it was").toEqual(
      [],
    );
  }
  await scenario.did?.(w);
  await settle(w);
}

// ---------------------------------------------------------------------------
// The ledger

function rejectedStalePatch(): Scenario {
  return {
    name: "a batch whose only op is refused writes nothing anyone reads",
    changesRead: false,
    setup: seedShared("editor"),
    run: async (w, mutate) => {
      const result = (await mutate(
        w.owner,
        batchArgs([
          {
            opId: nextOpId(),
            type: "element.patch",
            elementPublicId: "s-agent",
            pagePublicId: P1,
            payload: agent("s-agent", 70),
            expectedElementRevision: 0,
          },
        ]),
      )) as { results: Row[] };
      expect(result.results[0]).toMatchObject({ status: "rejected" });
    },
  };
}

const applyBatch: Scenario[] = [
  {
    name: "element.add places an agent",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(w.owner, batchArgs([addElement("s-new", P1, agent("s-new"))])),
      ),
  },
  {
    name: "element.add with the tombstone's revision brings a deleted agent back",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            addElement("s-gone", P1, agent("s-gone"), 2, {
              expectedElementRevision: await elementRevision(w, "s-gone"),
            }),
          ]),
        ),
      ),
  },
  {
    name: "element.add of an image whose upload hasn't come adds its placeholder",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([addElement("s-new-img", P1, image("s-new-img"), 3)]),
        ),
      ),
    did: async (w) => {
      expect(await assetRows(w, "s-new-img")).toMatchObject([
        { uploadStatus: "pending" },
      ]);
    },
  },
  {
    name: "element.add copies an image to another page under a copy id",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            addElement(
              `s-img~cp1~${COPY_UUID}`,
              P2,
              image(`s-img~cp1~${COPY_UUID}`, "s-img"),
              1,
            ),
          ]),
        ),
      ),
  },
  {
    name: "element.patch by a collaborator moves an agent",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.other,
          batchArgs([
            {
              opId: nextOpId(),
              type: "element.patch",
              elementPublicId: "s-agent",
              pagePublicId: P1,
              payload: agent("s-agent", 99),
              expectedElementRevision: await elementRevision(w, "s-agent"),
            },
          ]),
        ),
      ),
  },
  {
    name: "element.patch merged by field",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "element.patch",
              elementPublicId: "s-agent",
              pagePublicId: P1,
              payload: agent("s-agent", 55),
              expectedElementRevision: await elementRevision(w, "s-agent"),
              merge: { fields: ["position"] },
            },
          ]),
        ),
      ),
  },
  {
    name: "element.patch moves an element to another page",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "element.patch",
              elementPublicId: "s-agent",
              pagePublicId: P2,
              expectedElementRevision: await elementRevision(w, "s-agent"),
            },
          ]),
        ),
      ),
  },
  {
    name: "element.reorder",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "element.reorder",
              elementPublicId: "s-agent",
              pagePublicId: P1,
              sortIndex: 7,
              expectedElementRevision: await elementRevision(w, "s-agent"),
            },
          ]),
        ),
      ),
  },
  {
    name: "element.delete leaves a tombstone",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.other,
          batchArgs([
            {
              opId: nextOpId(),
              type: "element.delete",
              elementPublicId: "s-agent",
              pagePublicId: P1,
              expectedElementRevision: await elementRevision(w, "s-agent"),
            },
          ]),
        ),
      ),
  },
  {
    name: "element.delete of an image whose upload never came drops its placeholder",
    changesRead: true,
    setup: async (w) => {
      await seedShared("editor")(w);
      await apply(w.owner, S, [addElement("s-new-img", P1, image("s-new-img"), 3)]);
    },
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "element.delete",
              elementPublicId: "s-new-img",
              pagePublicId: P1,
              expectedElementRevision: await elementRevision(w, "s-new-img"),
            },
          ]),
        ),
      ),
    did: async (w) => {
      expect(await assetRows(w, "s-new-img")).toEqual([]);
    },
  },
  {
    name: "lineup.add",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(w.owner, batchArgs([addLineup("s-lu-new", P2)])),
      ),
  },
  {
    name: "lineup.patch renames a lineup",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.other,
          batchArgs([
            {
              opId: nextOpId(),
              type: "lineup.patch",
              lineupPublicId: "s-lu",
              pagePublicId: P1,
              payload: oneLineupPayload("s-lu", { name: "Renamed" }),
              expectedLineupRevision: await lineupRevision(w, "s-lu"),
            },
          ]),
        ),
      ),
  },
  {
    name: "lineup.reorder",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "lineup.reorder",
              lineupPublicId: "s-lu",
              pagePublicId: P1,
              sortIndex: 5,
              expectedLineupRevision: await lineupRevision(w, "s-lu"),
            },
          ]),
        ),
      ),
  },
  {
    name: "lineup.delete",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "lineup.delete",
              lineupPublicId: "s-lu",
              pagePublicId: P1,
              expectedLineupRevision: await lineupRevision(w, "s-lu"),
            },
          ]),
        ),
      ),
  },
  {
    name: "pageContent.patch changes a page's settings",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "pageContent.patch",
              pagePublicId: P1,
              settings: {
                agentSize: 40,
                abilitySize: 30,
                useNeutralTeamColors: true,
              },
              expectedPageContentRevision: await pageContentRevision(w, P1),
            },
          ]),
        ),
      ),
  },
  {
    name: "page.add",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "page.add",
              pagePublicId: "s-p3",
              payload: { name: "Page 1", isAutoNamed: true, isAttack: true },
              sortIndex: 0,
              expectedStrategyRevision: await strategyRevision(w),
            },
          ]),
        ),
      ),
  },
  {
    name: "page.add copies another page's content (\"+\")",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "page.add",
              pagePublicId: "s-p3",
              payload: { name: "Page 3", isAutoNamed: true, isAttack: true },
              sortIndex: 2,
              expectedStrategyRevision: await strategyRevision(w),
              copyContentFromPagePublicId: P1,
            },
          ]),
        ),
      ),
    did: async (w) => {
      const page = await pageRow(w, "s-p3");
      const copied = await w.t.run((ctx) =>
        ctx.db
          .query("elements")
          .withIndex("by_pageId", (q) => q.eq("pageId", page!._id))
          .collect(),
      );
      expect(copied.length).toBeGreaterThan(0);
    },
  },
  {
    name: "page.patch renames a page",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.other,
          batchArgs([
            {
              opId: nextOpId(),
              type: "page.patch",
              pagePublicId: P2,
              payload: { name: "Retake", isAutoNamed: false, isAttack: true },
              expectedPageRevision: (await pageRow(w, P2))!.revision,
            },
          ]),
        ),
      ),
  },
  {
    name: "page.reorder",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "page.reorder",
              pagePublicId: P2,
              sortIndex: 0,
              expectedStrategyRevision: await strategyRevision(w),
            },
          ]),
        ),
      ),
  },
  {
    name: "page.delete moves a page and its content to the trash",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.owner,
          batchArgs([
            {
              opId: nextOpId(),
              type: "page.delete",
              pagePublicId: P2,
              expectedStrategyRevision: await strategyRevision(w),
            },
          ]),
        ),
      ),
  },
  {
    name: "strategy.patch renames the strategy",
    changesRead: true,
    setup: seedShared("editor"),
    run: async (w, mutate) =>
      expectApplied(
        await mutate(
          w.other,
          batchArgs([
            {
              opId: nextOpId(),
              type: "strategy.patch",
              payload: {
                name: "Renamed",
                themeOverridePalette: {
                  base: "#000000",
                  detail: "#111111",
                  highlight: "#222222",
                },
              },
              expectedStrategyRevision: await strategyRevision(w),
            },
          ]),
        ),
      ),
  },
  rejectedStalePatch(),
];

/// An upload intent for [assetPublicId] in "s", as images:generateUploadUrl
/// makes one.
function uploadIntentArgs(assetPublicId: string, attempt = "attempt-1") {
  return {
    strategyPublicId: S,
    assetPublicId,
    objectKey: `strategies/${S}/${assetPublicId}-${attempt}.png`,
    uploadAttemptPublicId: attempt,
    mimeType: "image/png",
    fileExtension: ".png",
  };
}

/// "s" shared, showing "s-new-img" whose upload has started.
async function seedUploadStarted(w: World) {
  await seedShared("editor")(w);
  await apply(w.owner, S, [addElement("s-new-img", P1, image("s-new-img"), 3)]);
  const intent = (await w.owner.mutation(
    mutationRef("images:createR2UploadIntent"),
    uploadIntentArgs("s-new-img"),
  )) as { uploadId: Id<"imageAssets"> };
  w.state.uploadId = intent.uploadId;
}

/// A deleted image asset of "s", waiting for the physical sweep.
async function seedDeletedAsset(w: World, fields: Row = {}) {
  await seedShared("editor")(w);
  w.state.assetId = await insertAsset(w, S, "s-old", {
    uploadStatus: "deleted",
    deletedAt: Date.now(),
    ...fields,
  });
}

async function storeFile(w: World, contents: string) {
  return await w.t.run((ctx) => ctx.storage.store(new Blob([contents])));
}

const ledger: Record<string, LedgerEntry> = {
  "folders.js:create": {
    exempt:
      "a new folder holds no strategy and no member, so nobody's role on any strategy changes",
  },
  "folders.js:update": {
    exempt: "writes only the folder's name, icon and colour, which no full read carries",
  },
  "folders.js:move": {
    scenarios: [
      {
        name: "moving a folder into a shared folder gives its strategies the share's people",
        changesRead: true,
        setup: async (w) => {
          await createFolder(w, "team");
          await createFolder(w, "plans");
          await shareWithOther(w, "folder", "team", "editor");
          await seed(w, { folderPublicId: "plans" });
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            folderPublicId: "plans",
            parentFolderPublicId: "team",
          }),
      },
      {
        name: "moving a folder out of a shared folder takes its strategies from the share's people",
        changesRead: true,
        setup: async (w) => {
          await createFolder(w, "team");
          await createFolder(w, "plans", "team");
          await shareWithOther(w, "folder", "team", "viewer");
          await seed(w, { folderPublicId: "plans" });
        },
        run: (w, mutate) =>
          mutate(w.owner, { ...protocol, folderPublicId: "plans" }),
      },
    ],
  },
  "folders.js:delete": {
    scenarios: [
      {
        name: "deleting a shared folder takes a half-moved strategy in it from the folder's people",
        changesRead: true,
        setup: async (w) => {
          await createFolder(w, "team");
          await shareWithOther(w, "folder", "team", "viewer");
          await createStrategy(w.owner, "moving", {
            folderPublicId: "team",
            unfinishedMove: true,
          });
          await apply(w.owner, "moving", [
            addElement("moving-agent", "moving-p1", agent("moving-agent")),
          ]);
        },
        run: (w, mutate) =>
          mutate(w.owner, { ...protocol, folderPublicId: "team" }),
      },
    ],
  },

  "images.js:claimDeletedImageAssets": {
    scenarios: [
      {
        name: "claiming a deleted asset for the sweep",
        changesRead: false,
        setup: (w) => seedDeletedAsset(w),
        run: (w, mutate) => mutate(w.t, {}),
        did: async (w) => {
          expect(
            (await assetRow(w, w.state.assetId))!
              .cleanupClaimedAt,
          ).toBeDefined();
        },
      },
    ],
  },
  "images.js:completeLegacyUpload": {
    scenarios: [
      {
        name: "a Convex-storage upload completes the image's placeholder",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          await apply(w.owner, S, [
            addElement("s-new-img", P1, image("s-new-img"), 3),
          ]);
          w.state.storageId = await storeFile(w, "new image");
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            strategyPublicId: S,
            assetPublicId: "s-new-img",
            storageId: w.state.storageId,
            mimeType: "image/png",
            fileExtension: ".png",
          }),
      },
      {
        name: "a Convex-storage upload replaces an image's bytes",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          await insertAsset(w, S, "s-convex", {
            provider: "convex",
            objectKey: undefined,
            storageId: await storeFile(w, "first"),
          });
          await apply(w.owner, S, [
            addElement("s-convex", P2, image("s-convex"), 1),
          ]);
          w.state.storageId = await storeFile(w, "second");
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            strategyPublicId: S,
            assetPublicId: "s-convex",
            storageId: w.state.storageId,
            mimeType: "image/png",
            fileExtension: ".png",
          }),
      },
    ],
  },
  "images.js:createR2UploadIntent": {
    scenarios: [
      {
        name: "an upload intent takes over the placeholder content left",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          await apply(w.owner, S, [
            addElement("s-new-img", P1, image("s-new-img"), 3),
          ]);
        },
        run: (w, mutate) => mutate(w.owner, uploadIntentArgs("s-new-img")),
      },
      {
        name: "a new upload of an image already shown",
        changesRead: true,
        setup: seedShared("editor"),
        run: (w, mutate) => mutate(w.owner, uploadIntentArgs("s-img", "again")),
      },
    ],
  },
  "images.js:finalizeDeletedImageAsset": {
    scenarios: [
      {
        name: "the sweep removes a deleted asset's row",
        changesRead: false,
        setup: (w) => seedDeletedAsset(w, { cleanupClaimedAt: Date.now() }),
        run: (w, mutate) =>
          mutate(w.t, { assetId: w.state.assetId, r2ObjectDeleted: true }),
        did: async (w) => {
          expect(await assetRow(w, w.state.assetId)).toBeNull();
        },
      },
    ],
  },
  "images.js:markDeletedAssetRefsForStrategy": {
    scenarios: [
      {
        name: "a client deletes an image only a tombstone shows",
        changesRead: false,
        setup: async (w) => {
          await seedShared("editor")(w);
          w.state.assetId = await insertAsset(w, S, "s-dropped");
          await apply(w.owner, S, [
            addElement("s-dropped", P1, image("s-dropped"), 4),
          ]);
          await apply(w.owner, S, [
            {
              opId: nextOpId(),
              type: "element.delete",
              elementPublicId: "s-dropped",
              pagePublicId: P1,
              expectedElementRevision: 1,
            },
          ]);
        },
        run: (w, mutate) =>
          mutate(w.owner, { strategyPublicId: S, assetIds: [w.state.assetId] }),
        did: async (w) => {
          expect(
            (await assetRow(w, w.state.assetId))!.uploadStatus,
          ).toBe("deleted");
        },
      },
    ],
  },
  "images.js:markDeletedPageImageAssets": {
    exempt:
      "only queues images for the reclaim worker (assetReclaimCandidates), which no full read reads; processAssetReclaimCandidates does the marking",
  },
  "images.js:markDeletedStrategyImageAssets": {
    scenarios: [
      {
        name: "a deleted strategy's images are marked deleted",
        changesRead: false,
        settleSetup: false,
        setup: async (w) => {
          await seedShared("editor")(w);
          w.state.strategyId = (await strategyRow(w, S))!._id;
          await w.owner.mutation(mutationRef("strategies:delete"), {
            ...protocol,
            strategyPublicId: S,
            expectedRevision: await strategyRevision(w),
          });
        },
        run: (w, mutate) => mutate(w.t, { strategyId: w.state.strategyId }),
        did: async (w) => {
          expect(await assetRows(w, "s-img")).toMatchObject([
            { uploadStatus: "deleted" },
          ]);
        },
      },
      {
        name: "run against a live strategy, its shown images go",
        changesRead: true,
        setup: seedShared("editor"),
        run: async (w, mutate) =>
          mutate(w.t, { strategyId: (await strategyRow(w, S))!._id }),
      },
    ],
  },
  "images.js:markPurgedTombstoneImageAssets": {
    exempt:
      "only queues images for the reclaim worker (assetReclaimCandidates), which no full read reads; processAssetReclaimCandidates does the marking",
  },
  "images.js:markR2UploadActive": {
    scenarios: [
      {
        name: "a finished R2 upload makes its image show",
        changesRead: true,
        setup: seedUploadStarted,
        run: (w, mutate) =>
          mutate(w.owner, {
            strategyPublicId: S,
            assetPublicId: "s-new-img",
            uploadId: w.state.uploadId,
            byteSize: 120,
            mimeType: "image/png",
            fileExtension: ".png",
          }),
      },
      {
        name: "a finished re-upload replaces the image shown",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          const intent = (await w.owner.mutation(
            mutationRef("images:createR2UploadIntent"),
            uploadIntentArgs("s-img", "again"),
          )) as { uploadId: Id<"imageAssets"> };
          w.state.uploadId = intent.uploadId;
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            strategyPublicId: S,
            assetPublicId: "s-img",
            uploadId: w.state.uploadId,
            byteSize: 140,
            mimeType: "image/png",
            fileExtension: ".png",
          }),
      },
    ],
  },
  "images.js:markR2UploadFailed": {
    scenarios: [
      {
        name: "a failed R2 upload",
        changesRead: true,
        setup: seedUploadStarted,
        run: (w, mutate) =>
          mutate(w.t, { uploadId: w.state.uploadId, reason: "gone" }),
      },
    ],
  },
  "images.js:markStaleImageUploadsDeleted": {
    scenarios: [
      {
        name: "an upload that never came is given up on",
        changesRead: true,
        setup: async (w) => {
          await seedUploadStarted(w);
          vi.setSystemTime(Date.now() + 2 * DAY_MS);
        },
        run: (w, mutate) => mutate(w.t, {}),
      },
    ],
  },
  "images.js:processAssetReclaimCandidates": {
    scenarios: [
      {
        name: "an image whose last tombstone was purged is marked deleted",
        changesRead: false,
        settleSetup: false,
        setup: async (w) => {
          await seedShared("editor")(w);
          await apply(w.owner, S, [
            {
              opId: nextOpId(),
              type: "element.delete",
              elementPublicId: "s-img",
              pagePublicId: P1,
              expectedElementRevision: await elementRevision(w, "s-img"),
            },
          ]);
          await settle(w);
          vi.setSystemTime(Date.now() + 31 * DAY_MS);
          // Queues the image; the worker it schedules is the mutation run.
          await w.t.mutation(mutationRef("maintenance:purgeOldTombstones"), {});
        },
        run: (w, mutate) => mutate(w.t, {}),
        did: async (w) => {
          expect(await assetRows(w, "s-img")).toMatchObject([
            { uploadStatus: "deleted" },
          ]);
        },
      },
    ],
  },
  "images.js:releaseImageAssetDeletionClaims": {
    scenarios: [
      {
        name: "a failed sweep releases its claims",
        changesRead: false,
        setup: (w) => seedDeletedAsset(w, { cleanupClaimedAt: Date.now() }),
        run: (w, mutate) =>
          mutate(w.t, { assetIds: [w.state.assetId], retryAfterMs: 0 }),
        did: async (w) => {
          expect(
            (await assetRow(w, w.state.assetId))!
              .cleanupClaimedAt,
          ).toBeUndefined();
        },
      },
    ],
  },
  "images.js:scheduleDeletedImageAssetSweep": {
    exempt: "only schedules the sweep action; it writes no row",
  },

  "invites.js:create": {
    exempt: "adds an invite token; nobody's role changes until it is redeemed",
  },
  "invites.js:redeem": {
    scenarios: [
      {
        name: "redeeming an invite gives its role",
        changesRead: true,
        setup: async (w) => {
          await seed(w);
          await w.owner.mutation(mutationRef("invites:create"), {
            ...protocol,
            strategyPublicId: S,
            token: "invite",
            role: "editor",
          });
        },
        run: (w, mutate) => mutate(w.other, { ...protocol, token: "invite" }),
      },
    ],
  },
  "invites.js:revoke": {
    exempt:
      "marks the invite revoked; whoever redeemed it keeps their role (roles come only from collaborator rows)",
  },

  "maintenance.js:backfillAssetReferences": {
    exempt:
      "writes only assetReferences and completedBackfills rows, which no full read reads, and schedules other passes that have their own entries",
  },
  "maintenance.js:backfillStrategyAgentSummaries": {
    exempt: "writes only strategyAgentSummaries rows, which no full read reads",
  },
  "maintenance.js:foldContentChanges": {
    scenarios: [
      {
        name: "folding old change rows, a young one left, changes no answer",
        changesRead: false,
        answersUnchanged: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          vi.advanceTimersByTime(2 * 60 * 1000);
          // Younger than a minute: left for a later fold.
          await apply(w.owner, S, [addElement("s-late", P2, agent("s-late"), 1)]);
          // A deleted strategy's rows fold away with its count.
          await createStrategy(w.owner, "doomed");
          await w.owner.mutation(mutationRef("strategies:delete"), {
            ...protocol,
            strategyPublicId: "doomed",
            expectedRevision: await strategyRevision(w, "doomed"),
          });
        },
        run: (w, mutate) => mutate(w.t, {}),
        did: async (w) => {
          const rows = await w.t.run(async (ctx) => ({
            folded: (await ctx.db.query("strategyContentVersions").collect())
              .length,
            unfolded: (await ctx.db.query("strategyContentChanges").collect())
              .length,
          }));
          expect(rows.folded).toBeGreaterThan(0);
          expect(rows.unfolded).toBeGreaterThan(0);
        },
      },
    ],
  },
  "maintenance.js:purgeDeletedPageOrphans": {
    scenarios: [
      {
        name: "content left by a page deleted before the trash is purged",
        changesRead: false,
        setup: async (w) => {
          await seedShared("editor")(w);
          const page = await pageRow(w, P2);
          w.state.pageId = page!._id;
          w.state.strategyId = page!.strategyId;
          // A page deleted the way pages were before the trash: its row
          // went, its content stayed for this purge.
          await w.t.run(async (ctx) => {
            const contents = await ctx.db
              .query("pageContents")
              .withIndex("by_pageId", (q) => q.eq("pageId", page!._id))
              .collect();
            for (const content of contents) await ctx.db.delete(content._id);
            await ctx.db.delete(page!._id);
          });
        },
        run: (w, mutate) =>
          mutate(w.t, { pageId: w.state.pageId, strategyId: w.state.strategyId }),
        did: async (w) => {
          expect(await elementRow(w, "s-agent-2")).toBeNull();
        },
      },
    ],
  },
  "maintenance.js:purgeOldOperationEvents": {
    exempt: "deletes only operationEvents rows, which no full read reads",
  },
  "maintenance.js:purgeOldTombstones": {
    scenarios: [
      {
        name: "an element tombstone past retention is purged",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          vi.setSystemTime(Date.now() + 31 * DAY_MS);
        },
        run: (w, mutate) => mutate(w.t, {}),
        did: async (w) => {
          expect(await elementRow(w, "s-gone")).toBeNull();
        },
      },
      {
        name: "a lineup tombstone past retention is purged",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          await apply(w.owner, S, [
            {
              opId: nextOpId(),
              type: "lineup.delete",
              lineupPublicId: "s-lu",
              pagePublicId: P1,
              expectedLineupRevision: await lineupRevision(w, "s-lu"),
            },
          ]);
          // Purge the element tombstone first, so the run below has only
          // the lineup to purge.
          vi.setSystemTime(Date.now() + 31 * DAY_MS);
          await w.t.mutation(mutationRef("maintenance:purgeOldTombstones"), {});
          await settle(w);
          await apply(w.owner, S, [
            {
              opId: nextOpId(),
              type: "lineup.add",
              lineupPublicId: "s-lu-3",
              pagePublicId: P1,
              payload: oneLineupPayload("s-lu-3"),
              sortIndex: 2,
            },
          ]);
          await apply(w.owner, S, [
            {
              opId: nextOpId(),
              type: "lineup.delete",
              lineupPublicId: "s-lu-3",
              pagePublicId: P1,
              expectedLineupRevision: 1,
            },
          ]);
          vi.setSystemTime(Date.now() + 31 * DAY_MS);
        },
        run: (w, mutate) => mutate(w.t, {}),
      },
    ],
  },
  "maintenance.js:purgeTrashedPages": {
    scenarios: [
      {
        name: "a page past its time in the trash is purged",
        changesRead: false,
        setup: async (w) => {
          await seedShared("editor")(w);
          await w.owner.mutation(mutationRef("pages:delete"), {
            ...protocol,
            strategyPublicId: S,
            pagePublicId: P2,
            expectedRevision: await strategyRevision(w),
          });
          vi.setSystemTime(Date.now() + PAGE_TRASH_RETENTION_MS + 1);
        },
        run: (w, mutate) => mutate(w.t, {}),
        did: async (w) => {
          expect(await pageRow(w, P2)).toBeNull();
        },
      },
    ],
  },

  "ops.js:applyBatch": { scenarios: applyBatch },

  "pages.js:add": {
    scenarios: [
      {
        name: "adding a page first renumbers the auto-named ones",
        changesRead: true,
        setup: seedShared("editor"),
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            expectedRevision: await strategyRevision(w),
            pagePublicId: "s-p3",
            name: "Page 1",
            isAutoNamed: true,
            sortIndex: 0,
            isAttack: true,
          }),
      },
    ],
  },
  "pages.js:delete": {
    scenarios: [
      {
        name: "deleting a page moves it to the trash",
        changesRead: true,
        setup: seedShared("editor"),
        run: async (w, mutate) =>
          mutate(w.other, {
            ...protocol,
            strategyPublicId: S,
            pagePublicId: P2,
            expectedRevision: await strategyRevision(w),
          }),
      },
    ],
  },
  "pages.js:rename": {
    scenarios: [
      {
        name: "renaming a page",
        changesRead: true,
        setup: seedShared("editor"),
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            pagePublicId: P1,
            name: "Execute",
            isAutoNamed: false,
            expectedRevision: (await pageRow(w, P1))!.revision,
          }),
      },
    ],
  },
  "pages.js:reorder": {
    scenarios: [
      {
        name: "reordering pages",
        changesRead: true,
        setup: seedShared("editor"),
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            orderedPagePublicIds: [P2, P1],
            expectedRevision: await strategyRevision(w),
          }),
      },
    ],
  },
  "pages.js:restore": {
    scenarios: [
      {
        name: "restoring a page brings it back with its content",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          await w.owner.mutation(mutationRef("pages:delete"), {
            ...protocol,
            strategyPublicId: S,
            pagePublicId: P2,
            expectedRevision: await strategyRevision(w),
          });
        },
        run: (w, mutate) =>
          mutate(w.other, {
            ...protocol,
            strategyPublicId: S,
            pagePublicId: P2,
          }),
      },
    ],
  },

  "presence.js:issueRoomPass": {
    exempt: "writes nothing: it checks access and signs a short-lived pass",
  },

  "shares.js:create": {
    exempt:
      "adds a share link; nobody's role changes until someone redeems it (a link-holder's token read is not an offline copy)",
  },
  "shares.js:leave": {
    scenarios: [
      {
        name: "leaving a strategy",
        changesRead: true,
        setup: seedShared("editor"),
        run: (w, mutate) =>
          mutate(w.other, {
            ...protocol,
            targetType: "strategy",
            targetPublicId: S,
          }),
      },
      {
        name: "leaving the folder a strategy sits in",
        changesRead: true,
        setup: seedInSharedFolder("viewer"),
        run: (w, mutate) =>
          mutate(w.other, {
            ...protocol,
            targetType: "folder",
            targetPublicId: "team",
          }),
      },
    ],
  },
  "shares.js:redeem": {
    scenarios: [
      {
        name: "redeeming a strategy link",
        changesRead: true,
        setup: async (w) => {
          await seed(w);
          await createLink(w, "strategy", S, "viewer", "join");
        },
        run: (w, mutate) => mutate(w.other, { ...protocol, token: "join" }),
      },
      {
        name: "redeeming a link to the folder a strategy sits in",
        changesRead: true,
        setup: async (w) => {
          await createFolder(w, "team");
          await seed(w, { folderPublicId: "team" });
          await createLink(w, "folder", "team", "editor", "join");
        },
        run: (w, mutate) => mutate(w.other, { ...protocol, token: "join" }),
      },
      {
        name: "redeeming an editor link raises a viewer's role",
        changesRead: true,
        setup: async (w) => {
          await seedShared("viewer")(w);
          await createLink(w, "strategy", S, "editor", "promote");
        },
        run: (w, mutate) => mutate(w.other, { ...protocol, token: "promote" }),
      },
    ],
  },
  "shares.js:removeLinkMembersBatch": {
    scenarios: [
      {
        name: "a later batch of a disabled link's joiners is removed",
        changesRead: true,
        setup: async (w) => {
          await seedShared("viewer")(w);
          w.state.linkId = await linkId(w, w.state.token);
        },
        run: (w, mutate) => mutate(w.t, { linkId: w.state.linkId }),
      },
    ],
  },
  "shares.js:removeMember": {
    scenarios: [
      {
        name: "the owner removes a strategy's member",
        changesRead: true,
        setup: async (w) => {
          await seedShared("editor")(w);
          w.state.memberId = await memberIdOf(w, "strategy", S);
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "strategy",
            targetPublicId: S,
            memberId: w.state.memberId,
          }),
      },
      {
        name: "the owner removes a member of the folder a strategy sits in",
        changesRead: true,
        setup: async (w) => {
          await seedInSharedFolder("editor")(w);
          w.state.memberId = await memberIdOf(w, "folder", "team");
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "folder",
            targetPublicId: "team",
            memberId: w.state.memberId,
          }),
      },
    ],
  },
  "shares.js:revoke": {
    scenarios: [
      {
        name: "disabling a strategy link removes the people it let in",
        changesRead: true,
        setup: seedShared("viewer"),
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "strategy",
            targetPublicId: S,
            token: w.state.token,
            removeMembers: true,
          }),
      },
      {
        name: "disabling a folder link removes the people it let in",
        changesRead: true,
        setup: seedInSharedFolder("editor"),
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "folder",
            targetPublicId: "team",
            token: w.state.token,
            removeMembers: true,
          }),
      },
      {
        name: "disabling a link the old way keeps the people it let in",
        changesRead: false,
        setup: seedShared("viewer"),
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "strategy",
            targetPublicId: S,
            token: w.state.token,
          }),
        did: async (w) => {
          const link = await w.t.run((ctx) =>
            ctx.db
              .query("shareLinks")
              .withIndex("by_token", (q) => q.eq("token", w.state.token))
              .first(),
          );
          expect(link!.revokedAt).toBeDefined();
        },
      },
    ],
  },
  "shares.js:setMemberRole": {
    scenarios: [
      {
        name: "the owner makes a strategy's viewer an editor",
        changesRead: true,
        setup: async (w) => {
          await seedShared("viewer")(w);
          w.state.memberId = await memberIdOf(w, "strategy", S);
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "strategy",
            targetPublicId: S,
            memberId: w.state.memberId,
            role: "editor",
          }),
      },
      {
        name: "the owner makes an editor of the folder a strategy sits in a viewer",
        changesRead: true,
        setup: async (w) => {
          await seedInSharedFolder("editor")(w);
          w.state.memberId = await memberIdOf(w, "folder", "team");
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            targetType: "folder",
            targetPublicId: "team",
            memberId: w.state.memberId,
            role: "viewer",
          }),
      },
    ],
  },

  "strategies.js:abandonMove": {
    scenarios: [
      {
        name: "abandoning a half-moved strategy deletes it",
        changesRead: true,
        setup: async (w) => {
          await createStrategy(w.owner, "moving", { unfinishedMove: true });
          await apply(w.owner, "moving", [
            addElement("moving-agent", "moving-p1", agent("moving-agent")),
          ]);
        },
        run: (w, mutate) =>
          mutate(w.owner, { ...protocol, strategyPublicId: "moving" }),
      },
    ],
  },
  "strategies.js:create": {
    scenarios: [
      {
        name: "creating a strategy",
        changesRead: true,
        creates: ["new"],
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            publicId: "new",
            name: "New",
            mapData: "ascent",
          }),
      },
    ],
  },
  "strategies.js:createWithInitialPage": {
    scenarios: [
      {
        name: "creating a strategy with its first page",
        changesRead: true,
        creates: ["new"],
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            publicId: "new",
            name: "New",
            mapData: "ascent",
            initialPagePublicId: "new-p1",
            initialPageName: "Page 1",
            initialPageIsAttack: true,
          }),
      },
      {
        name: "a retry gives a strategy left without pages its first page",
        changesRead: true,
        setup: async (w) => {
          await w.t.run(async (ctx) => {
            const owner = (await ctx.db.query("users").collect()).find(
              (user) => user.externalId === "ledger|owner",
            )!;
            await ctx.db.insert("strategies", {
              publicId: "half",
              ownerId: owner._id,
              name: "Strategy half",
              mapData: "ascent",
              revision: 0,
              createdAt: Date.now(),
              updatedAt: Date.now(),
            });
          });
        },
        run: (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            publicId: "half",
            name: "Strategy half",
            mapData: "ascent",
            initialPagePublicId: "half-p1",
            initialPageName: "Page 1",
            initialPageIsAttack: true,
          }),
      },
    ],
  },
  "strategies.js:delete": {
    scenarios: [
      {
        name: "deleting a shared strategy",
        changesRead: true,
        setup: seedShared("editor"),
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            expectedRevision: await strategyRevision(w),
          }),
      },
    ],
  },
  "strategies.js:duplicate": {
    scenarios: [
      {
        name: "a collaborator duplicates a strategy into their library",
        changesRead: true,
        creates: ["s-copy"],
        setup: seedShared("editor"),
        run: (w, mutate) =>
          mutate(w.other, {
            ...protocol,
            sourceStrategyPublicId: S,
            publicId: "s-copy",
            name: "Copy",
          }),
      },
    ],
  },
  "strategies.js:finishMove": {
    scenarios: [
      {
        name: "finishing a move only lists the strategy",
        changesRead: false,
        setup: async (w) => {
          await createStrategy(w.owner, "moving", { unfinishedMove: true });
          await apply(w.owner, "moving", [
            addElement("moving-agent", "moving-p1", agent("moving-agent")),
          ]);
        },
        run: (w, mutate) =>
          mutate(w.owner, { ...protocol, strategyPublicId: "moving" }),
        did: async (w) => {
          expect((await strategyRow(w, "moving"))!.unfinishedMove).toBeUndefined();
        },
      },
    ],
  },
  "strategies.js:move": {
    scenarios: [
      {
        name: "moving a strategy into a shared folder",
        changesRead: true,
        setup: async (w) => {
          await createFolder(w, "team");
          await shareWithOther(w, "folder", "team", "viewer");
          await seed(w);
        },
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            expectedRevision: await strategyRevision(w),
            folderPublicId: "team",
          }),
      },
      {
        name: "moving a strategy out of a shared folder",
        changesRead: true,
        setup: seedInSharedFolder("editor"),
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            expectedRevision: await strategyRevision(w),
          }),
      },
    ],
  },
  "strategies.js:update": {
    scenarios: [
      {
        name: "renaming a strategy and changing its theme",
        changesRead: true,
        setup: seedShared("viewer"),
        run: async (w, mutate) =>
          mutate(w.owner, {
            ...protocol,
            strategyPublicId: S,
            expectedRevision: await strategyRevision(w),
            name: "Renamed",
            themeProfileId: "lotus-moss",
          }),
      },
    ],
  },

  "users.js:ensureCurrentUser": {
    exempt:
      "writes only the caller's own users row (name, avatar); roles are keyed by its _id, which never changes, and no full read carries a user's profile",
  },
};

// ---------------------------------------------------------------------------

/// Every mutation the deployment would register: the ones the contract
/// snapshot lists, and the ones the modules export (the snapshot is
/// regenerated by hand and can lag the source).
async function serverMutations(): Promise<string[]> {
  const here = dirname(fileURLToPath(import.meta.url));
  const spec = JSON.parse(
    readFileSync(join(here, "function_spec.json"), "utf8"),
  ) as { functions: Array<{ identifier: string; functionType: string }> };
  const identifiers = new Set(
    spec.functions
      .filter((fn) => fn.functionType === "Mutation")
      .map((fn) => fn.identifier),
  );
  for (const [path, load] of Object.entries(modules)) {
    if (path.includes("_generated") || /\.test\.ts$/.test(path)) continue;
    const exported = (await (load as () => Promise<Row>)()) as Row;
    for (const [name, value] of Object.entries(exported)) {
      if (value !== null && typeof value === "function" && value.isMutation) {
        identifiers.add(`${path.replace(/^\.\//, "").replace(/\.ts$/, "")}.js:${name}`);
      }
    }
  }
  return [...identifiers].sort();
}

describe("the content version ledger", () => {
  test("names every mutation the server has, and only those", async () => {
    expect(Object.keys(ledger).sort()).toEqual(await serverMutations());
  });

  test("every scenario-free entry gives its reason", () => {
    for (const entry of Object.values(ledger)) {
      if ("exempt" in entry) expect(entry.exempt.length).toBeGreaterThan(10);
      else expect(entry.scenarios.length).toBeGreaterThan(0);
    }
  });
});

for (const [identifier, entry] of Object.entries(ledger)) {
  if (!("scenarios" in entry)) continue;
  describe(identifier, () => {
    for (const scenario of entry.scenarios) {
      test(scenario.name, () => check(identifier, scenario), 30_000);
    }
  });
}
