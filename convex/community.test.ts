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
const copyPost = makeFunctionReference<"mutation">("community:copyPost");
const report = makeFunctionReference<"mutation">("community:report");
const review = makeFunctionReference<"mutation">("community:review");
const listPosts = makeFunctionReference<"query">("community:listPosts");
const getPost = makeFunctionReference<"query">("community:getPost");
const listMine = makeFunctionReference<"query">("community:listMine");
const listMyStars = makeFunctionReference<"query">("community:listMyStars");
const listMyCopies = makeFunctionReference<"query">("community:listMyCopies");
const listStarred = makeFunctionReference<"query">("community:listStarred");
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const getSourceChanged = makeFunctionReference<"query">(
  "community:getSourceChanged",
);
const getViewer = makeFunctionReference<"query">("community:getViewer");
const listPostable = makeFunctionReference<"query">("community:listPostable");
const getPostPreview = makeFunctionReference<"query">(
  "community:getPostPreview",
);
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

let postCount = 0;

async function post(
  harness: Harness,
  person: Person,
  strategyPublicId: string,
  title = "B Market Execute",
): Promise<string> {
  const result = await harness.as(person).mutation(publish, {
    ...protocol,
    strategyPublicId,
    postPublicId: `post-${strategyPublicId}-${++postCount}`,
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
        postPublicId: "blank-title",
        title: "   ",
      }),
    ).rejects.toThrow("title");
  });

  test("a retried publish finds its post, and the picker lists what's posted", async () => {
    const harness = await createHarness();
    const { as } = harness;
    await seedStrategy(harness, "author", "source");
    await seedStrategy(harness, "author", "other");
    const args = {
      ...protocol,
      strategyPublicId: "source",
      postPublicId: "retried-post",
      title: "Retried",
    };
    await as("author").mutation(publish, args);
    await expect(as("author").mutation(publish, args)).resolves.toEqual({
      ok: true,
      postPublicId: "retried-post",
    });
    await expect(feed(harness)).resolves.toEqual(["Retried"]);
    const postable = await as("author").query(listPostable, {});
    expect(
      postable.map(
        (entry: { strategyPublicId: string; postPublicId: string | null }) => [
          entry.strategyPublicId,
          entry.postPublicId,
        ],
      ).sort(),
    ).toEqual([
      ["other", null],
      ["source", "retried-post"],
    ]);
    await expect(harness.t.query(listPostable, {})).resolves.toEqual([]);
  });

  test("the posting preview shows the owner's strategy as a card would", async () => {
    const harness = await createHarness();
    const { as } = harness;
    await seedStrategy(harness, "author", "source", {
      mapData: "bind",
      isAttack: false,
      agents: ["sova"],
    });
    await expect(
      as("author").query(getPostPreview, { strategyPublicId: "source" }),
    ).resolves.toEqual({
      name: "Strategy source",
      mapData: "bind",
      side: "defense",
      agentTypes: ["sova"],
    });
    await expect(
      as("reader").query(getPostPreview, { strategyPublicId: "source" }),
    ).rejects.toThrow();
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

  test("taking a post down ends its link and leaves people's copies", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source");
    const card = (await t.query(getPost, { postPublicId: postId })).post;
    await as("reader").mutation(copyPost, {
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

  test("stars and copies reach the counts and trending in batches", async () => {
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
    await as("third").mutation(copyPost, {
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
      ).copyCount,
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

  test("a copy lands in the reader's library as theirs", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source", { agents: ["jett"] });
    const postId = await post(harness, "author", "source", "Posted name");

    await expect(
      t.mutation(copyPost, {
        ...protocol,
        postPublicId: postId,
        publicId: "anon-copy",
      }),
    ).rejects.toThrow("Unauthenticated");
    await as("reader").mutation(copyPost, {
      ...protocol,
      postPublicId: postId,
      publicId: "reader-copy",
    });
    // A retry of the same save is safe.
    await expect(
      as("reader").mutation(copyPost, {
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

  test("each copy remembers its post until it leaves the library", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source");
    for (const publicId of ["first-copy", "second-copy"]) {
      await as("reader").mutation(copyPost, {
        ...protocol,
        postPublicId: postId,
        publicId,
      });
    }
    await expect(as("reader").query(listMyCopies, {})).resolves.toEqual([
      { strategyPublicId: "second-copy", postPublicId: postId },
      { strategyPublicId: "first-copy", postPublicId: postId },
    ]);
    const [copy] = (await as("reader").query(listForFolder, {})).filter(
      (entry: { publicId: string }) => entry.publicId === "second-copy",
    );
    await as("reader").mutation(deleteStrategy, {
      ...protocol,
      strategyPublicId: "second-copy",
      expectedRevision: copy.revision,
    });
    await expect(as("reader").query(listMyCopies, {})).resolves.toEqual([
      { strategyPublicId: "first-copy", postPublicId: postId },
    ]);
    await expect(t.query(listMyCopies, {})).resolves.toEqual([]);
    // Two copies still count once.
    await t.mutation(foldCountChanges, {});
    const [mine] = await as("author").query(listMine, {});
    expect(mine.copyCount).toBe(1);
    await settle(harness);
  });

  test("starred posts list newest star first, narrowed like the feed", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "ascent-one");
    await seedStrategy(harness, "author", "bind-one", { mapData: "bind" });
    await seedStrategy(harness, "author", "unstarred");
    const ascent = await post(harness, "author", "ascent-one", "Ascent one");
    const bind = await post(harness, "author", "bind-one", "Bind one");
    await post(harness, "author", "unstarred", "Not starred");
    for (const postPublicId of [ascent, bind]) {
      await as("reader").mutation(setStar, {
        ...protocol,
        postPublicId,
        starred: true,
      });
    }
    const titles = async (args: Record<string, unknown>) =>
      (await as("reader").query(listStarred, args)).posts.map(
        (card: { title: string }) => card.title,
      );
    await expect(titles({})).resolves.toEqual(["Bind one", "Ascent one"]);
    await expect(titles({ mapData: "ascent" })).resolves.toEqual(["Ascent one"]);
    await expect(titles({ text: "bind" })).resolves.toEqual(["Bind one"]);
    await as("author").mutation(takeDown, { ...protocol, postPublicId: bind });
    await expect(titles({})).resolves.toEqual(["Ascent one"]);
    await expect(t.query(listStarred, {})).resolves.toEqual({
      posts: [],
      nextCursor: null,
    });
    await settle(harness);
  });
});

describe("reports", () => {
  test("three reports hide a post until a reviewer decides", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    process.env.COMMUNITY_REVIEWERS = "someone-else, reviewer";
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source", "Reported");
    const card = (await t.query(getPost, { postPublicId: postId })).post;
    const readThrough = (shareToken: string) =>
      t.query(getFullSnapshot, {
        ...protocol,
        strategyPublicId: card.strategyPublicId,
        shareToken,
      });

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
    // Hidden from everyone but reviewers, its link included.
    await expect(t.query(getPost, { postPublicId: postId })).resolves.toBeNull();
    await expect(readThrough(card.shareToken)).rejects.toThrow(
      "Share link revoked",
    );
    const reviewed = await as("reviewer").query(getPost, { postPublicId: postId });
    expect(reviewed).toMatchObject({ status: "hidden" });
    expect(reviewed.post.shareToken).not.toBe(card.shareToken);
    await expect(readThrough(reviewed.post.shareToken)).resolves.toBeTruthy();
    await expect(
      as("reader").mutation(redeemShare, {
        ...protocol,
        token: reviewed.post.shareToken,
      }),
    ).rejects.toThrow("Forbidden");

    await expect(as("reader").query(listForReview, {})).rejects.toThrow(
      "Forbidden",
    );
    await expect(as("reviewer").query(getViewer, {})).resolves.toMatchObject({
      isReviewer: true,
      canPost: true,
    });
    const queue = await as("reviewer").query(listForReview, {});
    expect(queue).toHaveLength(1);
    expect(queue[0]).toMatchObject({ reportCount: 3, hidden: true, post: { title: "Reported" } });
    expect(queue[0].post.shareToken).toBe(reviewed.post.shareToken);
    // What was reported stays as it was until a reviewer decides.
    for (const change of [{ refresh: true }, { title: "Cleaned up" }]) {
      await expect(
        as("author").mutation(updatePost, {
          ...protocol,
          postPublicId: postId,
          ...change,
        }),
      ).rejects.toThrow("being reviewed");
    }
    // Nor can the author take it down and post it again to skip the review.
    await expect(
      as("author").mutation(takeDown, { ...protocol, postPublicId: postId }),
    ).rejects.toThrow("being reviewed");
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
    await expect(readThrough(card.shareToken)).resolves.toBeTruthy();
    await expect(readThrough(reviewed.post.shareToken)).rejects.toThrow();
    await expect(
      as("reviewer").query(getReports, { postPublicId: postId }),
    ).resolves.toEqual([]);
    await settle(harness);
  });

  test("a post a reviewer put back stays up when reported again, and the reviewers are told once", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    process.env.COMMUNITY_REVIEWERS = "reviewer";
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source", "Cleared");
    const card = (await t.query(getPost, { postPublicId: postId })).post;
    const reportAs = (person: Person) =>
      as(person).mutation(report, {
        ...protocol,
        postPublicId: postId,
        reason: "offensive",
      });
    const queue = () => as("reviewer").query(listForReview, {});
    for (const person of ["reader", "second", "third"] as const) {
      await reportAs(person);
    }
    await as("reviewer").mutation(review, {
      ...protocol,
      postPublicId: postId,
      decision: "restore",
    });
    await settle(harness);

    // The same three report it again: it stays in the feed, and waits for
    // the reviewers with its ordinary link.
    for (const person of ["reader", "second", "third"] as const) {
      await reportAs(person);
    }
    await expect(feed(harness)).resolves.toEqual(["Cleared"]);
    await expect(t.query(getPost, { postPublicId: postId })).resolves.toMatchObject(
      { status: "listed" },
    );
    const waiting = await queue();
    expect(waiting).toHaveLength(1);
    expect(waiting[0]).toMatchObject({ reportCount: 3, hidden: false, post: { title: "Cleared" } });
    expect(waiting[0].post.shareToken).toBe(card.shareToken);
    await expect(
      as("reviewer").query(getReports, { postPublicId: postId }),
    ).resolves.toEqual([{ reason: "offensive", count: 3, notes: [] }]);
    // A fourth report counts but tells nobody again.
    await reportAs("reviewer");
    const notified = await t.run(async (ctx) =>
      (await ctx.db.system.query("_scheduled_functions").collect())
        .filter((job) => job.name.includes("notifyReviewers"))
        .map((job) => job.args[0]),
    );
    expect(notified).toEqual([
      expect.objectContaining({ hidden: true, reportCount: 3 }),
      expect.objectContaining({ hidden: false, reportCount: 3 }),
    ]);
    expect((await queue())[0].reportCount).toBe(4);

    // Restoring again starts the count over, and the post leaves the list.
    await as("reviewer").mutation(review, {
      ...protocol,
      postPublicId: postId,
      decision: "restore",
    });
    await expect(queue()).resolves.toEqual([]);
    await reportAs("reader");
    await expect(queue()).resolves.toEqual([]);
    await settle(harness);
  });

  test("an author changing a cleared post ends the clearance", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    process.env.COMMUNITY_REVIEWERS = "reviewer";
    await seedStrategy(harness, "author", "source");
    await seedStrategy(harness, "author", "other");
    const postId = await post(harness, "author", "source", "Cleared");
    const otherId = await post(harness, "author", "other", "Other");
    const reportAs = (person: Person, postPublicId: string) =>
      as(person).mutation(report, {
        ...protocol,
        postPublicId,
        reason: "picture",
      });
    for (const id of [postId, otherId]) {
      for (const person of ["reader", "second", "third"] as const) {
        await reportAs(person, id);
      }
      await as("reviewer").mutation(review, {
        ...protocol,
        postPublicId: id,
        decision: "restore",
      });
    }

    // Reported enough again, then renamed: it is hidden at once.
    for (const person of ["reader", "second", "third"] as const) {
      await reportAs(person, postId);
    }
    await as("author").mutation(updatePost, {
      ...protocol,
      postPublicId: postId,
      title: "Renamed",
    });
    await expect(t.query(getPost, { postPublicId: postId })).resolves.toBeNull();
    const [waiting] = await as("reviewer").query(listForReview, {});
    expect(waiting).toMatchObject({ reportCount: 3, post: { title: "Renamed" } });
    // Opened through the link only reviewers are given.
    expect(waiting.post.shareToken).toBe(
      (await as("reviewer").query(getPost, { postPublicId: postId })).post
        .shareToken,
    );
    await expect(
      t.query(getFullSnapshot, {
        ...protocol,
        strategyPublicId: waiting.post.strategyPublicId,
        shareToken: waiting.post.shareToken,
      }),
    ).resolves.toBeTruthy();

    // Refreshed with one report waiting: still up, but the next reports
    // hide it as they would any post.
    await reportAs("reader", otherId);
    await as("author").mutation(updatePost, {
      ...protocol,
      postPublicId: otherId,
      refresh: true,
    });
    await expect(feed(harness)).resolves.toEqual(["Other"]);
    await reportAs("second", otherId);
    await reportAs("third", otherId);
    await expect(feed(harness)).resolves.toEqual([]);
    await settle(harness);
  });

  test("a ban removes the post and stops its author posting", async () => {
    const harness = await createHarness();
    const { as } = harness;
    process.env.COMMUNITY_REVIEWERS = "reviewer";
    await seedStrategy(harness, "author", "source");
    await seedStrategy(harness, "author", "another");
    await seedStrategy(harness, "author", "third-strategy");
    const postId = await post(harness, "author", "source");
    const otherPostId = await post(harness, "author", "third-strategy", "Other");
    await as("reviewer").mutation(review, {
      ...protocol,
      postPublicId: postId,
      decision: "ban",
    });
    await expect(feed(harness)).resolves.toEqual(["Other"]);
    // Their other posts stay up, but they can't change what those show.
    await expect(
      as("author").mutation(updatePost, {
        ...protocol,
        postPublicId: otherPostId,
        title: "Renamed",
        refresh: true,
      }),
    ).rejects.toThrow("Forbidden");
    await expect(as("author").query(getViewer, {})).resolves.toMatchObject({
      isReviewer: false,
      canPost: false,
      authorName: "author",
    });
    await expect(post(harness, "author", "another")).rejects.toThrow(
      "Forbidden",
    );
    await settle(harness);
  });
});

describe("limits", () => {
  const HOUR = 60 * 60 * 1000;

  test("an account posts at most ten times an hour, taken-down posts included", async () => {
    const harness = await createHarness();
    const { as } = harness;
    for (let index = 0; index < 11; index++) {
      await seedStrategy(harness, "author", `s${index}`);
    }
    const publishArgs = (index: number) => ({
      ...protocol,
      strategyPublicId: `s${index}`,
      postPublicId: `limited-${index}`,
      title: `Post ${index}`,
    });
    for (let index = 0; index < 10; index++) {
      await as("author").mutation(publish, publishArgs(index));
    }
    await as("author").mutation(takeDown, {
      ...protocol,
      postPublicId: "limited-0",
    });
    // A retry finds its post, limit or not.
    await expect(
      as("author").mutation(publish, publishArgs(9)),
    ).resolves.toEqual({ ok: true, postPublicId: "limited-9" });
    await expect(
      as("author").mutation(publish, publishArgs(10)),
    ).rejects.toThrow("You've posted a lot in the last hour. Try again later.");
    await expect(
      as("author").mutation(publish, publishArgs(10)),
    ).rejects.toThrow("RATE_LIMITED");
    // Someone else posts as usual.
    await seedStrategy(harness, "reader", "reader-source");
    await post(harness, "reader", "reader-source");

    vi.advanceTimersByTime(HOUR);
    await as("author").mutation(publish, publishArgs(10));
    await settle(harness);
  });

  test("an account makes at most thirty copies an hour", async () => {
    const harness = await createHarness();
    const { as } = harness;
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source");
    const copy = (publicId: string) =>
      as("reader").mutation(copyPost, {
        ...protocol,
        postPublicId: postId,
        publicId,
      });
    for (let index = 0; index < 30; index++) {
      await copy(`copy-${index}`);
    }
    await expect(copy("copy-29")).resolves.toEqual({ ok: true, reused: true });
    await expect(copy("copy-30")).rejects.toThrow(
      "You've made a lot of copies in the last hour. Try again later.",
    );
    vi.advanceTimersByTime(HOUR);
    await expect(copy("copy-30")).resolves.toEqual({ ok: true });
  });

  test("an account sends at most twenty reports a day", async () => {
    const harness = await createHarness();
    const { as } = harness;
    const posts: string[] = [];
    for (let index = 0; index < 21; index++) {
      await seedStrategy(harness, "author", `s${index}`);
      // Under the author's own posting limit.
      if (index % 10 === 0) vi.advanceTimersByTime(HOUR);
      posts.push(await post(harness, "author", `s${index}`));
    }
    const reportPost = (postPublicId: string) =>
      as("reader").mutation(report, {
        ...protocol,
        postPublicId,
        reason: "spam",
      });
    for (const postPublicId of posts.slice(0, 20)) {
      await reportPost(postPublicId);
    }
    // Reporting a post again changes nothing, limit or not.
    await expect(reportPost(posts[0])).resolves.toEqual({ ok: true });
    await expect(reportPost(posts[20])).rejects.toThrow(
      "You've sent a lot of reports today. Try again later.",
    );
    vi.advanceTimersByTime(24 * HOUR);
    await expect(reportPost(posts[20])).resolves.toEqual({ ok: true });
  });
});

describe("trending", () => {
  test("an author's own star doesn't count toward trending", async () => {
    const harness = await createHarness();
    const { t, as } = harness;
    await seedStrategy(harness, "author", "source");
    const postId = await post(harness, "author", "source");
    const trendScore = () =>
      t.run(async (ctx) => {
        const row = await ctx.db
          .query("communityPosts")
          .withIndex("by_publicId", (q) => q.eq("publicId", postId))
          .unique();
        return row!.trendScore;
      });
    await as("author").mutation(setStar, {
      ...protocol,
      postPublicId: postId,
      starred: true,
    });
    await t.mutation(foldCountChanges, {});
    await t.mutation(refreshTrending, {});
    expect(
      (await t.query(getPost, { postPublicId: postId })).post.starCount,
    ).toBe(1);
    expect(await trendScore()).toBe(0);

    await as("reader").mutation(setStar, {
      ...protocol,
      postPublicId: postId,
      starred: true,
    });
    await t.mutation(refreshTrending, {});
    expect(await trendScore()).toBe(1);
  });
});
