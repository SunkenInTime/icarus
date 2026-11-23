import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ConvexHttpClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";
import { measure, summarize } from "./logs.mjs";
import { batches, elementAdds, freehandPayload, pageSliceStarts, seeded } from "./content.mjs";
import { createStrategy, deadline, Device, ELEMENT_FIELD_LEVEL, hash } from "./scenarios.mjs";

const ISSUER = "https://cost.icarus.test";
const COACH = { subject: "cost-coach", issuer: ISSUER, name: "Coach" };
const TEAMMATE = { subject: "cost-teammate", issuer: ISSUER, name: "Teammate" };

const CONTENT_VERSIONS_BATCH = 100;
const SESSION_EDITS = 50;
const PEER_EDITS = 20;
const ROOM_PASS_RENEWALS_PER_HOUR = 60;
const DRAWING_POINTS = 2000;
const LARGE_DRAWING_POINTS = 250;
const ANSWER_DEADLINE_MS = 60_000;

const fullSnapshotArgs = (strategyPublicId) => ({
  strategyPublicId,
  acceptsTrashedPagesLeftOut: true,
  acceptsPictureIds: true,
  elementFieldLevel: ELEMENT_FIELD_LEVEL,
  includeContentVersion: true,
});

const wholePageArgs = (strategyPublicId, pagePublicId) => ({
  strategyPublicId,
  pagePublicId,
  acceptsPictureIds: true,
  elementFieldLevel: ELEMENT_FIELD_LEVEL,
});

function pageVersion(page) {
  return [
    page.page.revision,
    page.content.revision,
    ...page.elements.map((row) => `${row.publicId}:${row.revision}:${row.deleted}`),
    ...page.lineups.map((row) => `${row.publicId}:${row.revision}:${row.deleted}`),
  ].join("|");
}

class PageWatch {
  constructor(device, strategyPublicId, pagePublicId) {
    this.device = device;
    this.strategyPublicId = strategyPublicId;
    this.pagePublicId = pagePublicId;
    this.waiters = [];
    this.switching = Promise.resolve();
    this.slicing = false;
    this.stopParts = [];
  }

  static async start(device, strategyPublicId, pagePublicId) {
    const watch = new PageWatch(device, strategyPublicId, pagePublicId);
    const first = new Promise((resolve) => {
      watch.stopWhole = device.watchEach(
        "page:getSnapshot",
        wholePageArgs(strategyPublicId, pagePublicId),
        (page) => {
          watch.onWhole(page);
          resolve();
        },
      );
    });
    await deadline(first, ANSWER_DEADLINE_MS, `page:getSnapshot of ${pagePublicId}`);
    return watch;
  }

  onWhole(page) {
    if (this.slicing) return;
    this.elements = page.elements;
    const version = pageVersion(page);
    this.firstVersion ??= version;
    if (version !== this.firstVersion) {
      this.switching = this.watchSlices(page.elements.length);
      this.switching.catch(() => {});
    }
    this.notify();
  }

  async watchSlices(elementCount) {
    const starts = pageSliceStarts(elementCount);
    if (starts.length === 1) return;
    this.slicing = true;
    const parts = new Array(starts.length + 1);
    let answered = 0;
    let allAnswered;
    const ready = new Promise((resolve) => (allAnswered = resolve));
    const take = (index) => (value) => {
      if (parts[index] === undefined) answered++;
      parts[index] = value;
      if (answered < parts.length) return;
      this.elements = parts.slice(1).flatMap((slice) => slice.elements);
      this.notify();
      allAnswered();
    };
    const page = { strategyPublicId: this.strategyPublicId, pagePublicId: this.pagePublicId };
    this.stopParts = [
      this.device.watchEach("page:getFrame", page, take(0)),
      ...starts.map((start, index) =>
        this.device.watchEach(
          "page:getElementSlice",
          { ...page, fromPublicId: start, toPublicId: starts[index + 1], elementFieldLevel: ELEMENT_FIELD_LEVEL },
          take(index + 1),
        ),
      ),
    ];
    await deadline(ready, ANSWER_DEADLINE_MS, `the slices of ${this.pagePublicId}`);
    this.stopWhole();
    this.stopWhole = null;
  }

  notify() {
    this.waiters = this.waiters.filter(({ test, resolve }) => {
      if (!test(this.elements)) return true;
      resolve();
      return false;
    });
  }

  waitFor(test) {
    if (test(this.elements)) return Promise.resolve();
    const seen = new Promise((resolve) => this.waiters.push({ test, resolve }));
    return deadline(seen, ANSWER_DEADLINE_MS, `the edit reaching ${this.pagePublicId}`);
  }

  settle() {
    return this.switching;
  }

  row(elementPublicId) {
    return this.elements.find((row) => row.publicId === elementPublicId);
  }

  stop() {
    this.stopWhole?.();
    this.stopParts.forEach((stop) => stop());
  }
}

class Editor {
  constructor(device, strategy, { desktop }) {
    this.device = device;
    this.strategy = strategy;
    this.desktop = desktop;
    this.unsubscribes = [];
  }

  async open(pagePublicId) {
    const strategyPublicId = this.strategy.publicId;
    const shell = await this.device.query("strategy:getShell", { strategyPublicId });
    const pageId = pagePublicId ?? [...shell.pages].sort((a, b) => a.sortIndex - b.sortIndex)[0].publicId;
    await this.device.query("page:getSnapshot", wholePageArgs(strategyPublicId, pageId));
    this.unsubscribes.push(await this.device.watch("strategy:getShell", { strategyPublicId }));
    this.page = await PageWatch.start(this.device, strategyPublicId, pageId);
    await this.device.mutation("presence:issueRoomPass", { strategyPublicId });
    await this.device.query("pages:listTrashed", { strategyPublicId });
    if (this.desktop) await this.device.query("strategy:getFullSnapshot", fullSnapshotArgs(strategyPublicId));
    return this;
  }

  async switchPage(pagePublicId) {
    this.page.stop();
    await this.device.query("page:getSnapshot", wholePageArgs(this.strategy.publicId, pagePublicId));
    this.page = await PageWatch.start(this.device, this.strategy.publicId, pagePublicId);
  }

  close() {
    this.page?.stop();
    this.unsubscribes.forEach((unsubscribe) => unsubscribe());
  }
}

async function watchMyLibrary(device) {
  return [
    await device.watch("folders:listTree", { scope: "all" }),
    await device.watch("strategies:listForFolder", { scope: "owned", includeAgentTypes: true }),
    await device.watch("community:listMine", {}),
  ];
}

async function watchSharedLibrary(device) {
  return [
    await device.watch("folders:listTree", { scope: "all" }),
    await device.watch("strategies:listSharedWithMe", { includeAgentTypes: true }),
  ];
}

const MOVED_TOGETHER = {
  drawing: ["listOfPoints", "lineStart", "lineEnd", "start", "end", "boundingBox"],
  text: ["position", "size", "fontSize", "sizeVersion"],
  image: ["position", "scale", "sizeVersion"],
};

const shifted = (point, delta) => ({ dx: point.dx + delta.dx, dy: point.dy + delta.dy });

function movedData(kind, data, delta) {
  const moved = { ...data };
  if (kind === "drawing") {
    for (const key of ["lineStart", "lineEnd", "start", "end"]) {
      if (moved[key]) moved[key] = shifted(moved[key], delta);
    }
    if (moved.listOfPoints) moved.listOfPoints = moved.listOfPoints.map((point) => shifted(point, delta));
    if (moved.boundingBox) {
      moved.boundingBox = { min: shifted(moved.boundingBox.min, delta), max: shifted(moved.boundingBox.max, delta) };
    }
    return { moved, fields: MOVED_TOGETHER.drawing.filter((key) => key in data) };
  }
  moved.position = shifted(moved.position, delta);
  const group =
    kind === "utility" && data.type === "customRectangle"
      ? ["position", "rotation", "customWidth", "customLength"]
      : (MOVED_TOGETHER[kind] ?? ["position"]);
  return { moved, fields: group.filter((key) => key in data) };
}

function liveMove(row, rng) {
  const delta = { dx: (rng.next() - 0.5) * 80, dy: (rng.next() - 0.5) * 80 };
  const { moved, fields } = movedData(row.payload.kind, row.payload.data, delta);
  return {
    opId: rng.uuid(),
    type: "element.patch",
    elementPublicId: row.publicId,
    pagePublicId: row.pagePublicId,
    payload: { ...row.payload, data: moved },
    sortIndex: row.sortIndex,
    expectedElementRevision: row.revision,
    merge: { fields: [...fields].sort() },
  };
}

async function sendLive(device, strategyPublicId, clientId, op) {
  const [result] = await device.applyBatch(strategyPublicId, clientId, [op], { includeWasApplied: true });
  return result.appliedRevision;
}

const STORE_SENDER_WAIT_MS = 180;

async function sendFromStore(device, strategyPublicId, clientId, op) {
  await new Promise((resolve) => setTimeout(resolve, STORE_SENDER_WAIT_MS));
  const [result] = await device.applyBatch(strategyPublicId, clientId, [op], {
    includeWasApplied: true,
    readsAccountMismatch: true,
  });
  return result.appliedRevision;
}

const namedPage = (device, strategyPublicId, pagePublicId) =>
  device.query("page:getSnapshot", { ...wholePageArgs(strategyPublicId, pagePublicId), accountSubject: COACH.subject });

const namedPageList = (device, strategyPublicId) =>
  device.query("strategy:getPageList", { strategyPublicId, accountSubject: COACH.subject });

const STORE_BURSTS = 5;

function withSenderCounts(result) {
  result.metrics.applyBatchCalls = result.summary.byFunction.get("ops:applyBatch")?.runs ?? 0;
  result.metrics.conflictRetries = result.summary.total.conflictRetries;
  return result;
}

async function makeStrategy(
  device,
  rng,
  { name, folderPublicId, pageCount, items, freehandPoints, itemsOnFirstPageOnly, seedBatch = 40 },
) {
  const strategy = await createStrategy(device, rng, { name, folderPublicId, pageCount });
  const clientId = rng.uuid();
  const pages = itemsOnFirstPageOnly ? strategy.pages.slice(0, 1) : strategy.pages;
  for (const page of pages) {
    for (const batch of batches(elementAdds(page, items, rng, { freehandPoints }), seedBatch)) {
      await device.applyBatch(strategy.publicId, clientId, batch);
    }
  }
  return { ...strategy, name, owner: device };
}

async function makeSketch(device, rng) {
  const strategy = await createStrategy(device, rng, { name: "Sketch", pageCount: 1 });
  const page = strategy.pages[0];
  const adds = elementAdds(page, 59, rng);
  const drawingId = rng.uuid();
  adds.push({
    opId: rng.uuid(),
    type: "element.add",
    elementPublicId: drawingId,
    pagePublicId: page,
    payload: freehandPayload(drawingId, DRAWING_POINTS, rng),
    sortIndex: 59,
  });
  const clientId = rng.uuid();
  for (const batch of batches(adds)) await device.applyBatch(strategy.publicId, clientId, batch);
  return { ...strategy, name: "Sketch", owner: device, drawingId };
}

async function share(owner, guest, rng, targetType, targetPublicId, role) {
  const token = `cost-${rng.uuid()}`;
  await owner.mutation("shares:create", { targetType, targetPublicId, token, role });
  await guest.mutation("shares:redeem", { token });
}

async function rename(strategy) {
  const device = strategy.owner;
  const { header } = await device.query("strategy:getShell", { strategyPublicId: strategy.publicId });
  strategy.flipped = !strategy.flipped;
  await device.mutation("strategies:update", {
    strategyPublicId: strategy.publicId,
    name: `${strategy.name} ${strategy.flipped ? "B" : "A"}`,
    expectedRevision: header.revision,
  });
}

async function freshenLists(world) {
  for (const strategy of world.listed) await rename(strategy);
}

async function inParallel(tasks, width) {
  const results = new Array(tasks.length);
  let next = 0;
  const lane = async () => {
    while (next < tasks.length) {
      const index = next++;
      results[index] = await tasks[index]();
    }
  };
  await Promise.all(Array.from({ length: width }, lane));
  return results;
}

const own = (name) => seeded(hash(name));

export async function seedTeam({ env, rng, projectDir }) {
  const coach = new Device(env, COACH);
  const teammate = new Device(env, TEAMMATE);
  await coach.mutation("users:ensureCurrentUser", {});
  await teammate.mutation("users:ensureCurrentUser", {});

  const folders = [];
  for (let i = 0; i < 5; i++) {
    const parent = rng.uuid();
    await coach.mutation("folders:create", { publicId: parent, name: `Map pool ${i + 1}` });
    folders.push(parent);
    for (let j = 0; j < 3; j++) {
      const child = rng.uuid();
      await coach.mutation("folders:create", { publicId: child, name: `Set ${i + 1}.${j + 1}`, parentFolderPublicId: parent });
      folders.push(child);
    }
  }
  const teamFolder = rng.uuid();
  await teammate.mutation("folders:create", { publicId: teamFolder, name: "Team" });
  const small = (device, name, folderPublicId, pageCount) => () =>
    makeStrategy(device, own(name), { name, folderPublicId, pageCount, items: 8, itemsOnFirstPageOnly: true });
  const [large, typical, session, sketch, ...rest] = await inParallel(
    [
      () =>
        makeStrategy(coach, own("Large"), {
          name: "Large",
          pageCount: 20,
          items: 300,
          freehandPoints: LARGE_DRAWING_POINTS,
        }),
      () => makeStrategy(coach, own("Typical"), { name: "Typical", pageCount: 4, items: 60 }),
      () => makeStrategy(coach, own("Session"), { name: "Session", pageCount: 4, items: 60 }),
      () => makeSketch(coach, own("Sketch")),
      ...Array.from({ length: 150 }, (_, i) =>
        small(coach, `Play ${i + 1}`, i < 30 ? undefined : folders[(i - 30) % folders.length], 1 + (i % 4)),
      ),
      ...Array.from({ length: 10 }, (_, i) => small(teammate, `Mine ${i + 1}`, undefined, 2)),
      ...Array.from({ length: 5 }, (_, i) => small(teammate, `Team ${i + 1}`, teamFolder, 2)),
    ],
    8,
  );
  const library = rest.slice(0, 150);
  const teammateOwn = rest.slice(150, 160);
  const inTeamFolder = rest.slice(160);
  await share(teammate, coach, rng, "folder", teamFolder, "viewer");
  for (const strategy of teammateOwn.slice(0, 3)) await share(teammate, coach, rng, "strategy", strategy.publicId, "editor");
  await share(coach, teammate, rng, "strategy", session.publicId, "editor");

  const seededAt = Date.now();
  return {
    settle: () => foldSeedChanges(env, projectDir, seededAt),
    coach,
    teammate,
    typical,
    session,
    large,
    sketch,
    listed: [library[0], library[40], teammateOwn[0], inTeamFolder[0]],
    openable: [...library, large, typical, session, sketch, ...teammateOwn.slice(0, 3), ...inTeamFolder].map(
      (strategy) => strategy.publicId,
    ),
    opened: [typical, session, large, sketch],
  };
}

async function metered(devices, env, work) {
  const asked = devices.reduce((sum, device) => sum + device.asked, 0);
  const sent = devices.reduce((sum, device) => sum + device.sentBytes, 0);
  const measured = await measure(env.logs, env.http, work);
  const summary = summarize(measured.entries);
  return {
    summary,
    value: measured.value,
    metrics: {
      functionCalls: summary.total.runs + summary.total.cachedRuns,
      readBytes: summary.total.readBytes,
      writeBytes: summary.total.writeBytes,
      sentBytes: devices.reduce((sum, device) => sum + device.sentBytes, 0) - sent,
      returnBytes: summary.total.returnBytes,
      queryReruns: summary.total.queryRuns - (devices.reduce((sum, device) => sum + device.asked, 0) - asked),
    },
  };
}

async function walkLibrary(device) {
  const inventory = await device.query("strategies:listInventory", {});
  const shared = await device.query("strategies:listSharedWithMe", { includeAgentTypes: true });
  const sharedFolders = await device.query("folders:listTree", { scope: "shared" });
  const ids = new Set([...inventory.strategies.map((row) => row.publicId), ...shared.map((row) => row.publicId)]);
  for (const folder of sharedFolders) {
    const inFolder = await device.query("strategies:listForFolder", {
      folderPublicId: folder.publicId,
      scope: "shared",
      includeAgentTypes: true,
    });
    for (const row of inFolder) ids.add(row.publicId);
  }
  return [...ids].sort();
}

const versionKey = (answer) =>
  answer.status === "found" ? JSON.stringify([canonical(answer.header), answer.contentVersion]) : null;

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
}

async function copiedVersions(device, ids) {
  const copied = new Map();
  for (const id of ids) {
    const [answer] = await device.query("strategy:listContentVersions", { strategyPublicIds: [id] });
    copied.set(id, versionKey(answer));
  }
  return copied;
}

async function changedSinceCopied(device, ids, copied) {
  const changed = [];
  for (let start = 0; start < ids.length; start += CONTENT_VERSIONS_BATCH) {
    const answers = await device.query("strategy:listContentVersions", {
      strategyPublicIds: ids.slice(start, start + CONTENT_VERSIONS_BATCH),
    });
    for (const answer of answers) {
      if (versionKey(answer) !== copied.get(answer.strategyPublicId)) changed.push(answer.strategyPublicId);
    }
  }
  return changed;
}

function openScenario(key, title, about) {
  return {
    title,
    about,
    world: "team",
    async run({ env, world }) {
      const strategy = world[key];
      await rename(strategy);
      const editor = new Editor(world.coach, strategy, { desktop: true });
      const result = await metered([world.coach], env, () => editor.open());
      editor.close();
      const fullRead = result.summary.byFunction.get("strategy:getFullSnapshot");
      result.notes = [
        `strategy:getFullSnapshot took ${Math.round((fullRead?.slowestSeconds ?? 0) * 1000)} ms, ` +
          `${Math.round((fullRead?.slowestCodeSeconds ?? 0) * 1000)} ms of it in its own code, where Convex stops a query at 1 s ` +
          "(not budgeted: run time follows the machine)",
      ];
      return result;
    },
  };
}

function pageListScenario(key, title, about) {
  return {
    title,
    about,
    world: "team",
    async run({ env, world }) {
      const strategy = world[key];
      const args = { strategyPublicId: strategy.publicId };
      await rename(strategy);
      const shell = await metered([world.coach], env, () => world.coach.query("strategy:getShell", args));
      await rename(strategy);
      const result = await metered([world.coach], env, () => world.coach.query("strategy:getPageList", args));
      result.notes = [
        `strategy:getShell on the same strategy read ${shell.metrics.readBytes} B and returned ` +
          `${shell.metrics.returnBytes} B in ${shell.metrics.functionCalls} call (not budgeted here)`,
      ];
      return result;
    },
  };
}

function reopenScenario(desktop) {
  return {
    world: "team",
    async run({ env, world }) {
      await rename(world.typical);
      const first = await new Editor(world.coach, world.typical, { desktop }).open();
      first.close();
      const again = new Editor(world.coach, world.typical, { desktop });
      const result = await metered([world.coach], env, () => again.open());
      again.close();
      return result;
    },
  };
}

function launchScenario({ changed, rereadAll }) {
  return {
    world: "team",
    async run({ env, world, rng }) {
      await freshenLists(world);
      for (const strategy of world.opened) await rename(strategy);
      const copied = await copiedVersions(world.coach, world.openable);
      if (changed) {
        const editor = await new Editor(world.coach, world.typical, { desktop: false }).open();
        const row = editor.page.elements.find((element) => element.payload.kind === "agent");
        await sendLive(world.coach, world.typical.publicId, rng.uuid(), liveMove(row, rng));
        await editor.page.settle();
        editor.close();
      }
      const result = await metered([world.coach], env, async () => {
        const ids = await walkLibrary(world.coach);
        const reread = rereadAll ? ids : await changedSinceCopied(world.coach, ids, copied);
        for (const id of reread) await world.coach.query("strategy:getFullSnapshot", fullSnapshotArgs(id));
        return { walked: ids.length, reread: reread.length };
      });
      result.notes = [`${result.value.walked} strategies in the walk, ${result.value.reread} read whole`];
      return result;
    },
  };
}

function cronJobs(projectDir) {
  const convexDir = join(projectDir, "convex");
  const refs = new Map();
  for (const file of readdirSync(convexDir).filter((name) => name.endsWith(".ts"))) {
    const source = readFileSync(join(convexDir, file), "utf8");
    for (const match of source.matchAll(/export const (\w+) =\s*makeFunctionReference<"(\w+)">\(\s*"([^"]+)"/g)) {
      refs.set(match[1], { kind: match[2], name: match[3] });
    }
  }
  const crons = readFileSync(join(convexDir, "crons.ts"), "utf8");
  const jobs = [];
  for (const match of crons.matchAll(/crons\.interval\(\s*"([^"]+)",\s*\{\s*(minutes|hours):\s*(\d+)\s*\},\s*(\w+),/g)) {
    const ref = refs.get(match[4]);
    if (!ref) throw new Error(`No function reference ${match[4]} for cron ${match[1]}`);
    const minutes = Number(match[3]) * (match[2] === "hours" ? 60 : 1);
    jobs.push({ job: match[1], ...ref, perHour: 60 / minutes });
  }
  if (jobs.length === 0) throw new Error("No crons.interval jobs found in convex/crons.ts");
  return jobs;
}

async function runJob(admin, job) {
  const reference = makeFunctionReference(job.name);
  return job.kind === "action" ? admin.action(reference, {}) : admin.mutation(reference, {});
}

function foldAfterMs(projectDir) {
  const source = readFileSync(join(projectDir, "convex", "lib", "contentVersions.ts"), "utf8");
  const match = source.match(/FOLD_AFTER_MS\s*=\s*([0-9_*\s]+);/);
  if (!match) throw new Error("No FOLD_AFTER_MS in convex/lib/contentVersions.ts");
  return match[1].split("*").reduce((product, factor) => product * Number(factor.replaceAll("_", "").trim()), 1);
}

function requireOwnBackend(env, what) {
  if (!env.ownBackend) throw new Error(`${what} runs maintenance jobs, so it only runs on a backend this run started`);
}

async function foldSeedChanges(env, projectDir, seededAt) {
  requireOwnBackend(env, "Folding the seed's content changes");
  const wait = seededAt + foldAfterMs(projectDir) + 1000 - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  const admin = new ConvexHttpClient(env.url, { skipConvexDeploymentUrlCheck: true });
  admin.setAdminAuth(env.adminKey);
  await idleRun(env, admin, { job: "fold-content-changes", name: "maintenance:foldContentChanges", kind: "mutation" });
}

const IDLE_ATTEMPTS = 50;
const DRAIN_RUNS = 500;

async function idleRun(env, admin, job) {
  for (let attempt = 0; attempt < IDLE_ATTEMPTS; attempt++) {
    for (let run = 0; run < DRAIN_RUNS; run++) {
      const drained = summarize((await measure(env.logs, env.http, () => runJob(admin, job))).entries);
      if (drained.total.writeDocuments === 0) break;
    }
    const measured = summarize((await measure(env.logs, env.http, () => runJob(admin, job))).entries);
    if (measured.total.writeDocuments === 0) return measured;
  }
  throw new Error(`${job.job} still had work waiting after ${IDLE_ATTEMPTS} tries`);
}

async function soloSession({ env, world, rng }, send) {
  const coach = world.coach;
  const lists = await watchMyLibrary(coach);
  const editor = await new Editor(coach, world.session, { desktop: false }).open();
  const order = editor.page.elements.slice(0, SESSION_EDITS).map((row) => row.publicId);
  const clientId = rng.uuid();
  const result = await metered([coach], env, async () => {
    for (const id of order) {
      await send(coach, world.session.publicId, clientId, liveMove(editor.page.row(id), rng));
      await editor.page.settle();
    }
  });
  editor.close();
  lists.forEach((unsubscribe) => unsubscribe());
  result.metrics.listReruns = ["folders:listTree", "strategies:listForFolder"].reduce(
    (sum, name) => sum + (result.summary.byFunction.get(name)?.runs ?? 0) + (result.summary.byFunction.get(name)?.cachedRuns ?? 0),
    0,
  );
  return result;
}

async function twoPeople({ env, world, rng }, send) {
  const { coach, teammate, session } = world;
  const lists = await watchSharedLibrary(teammate);
  const peer = await new Editor(teammate, session, { desktop: false }).open();
  const rows = (await coach.query("page:getSnapshot", wholePageArgs(session.publicId, session.pages[0]))).elements;
  const clientId = rng.uuid();
  const result = await metered([coach, teammate], env, async () => {
    for (const row of rows.slice(0, PEER_EDITS)) {
      const revision = await send(coach, session.publicId, clientId, liveMove(row, rng));
      await peer.page.waitFor((elements) => elements.some((seen) => seen.publicId === row.publicId && seen.revision >= revision));
      await peer.page.settle();
    }
  });
  peer.close();
  lists.forEach((unsubscribe) => unsubscribe());
  return result;
}

export const SESSIONS = {
  libraryOpen: {
    title: "Open the library",
    about:
      "A signed-in user with 150 strategies in 20 folders (five with three subfolders each) opens the library: the folder " +
      "tree with its per-folder summaries (scope all) and My Library's top level, live; then Shared, which swaps the " +
      "strategy list for strategies:listSharedWithMe while the tree stays. The tiles also watch the user's Community " +
      "posts (community:listMine) and read once per sign-in which strategies are Community copies " +
      "(community:listMyCopies). This is all the web build reads; a desktop launch also walks the library " +
      "(launchUnchanged).",
    world: "team",
    async run({ env, world }) {
      await freshenLists(world);
      const coach = world.coach;
      const result = await metered([coach], env, async () => {
        const [tree, mine, posts] = await watchMyLibrary(coach);
        await coach.query("community:listMyCopies", {});
        mine();
        const shared = await coach.watch("strategies:listSharedWithMe", { includeAgentTypes: true });
        tree();
        posts();
        shared();
      });
      return result;
    },
  },

  launchUnchanged: {
    title: "Desktop launch, nothing changed",
    about:
      "The desktop app connects and refreshes the copy it keeps of every strategy it can open, each copy a day to a " +
      "week old and none changed: listInventory, listSharedWithMe, the shared folder tree and each shared folder's list " +
      "(strategy_copy_provider.dart _listStrategies), then strategy:listContentVersions in batches of 100. No strategy " +
      "is read again.",
    ...launchScenario({ changed: false }),
  },

  launchOneChanged: {
    title: "Desktop launch, one strategy changed",
    about:
      "The same launch after a teammate moved one agent in a 4-page, 240-item strategy: the walk and the version check, " +
      "then strategy:getFullSnapshot of the one that changed.",
    ...launchScenario({ changed: true }),
  },

  launchWeekly: {
    title: "Desktop launch, copies a week old",
    about:
      "The launch once every copy is older than a week (strategyCopyFullReadMaxAge), when the desktop app reads every " +
      "strategy whole again, changed or not: the walk, then strategy:getFullSnapshot for each. The library holds the " +
      "150 small strategies, the 4-page and 20-page strategies and the ones shared with the user.",
    ...launchScenario({ rereadAll: true }),
  },

  openTypical: openScenario(
    "typical",
    "Open a typical strategy cold",
    "Desktop opens a strategy of 4 pages and 60 items a page that nothing has read since it last changed: getShell and " +
      "page:getSnapshot of the first page read once, then both watched (the page whole until it changes), " +
      "presence:issueRoomPass, pages:listTrashed for the pages bar, and strategy:getFullSnapshot for the copy desktop " +
      "keeps (StrategyCopyRefresher.keepOpenedStrategy). The web build makes the same calls but the last.",
  ),

  openLarge: openScenario(
    "large",
    "Open a large strategy cold",
    "The same open on a strategy of 20 pages and 300 items a page, one item in ten a freehand drawing of 250 points.",
  ),

  pageListTypical: pageListScenario(
    "typical",
    "Read a typical strategy's page list",
    "One strategy:getPageList of a strategy of 4 pages after it changed: the strategy row, its live pages in order and " +
      "each page's settings, read together. No shipped client calls it; the cloud queue will read it where today's " +
      "editor reads strategy:getShell. The note gives getShell's cost on the same strategy.",
  ),

  pageListLarge: pageListScenario(
    "large",
    "Read a large strategy's page list",
    "The same read on a strategy of 20 pages.",
  ),

  pageSwitchNew: {
    title: "Switch to a page not yet read",
    about:
      "With a typical strategy open on its third page, the user goes to the fourth: the page watch stops, page:getSnapshot " +
      "is read once, then watched whole (RemoteEditorSnapshotNotifier.setActivePage).",
    world: "team",
    async run({ env, world }) {
      await rename(world.typical);
      const editor = await new Editor(world.coach, world.typical, { desktop: false }).open(world.typical.pages[2]);
      const result = await metered([world.coach], env, () => editor.switchPage(world.typical.pages[3]));
      editor.close();
      return result;
    },
  },

  pageSwitchBack: {
    title: "Switch back to a page already read",
    about:
      "Then back to the third page, unchanged since it was read seconds earlier: the same two calls. The server answers " +
      "both from its query cache, so they read nothing; neither client keeps the page it left.",
    world: "team",
    async run({ env, world }) {
      await rename(world.typical);
      const editor = await new Editor(world.coach, world.typical, { desktop: false }).open(world.typical.pages[2]);
      await editor.switchPage(world.typical.pages[3]);
      const result = await metered([world.coach], env, () => editor.switchPage(world.typical.pages[2]));
      editor.close();
      return result;
    },
  },

  reopenDesktop: {
    title: "Reopen an unchanged strategy on desktop",
    about:
      "Desktop closes a typical strategy and opens it again with nothing changed. It reads the shell and page from the " +
      "server as on a cold open, and reads the whole strategy again for its copy without checking its content version " +
      "first. Measured within seconds of the first open, so the server answers unchanged queries from its cache; once " +
      "the cache has dropped them a reopen costs what a cold open does.",
    ...reopenScenario(true),
  },

  reopenWeb: {
    title: "Reopen an unchanged strategy on the web",
    about: "The same reopen on the web build, which keeps no copy and so makes no full read.",
    ...reopenScenario(false),
  },

  soloSession: {
    title: "Edit alone: 50 moves on one page",
    about:
      "A typical strategy open on its first page with My Library's tree and top-level list live behind the editor. The " +
      "user moves 50 different items one at a time, each sent alone as the op queue sends an edit made more than 180 ms " +
      "after the last: one live element.patch carrying the whole payload and the names of the moved fields. The first " +
      "edit re-runs the whole page and the editor switches to watching it in slices, as watchPageSnapshot does.",
    world: "team",
    run: (context) => soloSession(context, sendLive),
  },

  soloSessionStore: {
    title: "Edit alone, sent by the cloud store's sender",
    about:
      "soloSession's 50 moves, each sent 180 ms after it is made as the store sender sends it, opted in to ACCOUNT_MISMATCH, one applyBatch " +
      "per move in the op's live form. It measures what the server spends on the cloud store's sender's call pattern; " +
      "it does not run the Dart sender, whose own call count for these moves test/library_store/cloud_sender_test.dart " +
      "checks.",
    world: "team",
    run: async (context) => withSenderCounts(await soloSession(context, sendFromStore)),
  },

  drawingMove: {
    title: "Move a 2,000-point freehand drawing",
    about:
      "One live element.patch moving a freehand drawing of 2,000 points on a 60-item page the editor already watches in " +
      "slices. A move shifts every point, so its fields are listOfPoints and boundingBox and the patch carries the whole " +
      "drawing: sending only changed fields would send the same points.",
    world: "team",
    async run({ env, world, rng }) {
      const coach = world.coach;
      const editor = await new Editor(coach, world.sketch, { desktop: false }).open();
      const clientId = rng.uuid();
      const warmUp = editor.page.elements.find((row) => row.payload.kind === "agent");
      await sendLive(coach, world.sketch.publicId, clientId, liveMove(warmUp, rng));
      await editor.page.settle();
      const result = await metered([coach], env, () =>
        sendLive(coach, world.sketch.publicId, clientId, liveMove(editor.page.row(world.sketch.drawingId), rng)),
      );
      editor.close();
      return result;
    },
  },

  twoPeople: {
    title: "Two people on one page",
    about:
      "A teammate with edit access has the typical strategy's first page open, with Shared's lists live behind their " +
      "editor, while its owner moves 20 items one at a time. The owner's device holds no live queries here, so every " +
      "re-run counted is the teammate's; the owner's own are soloSession's. Each edit waits until the teammate's page " +
      "shows it.",
    world: "team",
    run: (context) => twoPeople(context, sendLive),
  },

  storeReadPage: {
    title: "The store's sender reads a page for itself",
    about:
      "One page:getSnapshot of the typical strategy's first page (60 items), named for the coach's account as the " +
      "store's sender reads a page the queue asks for: a whole-row write after an answer at a revision it did not " +
      "predict, or a page whose landed work it retires. Read after the strategy changed, so the server reads it.",
    world: "team",
    async run({ env, world }) {
      await rename(world.typical);
      return metered([world.coach], env, () =>
        namedPage(world.coach, world.typical.publicId, world.typical.pages[0]),
      );
    },
  },

  storeReadPageDelete: {
    title: "The store's sender reads before a page delete",
    about:
      "A page delete waits for the page list and the page read since this device last changed them. The sender reads " +
      "them, named for the coach's account, one per step: strategy:getPageList, then page:getSnapshot of the page " +
      "(the typical strategy's first page, 60 items). The same page-list read confirms edit access after FORBIDDEN, " +
      "and adopting a strategy reads it first.",
    world: "team",
    async run({ env, world }) {
      await rename(world.typical);
      return metered([world.coach], env, async () => {
        await namedPageList(world.coach, world.typical.publicId);
        await namedPage(world.coach, world.typical.publicId, world.typical.pages[0]);
      });
    },
  },

  storeSoloSessionRetire: {
    title: "Edit alone with no editor open, sent and retired by the store's sender",
    about:
      "soloSession's 50 moves sent by the store's sender with nothing watching: five bursts of ten with a minute's " +
      "pause after each. The sender reads nothing before a send; once a strategy has been quiet for 30 s it reads the " +
      "touched page to retire its landed work, and not that page again for five minutes, so the session reads the page " +
      "twice (test/library_store/cloud_sender_test.dart counts the same). The reads stand in for a source of results " +
      "until the editor's page results come through the store.",
    world: "team",
    async run({ env, world, rng }) {
      const coach = world.coach;
      const session = world.session;
      const rows = (await coach.query("page:getSnapshot", wholePageArgs(session.publicId, session.pages[0]))).elements;
      const clientId = rng.uuid();
      const perBurst = SESSION_EDITS / STORE_BURSTS;
      const result = await metered([coach], env, async () => {
        for (let burst = 0; burst < STORE_BURSTS; burst++) {
          for (const row of rows.slice(burst * perBurst, (burst + 1) * perBurst)) {
            await sendFromStore(coach, session.publicId, clientId, liveMove(row, rng));
          }
          if (burst === 0 || burst === STORE_BURSTS - 1) {
            await namedPage(coach, session.publicId, session.pages[0]);
          }
        }
      });
      return withSenderCounts(result);
    },
  },

  twoPeopleStore: {
    title: "Two people on one page, sent by the cloud store's sender",
    about:
      "twoPeople's 20 moves by the owner, each sent 180 ms after it is made as the store sender sends it, opted in to ACCOUNT_MISMATCH, one " +
      "applyBatch per move in the op's live form, while the teammate watches the page. It measures the server's side " +
      "of that call pattern, not the Dart sender, whose own call count test/library_store/cloud_sender_test.dart checks.",
    world: "team",
    run: async (context) => withSenderCounts(await twoPeople(context, sendFromStore)),
  },

  editorIdleHour: {
    title: "An editor left open for an hour",
    about:
      "A typical strategy open with My Library behind it and no edits for an hour. The only call it makes is " +
      "presence:issueRoomPass, renewed every 60 s (half the 2-minute pass, presence_room.dart _scheduleRenewal): one " +
      "renewal is measured and counted 60 times. Its live queries re-run only when something they read changes.",
    world: "team",
    async run({ env, world }) {
      const coach = world.coach;
      const lists = await watchMyLibrary(coach);
      const editor = await new Editor(coach, world.typical, { desktop: false }).open();
      const result = await metered([coach], env, () =>
        coach.mutation("presence:issueRoomPass", { strategyPublicId: world.typical.publicId }),
      );
      editor.close();
      lists.forEach((unsubscribe) => unsubscribe());
      const hour = {};
      for (const [metric, value] of Object.entries(result.metrics)) hour[metric] = value * ROOM_PASS_RENEWALS_PER_HOUR;
      result.metrics = {
        callsPerHour: hour.functionCalls,
        readBytesPerHour: hour.readBytes,
        writeBytesPerHour: hour.writeBytes,
        sentBytesPerHour: hour.sentBytes,
        queryReruns: result.metrics.queryReruns,
      };
      return result;
    },
  },

  idleHour: {
    title: "Nobody uses the app for an hour",
    about:
      "What the deployment's scheduled jobs (convex/crons.ts) cost in an hour with nothing for them to do: each job is " +
      "run once with nothing waiting for it, and counted as many times as its interval runs it in an hour " +
      "(fold-content-changes 30, fold-community-counts 12, the hourly ones once, the daily ones 1/24). A job's calls " +
      "include the functions it calls.",
    world: "team",
    async run({ env, projectDir }) {
      requireOwnBackend(env, "idleHour");
      const admin = new ConvexHttpClient(env.url, { skipConvexDeploymentUrlCheck: true });
      admin.setAdminAuth(env.adminKey);
      const total = { calls: 0, readBytes: 0, writeBytes: 0, actionMbSeconds: 0 };
      const byFunction = new Map();
      const notes = [];
      for (const job of cronJobs(projectDir)) {
        const measured = await idleRun(env, admin, job);
        const calls = measured.total.runs + measured.total.cachedRuns;
        total.calls += calls * job.perHour;
        total.readBytes += measured.total.readBytes * job.perHour;
        total.writeBytes += measured.total.writeBytes * job.perHour;
        total.actionMbSeconds += measured.total.actionMbSeconds * job.perHour;
        for (const [fn, row] of measured.byFunction) byFunction.set(fn, row);
        notes.push(
          `${job.job}: ${job.perHour.toFixed(2)} runs an hour, ${calls} call(s) and ${measured.total.readBytes} B read a run`,
        );
      }
      notes.push(
        `scheduled actions: ${(total.actionMbSeconds / 1024).toFixed(4)} GB-seconds an hour of local run time ` +
          "(not budgeted: run time varies with the machine)",
      );
      return {
        summary: { total: {}, byFunction },
        notes,
        metrics: {
          callsPerHour: Math.round(total.calls),
          readBytesPerHour: Math.round(total.readBytes),
          writeBytesPerHour: Math.round(total.writeBytes),
        },
      };
    },
  },
};

seedTeam.ownBackendOnly = true;
