// The flows the budgets guard, each run the way the app runs it: the same
// calls in the same order, with the same live queries subscribed.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ConvexClient, ConvexHttpClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";
import { measure, summarize } from "./logs.mjs";
import { batches, elementAdds, pageSliceStarts, seeded } from "./content.mjs";

const ELEMENT_FIELD_LEVEL = 3;

/// The deployed checkout's function arguments (convex/function_spec.json),
/// so a call leaves out arguments an older server doesn't take: the same
/// scenario then runs against a checkout from before a fix.
function loadSpec(projectDir) {
  const spec = JSON.parse(readFileSync(join(projectDir, "convex", "function_spec.json"), "utf8"));
  const args = new Map();
  for (const fn of spec.functions) {
    const name = fn.identifier.replace(/\.js:/, ":");
    args.set(name, new Set(Object.keys(fn.args?.value ?? {})));
  }
  return args;
}

function protocolVersion(projectDir) {
  const source = readFileSync(join(projectDir, "convex", "lib", "cloudProtocol.ts"), "utf8");
  const match = source.match(/CURRENT_CLOUD_PROTOCOL_VERSION\s*=\s*(\d+)/);
  if (!match) throw new Error("No CURRENT_CLOUD_PROTOCOL_VERSION in convex/lib/cloudProtocol.ts");
  return Number(match[1]);
}

/// One signed-in device: a websocket client, as the app holds one.
class Device {
  constructor(env, user) {
    this.env = env;
    this.user = user;
    // Live queries that failed after answering once: the flow then broke
    // the page or list a user watches, whatever it cost.
    this.errors = [];
    this.client = new ConvexClient(env.url, { skipConvexDeploymentUrlCheck: true, unsavedChangesWarning: false });
    // The admin key acting as [user]: the backend treats the calls as that
    // user's, as it does a signed-in app's.
    this.client.setAdminAuth(env.adminKey, {
      subject: user.subject,
      issuer: user.issuer,
      name: user.name,
    });
  }

  args(name, args) {
    const accepted = this.env.spec.get(name);
    if (!accepted) throw new Error(`The deployed checkout has no ${name}`);
    const out = { ...args };
    if (accepted.has("clientProtocolVersion")) out.clientProtocolVersion = this.env.protocol;
    for (const key of Object.keys(out)) {
      if (!accepted.has(key) || out[key] === undefined) delete out[key];
    }
    return out;
  }

  mutation(name, args) {
    return this.client.mutation(makeFunctionReference(name), this.args(name, args));
  }

  query(name, args) {
    return this.client.query(makeFunctionReference(name), this.args(name, args));
  }

  /// A live query; resolves once it has answered.
  async watch(name, args) {
    let settle;
    let answered = false;
    const first = new Promise((resolve, reject) => (settle = { resolve, reject }));
    const unsubscribe = this.client.onUpdate(
      makeFunctionReference(name),
      this.args(name, args),
      (value) => {
        answered = true;
        settle.resolve(value);
      },
      (error) => {
        if (answered) this.errors.push(`${name}: ${error.message}`);
        else settle.reject(error);
      },
    );
    await first;
    return unsubscribe;
  }

  async applyBatch(strategyPublicId, clientId, ops) {
    const { results } = await this.mutation("ops:applyBatch", {
      strategyPublicId,
      clientId,
      ops,
      accountSubject: this.user.subject,
      checkTrashedPageDeletes: true,
      acceptsPictureIds: true,
      elementFieldLevel: ELEMENT_FIELD_LEVEL,
    });
    const refused = results.filter((result) => result.status !== "applied");
    if (refused.length > 0) throw new Error(`applyBatch refused ops: ${JSON.stringify(refused[0])}`);
    return results;
  }

  close() {
    return this.client.close();
  }
}

const OWNER = { subject: "cost-owner", issuer: "https://cost.icarus.test", name: "Cost Owner" };

/// The library the scenarios run in: 150 strategies, 50 at the top level
/// and 25 in each of four folders, each with a page of eight items; and the
/// strategy the editor scenarios open, with a page of 60 items (watched in
/// four slices) and one of 20.
async function seedLibrary(device, rng) {
  await device.mutation("users:ensureCurrentUser", {});
  const folders = [];
  for (let i = 0; i < 4; i++) {
    const publicId = rng.uuid();
    await device.mutation("folders:create", { publicId, name: `Folder ${i + 1}` });
    folders.push(publicId);
  }
  for (let i = 0; i < 150; i++) {
    const folderPublicId = i < 50 ? undefined : folders[Math.floor((i - 50) / 25)];
    const strategy = await createStrategy(device, rng, { name: `Strategy ${i + 1}`, folderPublicId });
    await device.applyBatch(strategy.publicId, rng.uuid(), elementAdds(strategy.pages[0], 8, rng));
  }
  const editor = await createStrategy(device, rng, { name: "Editor", pageCount: 2 });
  const pageA = elementAdds(editor.pages[0], 60, rng);
  const pageB = elementAdds(editor.pages[1], 20, rng);
  const clientId = rng.uuid();
  for (const batch of batches([...pageA, ...pageB])) await device.applyBatch(editor.publicId, clientId, batch);
  return { folders, editor: { ...editor, elements: { [editor.pages[0]]: pageA, [editor.pages[1]]: pageB } } };
}

/// Creates a strategy the way a move does (createWithInitialPage, then
/// pages:add for each further page) and returns its ids.
async function createStrategy(device, rng, { name, folderPublicId, pageCount = 1, unfinishedMove }) {
  const publicId = rng.uuid();
  const pages = Array.from({ length: pageCount }, () => rng.uuid());
  await device.mutation("strategies:createWithInitialPage", {
    publicId,
    name,
    mapData: "ascent",
    initialPagePublicId: pages[0],
    initialPageName: "Page 1",
    initialPageIsAutoNamed: true,
    initialPageIsAttack: true,
    folderPublicId,
    unfinishedMove,
  });
  let revision = (await device.query("strategy:getShell", { strategyPublicId: publicId })).header.revision;
  for (let i = 1; i < pageCount; i++) {
    await device.mutation("pages:add", {
      strategyPublicId: publicId,
      expectedRevision: revision,
      pagePublicId: pages[i],
      name: `Page ${i + 1}`,
      isAutoNamed: true,
      sortIndex: i,
      isAttack: i % 2 === 0,
    });
    revision++;
  }
  return { publicId, pages };
}

/// What the library screen keeps live: the folder tree and the top-level
/// strategies (lib/collab/convex_strategy_repository.dart watchAllFolders,
/// watchStrategiesForFolder).
async function watchLibrary(device) {
  return [
    await device.watch("folders:listTree", { scope: "all" }),
    await device.watch("strategies:listForFolder", { scope: "owned", includeAgentTypes: true }),
  ];
}

/// What the editor keeps live on a page being edited: the strategy shell,
/// and the page as its frame plus id-range slices (watchPageSnapshot after
/// the first change).
async function watchEditor(device, editor, pagePublicId) {
  const page = { strategyPublicId: editor.publicId, pagePublicId };
  const starts = pageSliceStarts(editor.elements[pagePublicId].length);
  const unsubscribes = [
    await device.watch("strategy:getShell", { strategyPublicId: editor.publicId }),
    await device.watch("page:getFrame", page),
  ];
  for (const [index, start] of starts.entries()) {
    unsubscribes.push(
      await device.watch("page:getElementSlice", {
        ...page,
        fromPublicId: start,
        toPublicId: starts[index + 1],
        elementFieldLevel: ELEMENT_FIELD_LEVEL,
      }),
    );
  }
  return unsubscribes;
}

/// A drag of [add]'s element to a new spot: an element.patch of its
/// position, merged by field, as the canvas sends a drop.
function dragOp(add, revision, rng) {
  const from = add.payload.data.position;
  const to = rng.position();
  const payload = { ...add.payload, data: { ...add.payload.data, position: to } };
  add.payload = payload;
  return {
    opId: rng.uuid(),
    type: "element.patch",
    elementPublicId: add.elementPublicId,
    pagePublicId: add.pagePublicId,
    payload,
    expectedElementRevision: revision,
    merge: { fields: ["position"], base: [{ field: "position", value: from }] },
  };
}

const sumRuns = (summary, names) => names.reduce((sum, name) => sum + (summary.byFunction.get(name)?.runs ?? 0), 0);
const sumBytes = (summary, names) => names.reduce((sum, name) => sum + (summary.byFunction.get(name)?.readBytes ?? 0), 0);

const LIBRARY_LISTS = ["folders:listTree", "strategies:listForFolder"];
const PAGE_PARTS = ["page:getFrame", "page:getElementSlice"];

export const SCENARIOS = {
  move: {
    title: "Move 20 strategies into a 150-strategy library",
    about:
      "Moving local work to the cloud while the library is open at the top level, half the strategies into a folder. " +
      "Each move is createWithInitialPage, getShell, " +
      "two pages:add, two applyBatch (75 items), getFullSnapshot and finishMove, with the folder tree and the " +
      "top-level list live. Oct 22: every move write re-ran both lists, each re-run reading the whole library (#388).",
    async run({ owner, rng, library }) {
      const unsubscribes = await watchLibrary(owner);
      const measured = await measure(owner.env.logs, owner.env.http, async () => {
        for (let i = 0; i < 20; i++) {
          // Half to the top level, half into a folder: each finished move
          // shows in one of the two lists.
          const folderPublicId = i % 2 === 0 ? undefined : library.folders[0];
          const { publicId, pages } = await createStrategy(owner, rng, {
            name: `Moved ${i + 1}`,
            folderPublicId,
            pageCount: 3,
            unfinishedMove: true,
          });
          const ops = pages.flatMap((page) => elementAdds(page, 25, rng));
          const clientId = rng.uuid();
          for (const batch of batches(ops)) await owner.applyBatch(publicId, clientId, batch);
          await owner.query("strategy:getFullSnapshot", {
            strategyPublicId: publicId,
            acceptsTrashedPagesLeftOut: true,
            acceptsPictureIds: true,
            elementFieldLevel: ELEMENT_FIELD_LEVEL,
            includeContentVersion: true,
          });
          await owner.mutation("strategies:finishMove", { strategyPublicId: publicId, folderPublicId });
        }
      });
      unsubscribes.forEach((unsubscribe) => unsubscribe());
      const summary = summarize(measured.entries);
      return {
        summary,
        metrics: {
          listReruns: sumRuns(summary, LIBRARY_LISTS),
          listReadBytes: sumBytes(summary, LIBRARY_LISTS),
          readBytes: summary.total.readBytes,
        },
      };
    },
  },

  agentDrag: {
    title: "Drag an agent",
    about:
      "One element.patch of an agent's position through ops:applyBatch, on a page of 60 items watched in slices, " +
      "with the library lists live behind the editor. Oct 19: the drag re-read every agent of the strategy " +
      "to rebuild its agent summary (75 KB, #348).",
    async run({ owner, rng, library }) {
      const { editor } = library;
      const page = editor.pages[0];
      const unsubscribes = [...(await watchLibrary(owner)), ...(await watchEditor(owner, editor, page))];
      const agent = editor.elements[page].find((add) => add.payload.kind === "agent");
      const revision = await elementRevision(owner, editor, page, agent.elementPublicId);
      const measured = await measure(owner.env.logs, owner.env.http, () =>
        owner.applyBatch(editor.publicId, rng.uuid(), [dragOp(agent, revision, rng)]),
      );
      unsubscribes.forEach((unsubscribe) => unsubscribe());
      const summary = summarize(measured.entries);
      const batch = summary.byFunction.get("ops:applyBatch");
      return {
        summary,
        metrics: {
          applyBatchReadBytes: batch?.readBytes ?? 0,
          applyBatchWriteBytes: batch?.writeBytes ?? 0,
          liveQueryReruns: summary.total.runs - (batch?.runs ?? 0),
          readBytes: summary.total.readBytes,
        },
      };
    },
  },

  sliceEdit: {
    title: "Edit a page watched in slices",
    about:
      "One item moved on a page of 60 items that the editor watches as page:getFrame plus four " +
      "page:getElementSlice ranges (#350). The edit should re-run the one slice holding the item: " +
      "17.4 KB per save in slices against 56.5 KB for the whole page when slices shipped.",
    async run({ owner, rng, library }) {
      const { editor } = library;
      const page = editor.pages[0];
      const unsubscribes = await watchEditor(owner, editor, page);
      const item = editor.elements[page].find((add) => add.payload.kind === "ability");
      const revision = await elementRevision(owner, editor, page, item.elementPublicId);
      const measured = await measure(owner.env.logs, owner.env.http, () =>
        owner.applyBatch(editor.publicId, rng.uuid(), [dragOp(item, revision, rng)]),
      );
      unsubscribes.forEach((unsubscribe) => unsubscribe());
      const summary = summarize(measured.entries);
      return {
        summary,
        metrics: {
          pageReruns: sumRuns(summary, PAGE_PARTS),
          pageReadBytes: sumBytes(summary, PAGE_PARTS),
          otherReruns: summary.total.runs - sumRuns(summary, [...PAGE_PARTS, "ops:applyBatch"]),
        },
      };
    },
  },

  concurrentEdits: {
    title: "Two devices edit one strategy at once",
    about:
      "Two signed-in devices each send 10 single-drag applyBatch calls to the same strategy at the same " +
      "time, on different items of one page. Oct 22: a per-strategy counter row made concurrent " +
      "batches lose write conflicts and retry (#391's design).",
    async run({ owner, rng, library, env }) {
      const { editor } = library;
      const page = editor.pages[1];
      const second = new Device(env, OWNER);
      // Connected and signed in before the measured sends, so both devices
      // send from the first call.
      await second.query("strategy:getShell", { strategyPublicId: editor.publicId });
      const items = editor.elements[page];
      const revisions = await Promise.all(items.slice(0, 20).map((add) => elementRevision(owner, editor, page, add.elementPublicId)));
      const measured = await measure(owner.env.logs, owner.env.http, () => {
        const send = (device, offset) => {
          const clientId = rng.uuid();
          const calls = [];
          for (let i = 0; i < 10; i++) {
            const index = offset + i;
            calls.push(device.applyBatch(editor.publicId, clientId, [dragOp(items[index], revisions[index], rng)]));
          }
          return Promise.all(calls);
        };
        return Promise.all([send(owner, 0), send(second, 10)]);
      });
      await second.close();
      const summary = summarize(measured.entries);
      // Zero retries proves nothing unless batches ran at the same time.
      const runs = measured.entries
        .filter((entry) => entry.identifier === "ops:applyBatch")
        .map((entry) => [entry.executionTimestamp, entry.timestamp]);
      let overlapping = 0;
      for (let i = 0; i < runs.length; i++) {
        for (let j = i + 1; j < runs.length; j++) {
          if (runs[i][0] < runs[j][1] && runs[j][0] < runs[i][1]) overlapping++;
        }
      }
      return {
        summary,
        problems: [
          ...second.errors,
          ...(overlapping === 0 ? ["No two applyBatch runs overlapped, so the flow tested no contention"] : []),
        ],
        metrics: {
          conflictRetries: summary.total.conflictRetries,
        },
      };
    },
  },
};

async function elementRevision(device, editor, page, elementPublicId) {
  const slice = await device.query("page:getElementSlice", {
    strategyPublicId: editor.publicId,
    pagePublicId: page,
    fromPublicId: elementPublicId,
    toPublicId: `${elementPublicId}\u0000`,
    elementFieldLevel: ELEMENT_FIELD_LEVEL,
  });
  const element = slice.elements.find((row) => row.publicId === elementPublicId);
  if (!element) throw new Error(`No element ${elementPublicId}`);
  return element.revision;
}

/// Seeds the library and runs [names], each on the same library, in order.
export async function runScenarios({ url, adminKey, projectDir, logs, names }) {
  const http = new ConvexHttpClient(url, { skipConvexDeploymentUrlCheck: true });
  const env = { url, adminKey, logs, http, spec: loadSpec(projectDir), protocol: protocolVersion(projectDir) };
  const owner = new Device(env, OWNER);
  const rng = seeded(0x1ca75);
  const started = Date.now();
  const library = await seedLibrary(owner, rng);
  console.log(`Seeded the library in ${((Date.now() - started) / 1000).toFixed(1)} s`);
  const results = {};
  for (const name of names) {
    const scenario = SCENARIOS[name];
    const at = Date.now();
    // Each scenario draws from its own generator, so leaving one out
    // doesn't change what another writes.
    owner.errors = [];
    const result = await scenario.run({ owner, rng: seeded(hash(name)), library, env });
    result.seconds = (Date.now() - at) / 1000;
    // A cheap flow that failed is not a pass.
    result.problems = [
      ...(result.problems ?? []),
      ...owner.errors,
      ...[...result.summary.byFunction]
        .filter(([, row]) => row.failures > 0)
        .map(([fn, row]) => `${fn} failed ${row.failures} time(s)`),
    ];
    results[name] = result;
  }
  await owner.close();
  return results;
}

function hash(text) {
  let h = 2166136261;
  for (const char of text) h = Math.imul(h ^ char.charCodeAt(0), 16777619);
  return h >>> 0;
}
