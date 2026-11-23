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

type Harness = TestConvexForDataModel<DataModel>;

const strategyPublicId = "reads-name-account";
const pagePublicId = "reads-name-account-page";
const shareToken = "reads-name-account-link";

const reads = {
  "strategy:getPageList": { strategyPublicId },
  "page:getSnapshot": { strategyPublicId, pagePublicId },
  "page:getFrame": { strategyPublicId, pagePublicId },
  "page:getElementSlice": { strategyPublicId, pagePublicId, fromPublicId: "" },
} as const;

type Read = keyof typeof reads;

async function createHarness(): Promise<{
  t: TestConvexForDataModelAndIdentity<DataModel>;
  owner: Harness;
  editor: Harness;
}> {
  const t = convexTest(schema, modules);
  const signedIn = (subject: string) =>
    t.withIdentity({
      issuer: "https://reads-name-account.test",
      subject,
      tokenIdentifier: `reads-name-account|${subject}`,
      name: subject,
    });
  const owner = signedIn("owner");
  const editor = signedIn("editor");
  for (const user of [owner, editor]) {
    await user.mutation(ensureCurrentUser, protocol);
  }
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Reads name their account",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await owner.mutation(createShare, {
    ...protocol,
    targetType: "strategy",
    targetPublicId: strategyPublicId,
    token: shareToken,
    role: "editor",
  });
  await editor.mutation(redeemShare, { ...protocol, token: shareToken });
  return { t, owner, editor };
}

function read(
  who: TestConvexForDataModel<DataModel>,
  name: Read,
  more: Record<string, string> = {},
) {
  return who.query(makeFunctionReference<"query">(name), {
    ...protocol,
    ...reads[name],
    ...more,
  });
}

function refusal(promise: Promise<unknown>) {
  return promise.then(
    () => null,
    (error: Error & { data?: unknown }) => {
      const data =
        typeof error.data === "string" ? JSON.parse(error.data) : error.data;
      return `${data?.code ?? ""} ${error.message}`;
    },
  );
}

describe.each(Object.keys(reads) as Read[])("%s naming an account", (name) => {
  test("answers as an unnamed read does when the caller is that account", async () => {
    const { owner, editor } = await createHarness();
    for (const [who, subject] of [
      [owner, "owner"],
      [editor, "editor"],
    ] as const) {
      expect(await read(who, name, { accountSubject: subject })).toEqual(
        await read(who, name),
      );
    }
  });

  test("is refused when the caller is signed in as another account that may read it", async () => {
    const { editor } = await createHarness();
    expect(await read(editor, name)).not.toBeNull();
    expect(
      await refusal(read(editor, name, { accountSubject: "owner" })),
    ).toContain("ACCOUNT_MISMATCH");
  });

  test("is refused when no one is signed in, even through a share link", async () => {
    const { t } = await createHarness();
    expect(await read(t, name, { shareToken })).not.toBeNull();
    expect(
      await refusal(read(t, name, { shareToken, accountSubject: "owner" })),
    ).toContain("Unauthenticated");
  });

  test("the same read run again under another identity is refused", async () => {
    const { owner, editor } = await createHarness();
    const named = { accountSubject: "owner" };
    await read(owner, name, named);
    expect(await refusal(read(editor, name, named))).toContain(
      "ACCOUNT_MISMATCH",
    );
  });

  test("is refused for the account before the strategy is looked for", async () => {
    const { editor } = await createHarness();
    const missing = { strategyPublicId: "no-such-strategy" };
    expect(await refusal(read(editor, name, missing))).not.toContain(
      "ACCOUNT_MISMATCH",
    );
    expect(
      await refusal(
        read(editor, name, { ...missing, accountSubject: "owner" }),
      ),
    ).toContain("ACCOUNT_MISMATCH");
  });
});
