// Document-specific local plugin. All originals are exported before cleanup.
// No path edits, flattening, resizing, paint changes, or source-node deletion.
figma.showUI(__html__, { width: 540, height: 300 });
const ROOT_IDS = [
  "906:255",
  "908:2041",
  "908:2473",
  "908:2604",
  "908:3606",
  "908:3672",
];
const BACKUP_NAME = "BACKUP - Map Assets - 2026-09-04 - before cleanup";
let nextId = 0,
  busy = false;
const pending = new Map();
function status(text) {
  figma.ui.postMessage({ type: "status", text });
}
function save(name, data) {
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    figma.ui.postMessage({ type: "save", id, name, data });
  });
}
figma.ui.onmessage = (msg) => {
  if (msg.type === "saved") {
    const w = pending.get(msg.id);
    if (!w) return;
    pending.delete(msg.id);
    msg.error ? w.reject(new Error(msg.error)) : w.resolve(msg.data);
  } else if (msg.type === "run" && !busy) {
    busy = true;
    run().catch((e) => status("STOPPED: " + e.message));
  }
};
function describe(node, depth = 100) {
  const out = { id: node.id, name: node.name, type: node.type };
  for (const key of [
    "width",
    "height",
    "x",
    "y",
    "rotation",
    "visible",
    "locked",
    "opacity",
    "blendMode",
    "isMask",
    "exportSettings",
    "relativeTransform",
    "absoluteTransform",
    "absoluteRenderBounds",
    "fills",
    "strokes",
    "strokeWeight",
    "strokeAlign",
    "effects",
    "characters",
  ]) {
    if (key in node && typeof node[key] !== "symbol") out[key] = node[key];
  }
  if (depth > 0 && "children" in node)
    out.children = node.children.map((n) => describe(n, depth - 1));
  return out;
}
function read(name, binary = false) {
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    figma.ui.postMessage({ type: "read", id, name, binary });
  });
}
function sameBytes(a, b) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}
function stem(n) {
  return n.id.replace(":", "-") + "_" + n.name.replace(/[^A-Za-z0-9_-]/g, "_");
}
function leaves(n) {
  if (
    !("children" in n) ||
    n.type === "INSTANCE" ||
    n.type === "BOOLEAN_OPERATION"
  )
    return [n];
  return n.children.flatMap(leaves);
}
function geometry(n) {
  return leaves(n).map((n) => ({
    id: n.id,
    transform: n.absoluteTransform,
    width: n.width,
    height: n.height,
  }));
}
function dimensions(n) {
  return [n.width, n.height, n.x, n.y];
}
function maxDifference(a, b) {
  if (typeof a === "number" && typeof b === "number") return Math.abs(a - b);
  if (Array.isArray(a))
    return Math.max(0, ...a.map((v, i) => maxDifference(v, b[i])));
  if (a && typeof a === "object")
    return Math.max(0, ...Object.keys(a).map((k) => maxDifference(a[k], b[k])));
  return a === b ? 0 : Infinity;
}
function paints(n, key) {
  return Array.isArray(n[key]) ? n[key].filter((p) => p.visible !== false) : [];
}
function category(n) {
  if (n.name === "Spacer" || n.name === "SizeTangle") return "Export bounds";
  if (!n.visible) return "Hidden reference";
  if (n.type === "TEXT") return "Site labels";
  const fill = paints(n, "fills").find((p) => p.type === "SOLID");
  if (fill && fill.color.r < 0.2 && fill.color.g < 0.15 && fill.color.b < 0.1)
    return "Walkable footprint";
  if (
    fill &&
    fill.color.r > 0.8 &&
    fill.color.g > 0.3 &&
    fill.color.g < 0.7 &&
    fill.color.b < 0.35
  )
    return "Site overlays";
  if (paints(n, "strokes").length) return "Wall details";
  return "Map details";
}
function rename(n, name, changes) {
  if (n.name !== name) {
    changes.push({ id: n.id, before: n.name, after: name });
    n.name = name;
  }
}
function renameDetails(parent, changes) {
  if (!("children" in parent) || parent.type === "INSTANCE") return;
  const counts = {};
  for (const n of parent.children) {
    const generic =
      /^(Vector|Rectangle|Ellipse|Group|Subtract|Exclude|Union)( \d+)?$/.test(
        n.name,
      );
    let name = n.name
      .replace(/^([ABC])[- ]+site$/i, (_, s) => s.toUpperCase() + " Site")
      .replace(/^Site ([ABC])$/i, "$1 Site");
    if (/^Top(?: Details| details| Things)?$/.test(name)) name = "Wall details";
    if (generic) {
      const kind =
        parent.type === "BOOLEAN_OPERATION" ? "Boolean operand" : category(n);
      counts[kind] = (counts[kind] || 0) + 1;
      name = kind + " " + String(counts[kind]).padStart(2, "0");
    }
    rename(n, name, changes);
    renameDetails(n, changes);
  }
}
function groupRuns(parent, classify, groups) {
  // Only contiguous siblings: painter order and mask scopes stay intact.
  const runs = [];
  for (const n of [...parent.children]) {
    const key = classify(n),
      previous = runs[runs.length - 1];
    if (key && previous && previous.key === key) previous.nodes.push(n);
    else runs.push({ key, nodes: [n] });
  }
  for (const run of runs.reverse()) {
    if (!run.key || run.nodes.length < 2 || run.nodes.some((n) => n.isMask))
      continue;
    const index = parent.children.indexOf(run.nodes[0]);
    const group = figma.group(run.nodes, parent, index);
    group.name = run.key;
    groups.push({
      id: group.id,
      name: group.name,
      children: run.nodes.map((n) => n.id),
    });
  }
}
function cleanAsset(asset, changes, groups) {
  // Export-root names and IDs remain stable, including the legacy Sunset typo.
  if (/_map(?:_defense)?$/.test(asset.name)) {
    const artwork = asset.children.find((n) => n.type === "GROUP");
    if (!artwork) throw new Error("Missing artwork: " + asset.name);
    rename(artwork, "Artwork", changes);
    groupRuns(
      artwork,
      (n) => (n.type === "GROUP" ? null : category(n)),
      groups,
    );
    renameDetails(artwork, changes);
    groupRuns(
      asset,
      (n) => (n.name === "Spacer" ? "Export bounds (do not resize)" : null),
      groups,
    );
    for (const n of asset.children) {
      if (n.name === "Export bounds (do not resize)")
        n.children.forEach((c, i) =>
          rename(c, "Spacer " + String(i + 1).padStart(2, "0"), changes),
        );
      else if (!n.visible) rename(n, "Reference - " + n.name, changes);
    }
  } else {
    const callouts = /call_?outs|call_outs/.test(asset.name),
      walls = /spawn_walls/.test(asset.name);
    let count = 0;
    for (const n of asset.children) {
      if (n.name === "SizeTangle")
        rename(n, "Export bounds (do not resize)", changes);
      else if (callouts && n.type === "INSTANCE") {
        const label = n
          .findAll((n) => n.type === "TEXT")
          .map((n) => n.characters)
          .join(" ")
          .replace(/\s+/g, " ")
          .trim();
        rename(n, label || "Callout " + ++count, changes);
      } else if (walls) {
        const fill = paints(n, "fills").find((p) => p.type === "SOLID");
        const side =
          fill && fill.color.g > fill.color.r ? "Attacker" : "Defender";
        rename(
          n,
          side + " barrier " + String(++count).padStart(2, "0"),
          changes,
        );
      } else
        rename(n, "Ultimate orb " + String(++count).padStart(2, "0"), changes);
    }
    groupRuns(
      asset,
      (n) =>
        n.name.startsWith("Export bounds")
          ? null
          : callouts
            ? "Callouts"
            : walls
              ? n.name.startsWith("Attacker")
                ? "Attacker barriers"
                : "Defender barriers"
              : "Ultimate orbs",
      groups,
    );
  }
}
async function run() {
  await figma.loadAllPagesAsync();
  if (figma.root.name !== "Icarus Maps Latest One")
    throw new Error("Unexpected document. No edits made.");
  const page = figma.root.children.find(
    (p) => p.id === "857:104" && p.name === "Map Assets",
  );
  if (!page) throw new Error("Expected Map Assets page.");
  let backup = page.children.find((n) => n.name === BACKUP_NAME);
  const originalRoots = [...page.children],
    roots = ROOT_IDS.map((id) => page.children.find((n) => n.id === id));
  if (roots.some((n) => !n))
    throw new Error("Asset containers changed. No edits made.");
  const assets = roots.flatMap((n) =>
    n.children.filter((n) => n.type === "GROUP"),
  );
  assets.push(page.children.find((n) => n.id === "2097:539"));
  if (assets.length !== 79 || assets.some((n) => !n))
    throw new Error("Expected 79 map assets. No edits made.");
  const baselines = new Map();
  const priorResults = [];
  if (backup) {
    const inventory = JSON.parse(await read("inventory-complete-before.json"));
    const oldNodes = new Map();
    function collect(n) {
      oldNodes.set(n.id, n);
      if (n.children) n.children.forEach(collect);
    }
    collect(inventory.page);
    for (const node of assets) {
      const old = oldNodes.get(node.id),
        name = stem(old);
      baselines.set(node.id, {
        png: new Uint8Array(await read(name + ".before.png", true)),
        dimensions: dimensions(old),
        geometry: geometry(old),
        name,
      });
    }
    for (let i = 1; i <= 79; i++) {
      try {
        priorResults.push(
          JSON.parse(
            await read("result-" + String(i).padStart(2, "0") + ".json"),
          ),
        );
      } catch (e) {
        break;
      }
    }
    for (let i = 0; i < priorResults.length; i++) {
      const node = assets[i],
        baseline = baselines.get(node.id);
      const prior = priorResults[i];
      if (
        prior.id !== node.id ||
        !prior.pngBytesIdentical ||
        prior.maxDimensionDelta > 0.00001 ||
        prior.maxGeometryDelta > 0.001
      )
        throw new Error(
          "Prior comparison failed. Resolve and remove its result before resuming: " +
            node.name,
        );
      const png = await node.exportAsync({
        format: "PNG",
        constraint: { type: "SCALE", value: 2 },
      });
      if (
        !sameBytes(png, baseline.png) ||
        maxDifference(dimensions(node), baseline.dimensions) > 0.00001
      )
        throw new Error("Prior result changed: " + node.name);
    }
  } else {
    await save(
      "inventory-complete-before.json",
      JSON.stringify(
        { document: figma.root.name, page: describe(page) },
        null,
        2,
      ),
    );
    for (let i = 0; i < assets.length; i++) {
      const node = assets[i],
        name = stem(node);
      status(
        "Backing up " +
          (i + 1) +
          "/79: " +
          node.name +
          "\nNo cleanup changes yet.",
      );
      const png = await node.exportAsync({
        format: "PNG",
        constraint: { type: "SCALE", value: 2 },
      });
      const svg = await node.exportAsync({
        format: "SVG",
        svgIdAttribute: true,
      });
      await save(name + ".before.png", Array.from(png));
      await save(name + ".before.svg", Array.from(svg));
      baselines.set(node.id, {
        png,
        dimensions: dimensions(node),
        geometry: geometry(node),
        name,
      });
    }
    // Same-page backup avoids requiring a fourth page on this file's free plan.
    const clones = originalRoots.map((n) => n.clone());
    backup = figma.group(clones, page);
    backup.name = BACKUP_NAME;
    backup.y += 20000;
    backup.locked = true;
    backup.visible = false;
    await save(
      "backup-node.json",
      JSON.stringify(
        {
          id: backup.id,
          name: backup.name,
          visible: false,
          restore:
            "Unhide this group to inspect copies. The .fig local copy is the complete original.",
        },
        null,
        2,
      ),
    );
    figma.commitUndo();
  }
  const report = {
    document: figma.root.name,
    backupId: backup.id,
    assets: priorResults,
    complete: false,
  };
  for (let i = priorResults.length; i < assets.length; i++) {
    const node = assets[i],
      baseline = baselines.get(node.id),
      changes = [],
      groups = [];
    status("Cleaning and comparing " + (i + 1) + "/79: " + node.name);
    cleanAsset(node, changes, groups);
    const png = await node.exportAsync({
      format: "PNG",
      constraint: { type: "SCALE", value: 2 },
    });
    const delta = maxDifference(baseline.dimensions, dimensions(node)),
      geometryDelta = maxDifference(baseline.geometry, geometry(node)),
      pixelBytesIdentical = sameBytes(baseline.png, png);
    await save(baseline.name + ".after.png", Array.from(png));
    await save(
      baseline.name + ".after.svg",
      Array.from(
        await node.exportAsync({ format: "SVG", svgIdAttribute: true }),
      ),
    );
    const result = {
      id: node.id,
      name: node.name,
      beforeDimensions: baseline.dimensions,
      afterDimensions: dimensions(node),
      maxDimensionDelta: delta,
      maxGeometryDelta: geometryDelta,
      pngBytesIdentical: pixelBytesIdentical,
      changes,
      groups,
    };
    report.assets.push(result);
    await save(
      "result-" + String(i + 1).padStart(2, "0") + ".json",
      JSON.stringify(result, null, 2),
    );
    figma.commitUndo();
    if (!pixelBytesIdentical || delta > 0.00001 || geometryDelta > 0.001) {
      await save(
        "cleanup-stopped-" + Date.now() + ".json",
        JSON.stringify(report, null, 2),
      );
      throw new Error(
        "Comparison changed for " +
          node.name +
          ". Last asset is one undo step; inspect before continuing.",
      );
    }
  }
  report.complete = true;
  await save("cleanup-report.json", JSON.stringify(report, null, 2));
  await save(
    "inventory-after.json",
    JSON.stringify(
      { document: figma.root.name, page: describe(page) },
      null,
      2,
    ),
  );
  status(
    "Complete: all 79 assets cleaned.\nEvery PNG is byte-identical at 2x. Dimensions and source geometry verified.\nFull .fig backup, hidden Figma backup group, and before/after SVG exports saved locally.",
  );
}
status(
  "Ready: 79 map assets in Icarus Maps Latest One.\nExports originals, creates a hidden backup group, then cleans and verifies each asset.",
);
