import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import {
  CURRENT_CLOUD_PROTOCOL_VERSION,
  MAX_CLOUD_OPERATION_BYTES,
} from "./lib/cloudProtocol";
import { keepLaterFields, withoutLaterFields } from "./lib/elementFields";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const duplicateStrategy = makeFunctionReference<"mutation">(
  "strategies:duplicate",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const getElementSlice = makeFunctionReference<"query">("page:getElementSlice");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const listForPage = makeFunctionReference<"query">("elements:listForPage");
const listForStrategy = makeFunctionReference<"query">(
  "elements:listForStrategy",
);

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Row = Record<string, any>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategy = "caption-strategy";
const page = "caption-page";
const note = "Plant behind the box";

/// What a shipped build sends: picture ids, and no field level.
const oldBuild = { acceptsPictureIds: true };
const captionsBuild = { acceptsPictureIds: true, elementFieldLevel: 1 };

/// A strategy holding "jett", an agent with a caption, and "plain", an agent
/// without one.
async function seed(): Promise<{ t: RootHarness; owner: Harness }> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity({
    issuer: "https://caption.test",
    subject: "owner",
    tokenIdentifier: "caption|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategy,
    name: "Captions",
    mapData: "ascent",
    initialPagePublicId: page,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await send(owner, captionsBuild, "seed", [
    add("add-jett", agentData("jett", { caption: note })),
    add("add-plain", agentData("plain")),
  ]);
  return { t, owner };
}

function agentData(id: string, fields: Record<string, unknown> = {}) {
  return { id, type: "jett", position: { dx: 10, dy: 20 }, ...fields };
}

function agentPayload(data: Record<string, unknown>) {
  return { kind: "agent", payloadVersion: 1, data };
}

function add(opId: string, data: Record<string, unknown>) {
  return {
    opId,
    type: "element.add",
    elementPublicId: data.id,
    pagePublicId: page,
    payload: agentPayload(data),
    sortIndex: 0,
  };
}

function patch(
  opId: string,
  id: string,
  expectedElementRevision: number,
  data: Record<string, unknown>,
  merge?: { fields: string[] },
) {
  return {
    opId,
    type: "element.patch",
    elementPublicId: id,
    expectedElementRevision,
    payload: agentPayload(data),
    ...(merge === undefined ? {} : { merge }),
  };
}

async function send(
  owner: Harness,
  client: Record<string, unknown>,
  clientId: string,
  ops: unknown[],
) {
  const { results } = (await owner.mutation(applyBatch, {
    ...protocol,
    ...client,
    strategyPublicId: strategy,
    clientId,
    ops,
  })) as { results: Row[] };
  return results;
}

async function row(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) =>
    (await ctx.db.query("elements").collect()).find(
      (element) => element.publicId === publicId,
    ),
  );
}

/// Every read a client can make of the page's elements.
async function reads(owner: Harness, client: Record<string, unknown>) {
  const scope = { ...protocol, strategyPublicId: strategy };
  const level = { elementFieldLevel: client.elementFieldLevel };
  const results: Record<string, Row[]> = {
    pageSnapshot: (
      (await owner.query(getPageSnapshot, {
        ...scope,
        ...client,
        pagePublicId: page,
      })) as { elements: Row[] }
    ).elements,
    elementSlice: (
      (await owner.query(getElementSlice, {
        ...scope,
        ...level,
        pagePublicId: page,
        fromPublicId: "",
      })) as { elements: Row[] }
    ).elements,
    fullSnapshot: (
      (await owner.query(getFullSnapshot, { ...scope, ...client })) as {
        elements: Row[];
      }
    ).elements,
    listForPage: (await owner.query(listForPage, {
      ...scope,
      ...level,
      pagePublicId: page,
    })) as Row[],
    listForStrategy: (await owner.query(listForStrategy, {
      ...scope,
      ...level,
    })) as Row[],
  };
  return Object.entries(results);
}

function find(elements: Row[], id: string) {
  return elements.find((element) => element.publicId === id)!;
}

describe("a caption and the builds that don't know it", () => {
  test("no read gives a shipped build the field", async () => {
    const { owner } = await seed();

    for (const [name, elements] of await reads(owner, oldBuild)) {
      expect(find(elements, "jett").payload.data, name).toEqual(
        agentData("jett"),
      );
    }
  });

  test("every read gives a build at the field's level the field", async () => {
    const { owner } = await seed();

    for (const [name, elements] of await reads(owner, captionsBuild)) {
      expect(find(elements, "jett").payload.data, name).toEqual(
        agentData("jett", { caption: note }),
      );
    }
  });

  test("a rejected op doesn't hand a shipped build the field", async () => {
    const { owner } = await seed();

    const results = await send(owner, oldBuild, "old", [
      patch("stale", "jett", 99, agentData("jett", { position: { dx: 1, dy: 1 } })),
    ]);

    expect(results[0]!.reason).toBe("revision_mismatch");
    expect(results[0]!.current.value.data).toEqual(agentData("jett"));
  });

  test("a move merged by field leaves the caption", async () => {
    const { t, owner } = await seed();
    const moved = { position: { dx: 50, dy: 60 } };

    await send(owner, oldBuild, "old", [
      patch("move", "jett", 1, agentData("jett", moved), {
        fields: ["position"],
      }),
    ]);

    expect((await row(t, "jett"))!.payload.data).toEqual(
      agentData("jett", { ...moved, caption: note }),
    );
  });

  test("a merge naming the field without a value leaves the caption", async () => {
    const { t, owner } = await seed();

    const results = await send(owner, oldBuild, "old", [
      patch("erase", "jett", 1, agentData("jett"), { fields: ["caption"] }),
    ]);

    expect(results[0]!.status).toBe("noop");
    expect((await row(t, "jett"))!.payload.data.caption).toBe(note);
  });

  test("a whole write leaves the caption", async () => {
    const { t, owner } = await seed();
    const changed = { state: "viewCone" };

    await send(owner, oldBuild, "old", [
      patch("whole", "jett", 1, agentData("jett", changed)),
    ]);

    expect((await row(t, "jett"))!.payload.data).toEqual(
      agentData("jett", { ...changed, caption: note }),
    );
  });

  test("an old build's undo of a delete brings the caption back", async () => {
    const { t, owner } = await seed();

    const deletion = await send(owner, oldBuild, "old", [
      {
        opId: "delete",
        type: "element.delete",
        elementPublicId: "jett",
        pagePublicId: page,
        expectedElementRevision: 1,
      },
    ]);
    expect(deletion[0]!.status).toBe("applied");
    expect((await row(t, "jett"))!.deleted).toBe(true);

    const undo = await send(owner, oldBuild, "old", [
      { ...add("restore", agentData("jett")), expectedElementRevision: 2 },
    ]);

    expect(undo[0]!.status).toBe("applied");
    const restored = (await row(t, "jett"))!;
    expect(restored.deleted).toBe(false);
    expect(restored.payload.data.caption).toBe(note);
  });

  test("an op queued by an old build keeps the caption when an updated build sends it", async () => {
    const { t, owner } = await seed();

    const changed = { state: "viewCone" };

    await send(owner, captionsBuild, "updated", [
      patch("queued", "jett", 1, agentData("jett", changed)),
    ]);

    expect((await row(t, "jett"))!.payload.data).toEqual(
      agentData("jett", { ...changed, caption: note }),
    );
  });

  test("a build at the field's level clears the caption by writing it empty", async () => {
    const { t, owner } = await seed();

    await send(owner, captionsBuild, "new", [
      patch("clear", "jett", 1, agentData("jett", { caption: "" }), {
        fields: ["caption"],
      }),
    ]);

    expect((await row(t, "jett"))!.payload.data.caption).toBe("");
  });

  test("a write that keeping the caption makes too large fails as an oversized op", async () => {
    const { t, owner } = await seed();
    const nearLimit = "x".repeat(MAX_CLOUD_OPERATION_BYTES - 1024);
    await send(owner, captionsBuild, "new", [
      patch("long", "jett", 1, agentData("jett", { caption: "y".repeat(4096) }), {
        fields: ["caption"],
      }),
    ]);

    const results = await send(owner, oldBuild, "old", [
      patch("big", "jett", 2, agentData("jett", { note: nearLimit })),
    ]);

    expect(results[0]).toMatchObject({ status: "failed", code: "INVALID_PAYLOAD" });
    expect((await row(t, "jett"))!.payload.data.note).toBeUndefined();
  });

  test("the server's own copies keep the caption", async () => {
    const { owner } = await seed();

    await owner.mutation(duplicateStrategy, {
      ...protocol,
      sourceStrategyPublicId: strategy,
      publicId: "caption-copy",
      name: "Captions (Copy)",
    });

    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      ...captionsBuild,
      strategyPublicId: "caption-copy",
    })) as { elements: Row[] };
    const captions = copy.elements
      .map((element) => element.payload.data.caption)
      .filter((caption) => caption !== undefined);
    expect(captions).toEqual([note]);
  });
});

describe("a wall and the builds that don't know it", () => {
  const wallBuild = { acceptsPictureIds: true, elementFieldLevel: 2 };
  const wall = [
    { dx: 40, dy: -30 },
    { dx: 90, dy: -35 },
  ];

  function abilityData(id: string, fields: Record<string, unknown> = {}) {
    return { id, position: { dx: 10, dy: 20 }, length: 0, ...fields };
  }

  function abilityPayload(data: Record<string, unknown>) {
    return { kind: "ability", payloadVersion: 1, data };
  }

  /// [seed]'s strategy, plus "tide", an ability with a caption and a wall.
  async function seedWall() {
    const seeded = await seed();
    await send(seeded.owner, wallBuild, "seed-wall", [
      {
        ...add("add-tide", abilityData("tide")),
        payload: abilityPayload(
          abilityData("tide", { caption: note, wallPath: wall }),
        ),
      },
    ]);
    return seeded;
  }

  function patchAbility(
    opId: string,
    data: Record<string, unknown>,
    merge?: { fields: string[] },
  ) {
    return {
      ...patch(opId, "tide", 1, data, merge),
      payload: abilityPayload(data),
    };
  }

  test("a build at each level reads the fields of its level and no later", async () => {
    const { owner } = await seedWall();
    const expected: [Record<string, unknown>, Record<string, unknown>][] = [
      [oldBuild, abilityData("tide")],
      [captionsBuild, abilityData("tide", { caption: note })],
      [wallBuild, abilityData("tide", { caption: note, wallPath: wall })],
    ];

    for (const [client, data] of expected) {
      for (const [name, elements] of await reads(owner, client)) {
        expect(find(elements, "tide").payload.data, name).toEqual(data);
      }
    }
  });

  test("a move by a build below the field's level leaves the wall", async () => {
    const { t, owner } = await seedWall();
    const moved = { position: { dx: 50, dy: 60 } };

    await send(owner, captionsBuild, "old", [
      patchAbility("move", abilityData("tide", moved), {
        fields: ["position"],
      }),
    ]);

    expect((await row(t, "tide"))!.payload.data).toEqual(
      abilityData("tide", { ...moved, caption: note, wallPath: wall }),
    );
  });

  test("a whole write by a build below the field's level leaves the wall", async () => {
    const { t, owner } = await seedWall();

    await send(owner, captionsBuild, "old", [
      patchAbility("whole", abilityData("tide", { length: 4 })),
    ]);

    expect((await row(t, "tide"))!.payload.data.wallPath).toEqual(wall);
  });

  test("an old build's undo of a delete brings the wall back", async () => {
    const { t, owner } = await seedWall();

    await send(owner, oldBuild, "old", [
      {
        opId: "delete",
        type: "element.delete",
        elementPublicId: "tide",
        pagePublicId: page,
        expectedElementRevision: 1,
      },
    ]);
    const undo = await send(owner, oldBuild, "old", [
      {
        ...add("restore", abilityData("tide")),
        payload: abilityPayload(abilityData("tide")),
        expectedElementRevision: 2,
      },
    ]);

    expect(undo[0]!.status).toBe("applied");
    expect((await row(t, "tide"))!.payload.data.wallPath).toEqual(wall);
  });

  test("a build at the field's level removes the wall by writing it empty", async () => {
    const { t, owner } = await seedWall();

    await send(owner, wallBuild, "new", [
      patchAbility("clear", abilityData("tide", { wallPath: [] }), {
        fields: ["wallPath"],
      }),
    ]);

    expect((await row(t, "tide"))!.payload.data.wallPath).toEqual([]);
  });

  test("a copy of the strategy keeps the wall", async () => {
    const { owner } = await seedWall();

    await owner.mutation(duplicateStrategy, {
      ...protocol,
      sourceStrategyPublicId: strategy,
      publicId: "wall-copy",
      name: "Walls (Copy)",
    });

    const copy = (await owner.query(getFullSnapshot, {
      ...protocol,
      ...wallBuild,
      strategyPublicId: "wall-copy",
    })) as { elements: Row[] };
    const walls = copy.elements
      .map((element) => element.payload.data.wallPath)
      .filter((path) => path !== undefined);
    expect(walls).toEqual([wall]);
  });

  test("only an ability's key of that name is the wall", () => {
    const stray = { id: "jett", wallPath: wall };
    const agent = { kind: "agent" as const, payloadVersion: 1 };

    expect(
      keepLaterFields(
        { ...agent, data: stray },
        { ...agent, data: { id: "jett" } },
      ).data,
    ).toEqual({ id: "jett" });
    expect(withoutLaterFields({ ...agent, data: stray }, 0).data).toEqual(stray);
  });
});

describe("before any caption exists", () => {
  test("a row without the field reads the same at every level", async () => {
    const { t, owner } = await seed();
    const stored = (await row(t, "plain"))!.payload;

    for (const client of [oldBuild, captionsBuild]) {
      for (const [name, elements] of await reads(owner, client)) {
        expect(find(elements, "plain").payload, name).toEqual(stored);
      }
    }
  });

  test("a write without the field stores just what it sent", async () => {
    const { t, owner } = await seed();
    const data = agentData("plain", { state: "viewCone" });

    await send(owner, oldBuild, "old", [patch("whole", "plain", 1, data)]);

    expect((await row(t, "plain"))!.payload.data).toEqual(data);
  });

  test("a drawing's own key of that name is left alone", () => {
    const drawing = (data: Record<string, unknown>) => ({
      kind: "drawing" as const,
      payloadVersion: 1,
      data,
    });

    const kept = keepLaterFields(
      drawing({ id: "line", caption: "not a caption" }),
      drawing({ id: "line" }),
    );

    expect(kept.data).toEqual({ id: "line" });
  });
});
