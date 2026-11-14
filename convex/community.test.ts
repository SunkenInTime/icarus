import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";
import { markContentTableBackfilled } from "./lib/assetReferences";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const listForFolder = makeFunctionReference<"query">(
  "strategies:listForFolder",
);
const listSharedWithMe = makeFunctionReference<"query">(
  "strategies:listSharedWithMe",
);
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const updateStrategy = makeFunctionReference<"mutation">("strategies:update");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");

const publish = makeFunctionReference<"mutation">("community:publish");
const updatePost = makeFunctionReference<"mutation">("community:updatePost");
const takeDown = makeFunctionReference<"mutation">("community:takeDown");
const setStar = makeFunctionReference<"mutation">("community:setStar");
const saveCopy = makeFunctionReference<"mutation">("community:saveCopy");
const report = makeFunctionReference<"mutation">("community:report");
const review = makeFunctionReference<"mutation">("community:review");
const listPosts = makeFunctionReference<"query">("community:listPosts");
const getPost = makeFunctionReference<"query">("community:getPost");
const listMine = makeFunctionReference<"query">("community:listMine");
const listMyStars = makeFunctionReference<"query">("community:listMyStars");
const getSourceChanged = makeFunctionReference<"query">(
  "community:getSourceChanged",
);
const getViewer = makeFunctionReference<"query">("community:getViewer");
const listForReview = makeFunctionReference<"query">(
  "community:listForReview",
);
const getReports = makeFunctionReference<"query">("community:getReports");
const foldCountChanges = makeFunctionReference<"mutation">(
  "community:foldCountChanges",
);
const refreshTrending = makeFunctionReference<"mutation">(
  "community:refreshTrending",
);

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

type Person = "author" | "reader" | "second" | "third" | "reviewer";

function identity(subject: Person) {
  return {
    issuer: "https://community.test",
    subject,
    tokenIdentifier: `community|${subject}`,
    name: subject,
  };
}

// Taking a post down schedules its snapshot's cleanup; each test runs it
// before it ends.
beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  delete process.env.COMMUNITY_REVIEWERS;
});

async function settle({ t }: Harness) {
  await t.finishAllScheduledFunctions(vi.runAllTimers);
}

async function createHarness() {
  const t = convexTest(schema, modules);
  // As on every deployment today: deleting a snapshot purges its pages
  // right away instead of waiting for this backfill.
  await t.run(async (ctx) => {
    await markContentTableBackfilled(ctx, "elements");
    await markContentTableBackfilled(ctx, "lineups");
  });
  const as = (person: Person) => t.withIdentity(identity(person));
  for (const person of [
    "author",
    "reader",
    "second",
    "third",
    "reviewer",
  ] as const) {
    await as(person).mutation(ensureCurrentUser, protocol);
  }
  return { t, as };
}

type Harness = Awaited<ReturnType<typeof createHarness>>;

/// A strategy of [person]'s on [mapData] with one page on [isAttack] and,
/// when given, agents of [agents] placed on it.
async function seedStrategy(
  { as }: Harness,
  person: Person,
  publicId: string,
  options: { mapData?: string; isAttack?: boolean; agents?: string[] } = {},
) {
  await as(person).mutation(createStrategy, {
    ...protocol,
    publicId,
    name: `Strategy ${publicId}`,
    mapData: options.mapData ?? "ascent",
    initialPagePublicId: `${publicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: options.isAttack ?? true,
  });
  const agents = options.agents ?? [];
  if (agents.length > 0) {
    await as(person).mutation(applyBatch, {
      ...protocol,
      strategyPublicId: publicId,
      clientId: "seed",
      ops: agents.map((agent, index) => ({
        opId: `add-${agent}`,
        type: "element.add",
        elementPublicId: `${publicId}-${agent}`,
        pagePublicId: `${publicId}-page`,
        payload: {
          kind: "agent",
          payloadVersion: 1,
          data: { id: `${publicId}-${agent}`, type: agent },
        },
        sortIndex: index,
      })),
    });
  }
}

async function post(
  harness: Harness,
  person: Person,
  strategyPublicId: string,
  title = "B Market Execute",
): Promise<string> {
  const result = await harness.as(person).mutation(publish, {
    ...protocol,
    strategyPublicId,
    title,
  });
  return result.postPublicId;
}

async function feed(harness: Harness, args: Record<string, unknown> = {}) {
  const page = await harness.t.query(listPosts, { sort: "new", ...args });
  return page.posts.map((card: { title: string }) => card.title);
}

describe("posting", () => {
  test("a post is a frozen copy anyone can read, in nobody's library", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source", { agents: ["jett", "sova"] });
    const postId = await post(harness, "author", "source", "  B   Market Execute ");

    const found = await t.query(getPost, { postPublicId: postId });
    expect(found).toMatchObject({
      status: "listed",
      post: {
        title: "B Market Execute",
        mapData: "ascent",
        side: "attack",
        authorName: "author",
        pageCount: 1,
        starCount: 0,
      },
    });
    expect(found.post.agentTypes.sort()).toEqual(["jett", "sova"]);
    expect(found.post.strategyPublicId).not.toBe("source");

    // Signed out, the snapshot reads through the post's token.
    const snapshot = await t.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: found.post.strategyPublicId,
      shareToken: found.post.shareToken,
    });
    expect(snapshot.header).toMatchObject({
      name: "B Market Execute",
      role: "viewer",
    });

    // The author's library holds their strategy once; nobody's Shared tab
    // gains the snapshot, and the token can't be joined.
    const library = await as("author").query(listForFolder, {});
    expect(
      library.map((entry: { publicId: string }) => entry.publicId),
    ).toEqual(["source"]);
    await expect(
      as("reader").mutation(redeemShare, {
        ...protocol,
        token: found.post.shareToken,
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      as("reader").query(listSharedWithMe, {}),
    ).resolves.toEqual([]);

    // A reader can't write to it.
    await expect(
      as("reader").mutation(updateStrategy, {
        ...protocol,
        strategyPublicId: found.post.strategyPublicId,
        expectedRevision: 0,
        name: "Defaced",
      }),
    ).rejects.toThrow();
  });

  test("only the owner posts, once per strategy", async () => {
    const harness = await createHarness();
    await seedStrategy(harness, "author", "source");
    await expect(post(harness, "reader", "source")).rejects.toThrow(
      "Forbidden",
    );
    await post(harness, "author", "source");
    await expect(post(harness, "author", "source")).rejects.toThrow(
      "already posted",
    );
    await expect(
      harness.as("author").mutation(publish, {
        ...protocol,
        strategyPublicId: "source",
        title: "   ",
      }),
    ).rejects.toThrow("title");
  });

  test("edits stay private until the author updates the post", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source", { agents: ["jett"] });
    const postId = await post(harness, "author", "source");
    const before = (await t.query(getPost, { postPublicId: postId })).post;
    await expect(
      as("author").query(getSourceChanged, { postPublicId: postId }),
    ).resolves.toEqual({ sourceExists: true, changed: false });

    await as("author").mutation(applyBatch, {
      ...protocol,
      strategyPublicId: "source",
      clientId: "edit",
      ops: [
        {
          opId: "add-omen",
          type: "element.add",
          elementPublicId: "source-omen",
          pagePublicId: "source-page",
          payload: {
            kind: "agent",
            payloadVersion: 1,
            data: { id: "source-omen", type: "omen" },
          },
          sortIndex: 5,
        },
      ],
    });
    await expect(
      as("author").query(getSourceChanged, { postPublicId: postId }),
    ).resolves.toEqual({ sourceExists: true, changed: true });
    expect(
      (await t.query(getPost, { postPublicId: postId })).post.agentTypes,
    ).toEqual(["jett"]);
    await expect(
      as("reader").query(getSourceChanged, { postPublicId: postId }),
    ).rejects.toThrow("Forbidden");

    await as("author").mutation(updatePost, {
      ...protocol,
      postPublicId: postId,
      refresh: true,
    });
    const after = (await t.query(getPost, { postPublicId: postId })).post;
    expect(after.agentTypes.sort()).toEqual(["jett", "omen"]);
    // The link someone already copied keeps working.
    expect(after.shareToken).toBe(before.shareToken);
    expect(after.strategyPublicId).not.toBe(before.strategyPublicId);
    await expect(
      t.query(getFullSnapshot, {
        ...protocol,
        strategyPublicId: after.strategyPublicId,
        shareToken: after.shareToken,
      }),
    ).resolves.toMatchObject({ header: { role: "viewer" } });
    await expect(
      as("author").query(getSourceChanged, { postPublicId: postId }),
    ).resolves.toEqual({ sourceExists: true, changed: false });
    await settle(harness);
  });

  test("taking a post down ends its link and leaves saved copies", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source");
    const card = (await t.query(getPost, { postPublicId: postId })).post;
    await as("reader").mutation(saveCopy, {
      ...protocol,
      postPublicId: postId,
      publicId: "reader-copy",
    });

    await expect(
      as("reader").mutation(takeDown, { ...protocol, postPublicId: postId }),
    ).rejects.toThrow("Forbidden");
    await as("author").mutation(takeDown, { ...protocol, postPublicId: postId });

    await expect(feed(harness)).resolves.toEqual([]);
    await expect(t.query(getPost, { postPublicId: postId })).resolves.toMatchObject(
      { status: "removed" },
    );
    await expect(
      t.query(getFullSnapshot, {
        ...protocol,
        strategyPublicId: card.strategyPublicId,
        shareToken: card.shareToken,
      }),
    ).rejects.toThrow();
    await expect(as("author").query(listMine, {})).resolves.toEqual([]);
    const readerLibrary = await as("reader").query(listForFolder, {});
    expect(
      readerLibrary.map((entry: { publicId: string }) => entry.publicId),
    ).toEqual(["reader-copy"]);
    // And the strategy can be posted again.
    await post(harness, "author", "source", "Second try");
    await settle(harness);
  });
});

describe("the feed", () => {
  test("filters by map, side and every picked agent", async () => {
    const harness = await createHarness();
    await seedStrategy(harness, "author", "a", {
      mapData: "ascent",
      agents: ["jett", "sova"],
    });
    await seedStrategy(harness, "author", "b", {
      mapData: "ascent",
      isAttack: false,
      agents: ["sova"],
    });
    await seedStrategy(harness, "author", "c", {
      mapData: "bind",
      agents: ["jett", "sova", "omen"],
    });
    await post(harness, "author", "a", "Ascent attack");
    await post(harness, "author", "b", "Ascent defense");
    await post(harness, "author", "c", "Bind attack");

    await expect(feed(harness)).resolves.toEqual([
      "Bind attack",
      "Ascent defense",
      "Ascent attack",
    ]);
    await expect(feed(harness, { mapData: "ascent" })).resolves.toEqual([
      "Ascent defense",
      "Ascent attack",
    ]);
    await expect(feed(harness, { side: "defense" })).resolves.toEqual([
      "Ascent defense",
    ]);
    await expect(
      feed(harness, { agentTypes: ["jett", "sova"] }),
    ).resolves.toEqual(["Bind attack", "Ascent attack"]);
    await expect(
      feed(harness, { mapData: "bind", agentTypes: ["omen"], sort: "trending" }),
    ).resolves.toEqual(["Bind attack"]);
    await expect(feed(harness, { text: "defense" })).resolves.toEqual([
      "Ascent defense",
    ]);
    await expect(feed(harness, { text: "author", mapData: "bind" })).resolves.toEqual([
      "Bind attack",
    ]);
  });

  test("stars and saves reach the counts and trending in batches", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "quiet");
    await seedStrategy(harness, "author", "popular");
    const quiet = await post(harness, "author", "quiet", "Quiet");
    const popular = await post(harness, "author", "popular", "Popular");

    await as("reader").mutation(setStar, {
      ...protocol,
      postPublicId: popular,
      starred: true,
    });
    // Starring twice counts once.
    await as("reader").mutation(setStar, {
      ...protocol,
      postPublicId: popular,
      starred: true,
    });
    await as("second").mutation(setStar, {
      ...protocol,
      postPublicId: popular,
      starred: true,
    });
    await as("second").mutation(setStar, {
      ...protocol,
      postPublicId: quiet,
      starred: true,
    });
    await as("second").mutation(setStar, {
      ...protocol,
      postPublicId: quiet,
      starred: false,
    });
    await as("third").mutation(saveCopy, {
      ...protocol,
      postPublicId: quiet,
      publicId: "third-copy",
    });
    await expect(as("second").query(listMyStars, {})).resolves.toEqual([
      popular,
    ]);
    await expect(t.query(listMyStars, {})).resolves.toEqual([]);

    // Nothing reaches the post rows until the fold.
    expect(
      (await t.query(getPost, { postPublicId: popular })).post.starCount,
    ).toBe(0);
    await t.mutation(foldCountChanges, {});
    expect(
      (await t.query(getPost, { postPublicId: popular })).post.starCount,
    ).toBe(2);
    expect(
      (await t.query(getPost, { postPublicId: quiet })).post.starCount,
    ).toBe(0);
    const mine = await as("author").query(listMine, {});
    expect(
      mine.find((entry: { post: { publicId: string } }) =>
        entry.post.publicId === quiet,
      ).saveCount,
    ).toBe(1);

    await expect(feed(harness, { sort: "top" })).resolves.toEqual([
      "Popular",
      "Quiet",
    ]);
    // Trending counts a save twice: Quiet's one save ties Popular's two
    // stars, and the newer post comes first.
    await t.mutation(refreshTrending, {});
    await expect(feed(harness, { sort: "trending" })).resolves.toEqual([
      "Popular",
      "Quiet",
    ]);
  });

  test("a saved copy lands in the reader's library as theirs", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source", { agents: ["jett"] });
    const postId = await post(harness, "author", "source", "Posted name");

    await expect(
      t.mutation(saveCopy, {
        ...protocol,
        postPublicId: postId,
        publicId: "anon-copy",
      }),
    ).rejects.toThrow("Unauthenticated");
    await as("reader").mutation(saveCopy, {
      ...protocol,
      postPublicId: postId,
      publicId: "reader-copy",
    });
    // A retry of the same save is safe.
    await expect(
      as("reader").mutation(saveCopy, {
        ...protocol,
        postPublicId: postId,
        publicId: "reader-copy",
      }),
    ).resolves.toEqual({ ok: true, reused: true });
    const library = await as("reader").query(listForFolder, {});
    expect(library).toHaveLength(1);
    expect(library[0]).toMatchObject({
      publicId: "reader-copy",
      name: "Posted name",
      role: "owner",
    });
  });
});

describe("reports", () => {
  test("three reports hide a post until a reviewer decides", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    process.env.COMMUNITY_REVIEWERS = "someone-else, reviewer";
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source", "Reported");

    for (const person of ["reader", "reader", "second"] as const) {
      await as(person).mutation(report, {
        ...protocol,
        postPublicId: postId,
        reason: "picture",
        note: "Page 4, the picture in the corner",
      });
    }
    // The same account reporting twice counts once.
    await expect(feed(harness)).resolves.toEqual(["Reported"]);
    await as("third").mutation(report, {
      ...protocol,
      postPublicId: postId,
      reason: "offensive",
    });
    await expect(feed(harness)).resolves.toEqual([]);
    await expect(t.query(getPost, { postPublicId: postId })).resolves.toMatchObject(
      { status: "hidden" },
    );

    await expect(as("reader").query(listForReview, {})).rejects.toThrow(
      "Forbidden",
    );
    await expect(as("reviewer").query(getViewer, {})).resolves.toEqual({
      isReviewer: true,
      canPost: true,
    });
    const queue = await as("reviewer").query(listForReview, {});
    expect(queue).toHaveLength(1);
    expect(queue[0]).toMatchObject({ reportCount: 3, post: { title: "Reported" } });
    await expect(
      as("reviewer").query(getReports, { postPublicId: postId }),
    ).resolves.toEqual([
      {
        reason: "picture",
        count: 2,
        notes: [
          "Page 4, the picture in the corner",
          "Page 4, the picture in the corner",
        ],
      },
      { reason: "offensive", count: 1, notes: [] },
    ]);

    await expect(
      as("author").mutation(review, {
        ...protocol,
        postPublicId: postId,
        decision: "restore",
      }),
    ).rejects.toThrow("Forbidden");
    await as("reviewer").mutation(review, {
      ...protocol,
      postPublicId: postId,
      decision: "restore",
    });
    await expect(feed(harness)).resolves.toEqual(["Reported"]);
    await expect(
      as("reviewer").query(getReports, { postPublicId: postId }),
    ).resolves.toEqual([]);
    await settle(harness);
  });

  test("a ban removes the post and stops its author posting", async () => {
    const harness = await createHarness();
    const { as } = harness;
    process.env.COMMUNITY_REVIEWERS = "reviewer";
    await seedStrategy(harness, "author", "source");
    await seedStrategy(harness, "author", "another");
    const postId = await post(harness, "author", "source");
    await as("reviewer").mutation(review, {
      ...protocol,
      postPublicId: postId,
      decision: "ban",
    });
    await expect(feed(harness)).resolves.toEqual([]);
    await expect(as("author").query(getViewer, {})).resolves.toEqual({
      isReviewer: false,
      canPost: false,
    });
    await expect(post(harness, "author", "another")).rejects.toThrow(
      "Forbidden",
    );
    await settle(harness);
  });
});
