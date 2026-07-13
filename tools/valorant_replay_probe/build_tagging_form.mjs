// Generates a self-contained HTML audit form for an ability tagging worklist.
// Usage: node build_tagging_form.mjs [--in <worklist.json>] [--out <form.html>] [--key <localStorage key>] [--title <heading>]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const base = path.join(path.dirname(fileURLToPath(import.meta.url)), "out", "corpus");
const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
};
const inPath = arg("--in", path.join(base, "tagging_worklist_trimmed.json"));
const outPath = arg("--out", path.join(base, "ability_tagging.html"));
const storageKey = arg("--key", "icarus_ability_tagging_v1");
const title = arg("--title", "Ability close tagging");

const rawWorklist = JSON.parse(fs.readFileSync(inPath, "utf8"));
const items = Array.isArray(rawWorklist) ? rawWorklist : rawWorklist.items;
const legend = JSON.parse(fs.readFileSync(path.join(base, "_replay_legend.json"), "utf8"));

// Game numbering stays stable across tagging rounds: derive labels from the
// full legend, then only render the games this worklist actually uses.
const gameLabels = {};
Object.keys(legend)
  .sort((a, b) => legend[a].map.localeCompare(legend[b].map) || legend[a].rounds - legend[b].rounds)
  .forEach((u, i) => (gameLabels[u] = `Game ${i + 1}`));
const usedReplays = new Set(items.map((it) => it.replayUuid));

const OUTCOME_LABELS = {
  destroyed: "Destroyed",
  recalled: "Recalled (remote)",
  "picked-up": "Picked up (owner nearby)",
  "owner-death-cleanup": "Owner died",
  "phase-transition-or-other-early-removal": "Phase change / other",
};
const EXTRA_OUTCOMES = [
  ["round-ended", "Round ended"],
  ["expired", "Expired (timer)"],
  ["not-found", "Couldn't find it"],
];
OUTCOME_LABELS["round-ended"] = "Round ended";
OUTCOME_LABELS["expired"] = "Expired (timer)";
const dedupeOutcomes = (pairs) => {
  const seen = new Set();
  return pairs.filter(([v]) => (seen.has(v) ? false : (seen.add(v), true)));
};

const data = {
  generated: "2026-07-12",
  title,
  storageKey,
  games: Object.fromEntries(
    Object.entries(legend)
      .filter(([u]) => usedReplays.has(u))
      .map(([u, g]) => [u, { ...g, label: gameLabels[u] }])
  ),
  items: items.map((it) => ({
    id: `${it.replayUuid.slice(0, 8)}_${it.actorNetGuid}_${it.timeMs}`,
    replayUuid: it.replayUuid,
    game: gameLabels[it.replayUuid],
    round: it.round,
    timeMs: it.timeMs,
    agent: it.agent,
    slot: it.slot,
    abilityName: it.abilityName,
    actorClass: it.actorClass,
    actorNetGuid: it.actorNetGuid,
    lifetimeMs: it.observedLifetimeMs,
    earlyByMs: it.earlyByMs,
    outcomes: dedupeOutcomes([
      ...it.candidateOutcomes
        .filter((c) => c !== "phase-transition-or-other-early-removal")
        .map((c) => [c, OUTCOME_LABELS[c] || c]),
      ["phase-transition-or-other-early-removal", OUTCOME_LABELS["phase-transition-or-other-early-removal"]],
      ...EXTRA_OUTCOMES,
    ]),
  })),
};

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title} — icarus replay corpus</title>
<style>
  :root { --bg:#0f1419; --card:#1a2129; --card2:#212a34; --line:#2e3a46; --text:#e7edf3; --dim:#8fa1b3; --accent:#ff4655; --ok:#3ddc84; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 "Segoe UI",system-ui,sans-serif; }
  .wrap { max-width:880px; margin:0 auto; padding:24px 20px 120px; }
  h1 { font-size:22px; margin:0 0 4px; } h1 em { color:var(--accent); font-style:normal; }
  .sub { color:var(--dim); margin-bottom:20px; }
  .sticky { position:sticky; top:0; z-index:5; background:var(--bg); padding:10px 0; border-bottom:1px solid var(--line); margin-bottom:18px; display:flex; align-items:center; gap:14px; }
  .bar { flex:1; height:8px; background:var(--card2); border-radius:4px; overflow:hidden; }
  .bar i { display:block; height:100%; width:0; background:var(--ok); transition:width .2s; }
  .games { display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:10px; margin-bottom:26px; }
  .game { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:10px 12px; font-size:13px; }
  .game b { font-size:14px; } .game .meta { color:var(--dim); }
  .game .side { margin-top:4px; } .game .side span { color:var(--dim); }
  h2 { font-size:16px; margin:30px 0 10px; padding-bottom:6px; border-bottom:1px solid var(--line); }
  h2 small { color:var(--dim); font-weight:normal; }
  .item { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; margin-bottom:10px; }
  .item.done { border-color:var(--ok); }
  .loc { display:flex; flex-wrap:wrap; gap:8px 16px; align-items:baseline; margin-bottom:8px; }
  .chip { background:var(--card2); border-radius:6px; padding:2px 9px; font-size:13px; }
  .chip b { color:var(--accent); }
  .loc .t { font-size:17px; font-weight:600; }
  .loc .dim { color:var(--dim); font-size:12.5px; }
  .opts { display:flex; flex-wrap:wrap; gap:6px; margin:6px 0 8px; }
  .opts label { background:var(--card2); border:1px solid var(--line); border-radius:7px; padding:5px 11px; cursor:pointer; font-size:13.5px; user-select:none; }
  .opts input { display:none; }
  .opts input:checked + span { color:#08110a; }
  .opts label:has(input:checked) { background:var(--ok); border-color:var(--ok); color:#08110a; font-weight:600; }
  .item textarea { width:100%; background:var(--card2); border:1px solid var(--line); border-radius:7px; color:var(--text); padding:6px 9px; font:13px/1.4 inherit; resize:vertical; min-height:30px; }
  .item textarea::placeholder { color:#5c6b7a; }
  .export { position:fixed; bottom:0; left:0; right:0; background:var(--card); border-top:1px solid var(--line); padding:12px 20px; display:flex; gap:12px; align-items:center; }
  .export button { background:var(--accent); border:0; border-radius:8px; color:#fff; font:600 14px inherit; padding:9px 18px; cursor:pointer; }
  .export button.ghost { background:var(--card2); border:1px solid var(--line); }
  .export .status { color:var(--dim); font-size:13px; }
  #out { display:none; width:100%; height:150px; margin-top:8px; background:var(--card2); color:var(--text); border:1px solid var(--line); border-radius:8px; font:12px/1.4 Consolas,monospace; padding:8px; }
  .globalnotes textarea { width:100%; min-height:60px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>${title} <em>// ${data.items.length} moments</em></h1>
  <div class="sub">For each item: open the game in the Valorant replay viewer, jump to the round, scrub to the match time, watch the object disappear, pick what happened. Answers autosave locally; hit <b>Export</b> at the end and paste the JSON back to Claude.</div>

  <div class="games" id="games"></div>

  <div class="sticky"><div class="bar"><i id="prog"></i></div><span id="count" class="status"></span></div>

  <div id="list"></div>

  <h2>General notes</h2>
  <div class="item globalnotes"><textarea id="gnotes" placeholder="Anything systematic you noticed — patterns, viewer quirks, suspicious rows…"></textarea></div>
</div>

<div class="export">
  <button onclick="doExport()">Export results JSON</button>
  <button class="ghost" onclick="copyOut()">Copy to clipboard</button>
  <span class="status" id="xstatus"></span>
</div>
<textarea id="out" readonly></textarea>

<script>
const DATA = ${JSON.stringify(data)};
const LS = DATA.storageKey;
const state = JSON.parse(localStorage.getItem(LS) || "{}");
const fmt = ms => { const t = Math.round(ms/1000); return Math.floor(t/60) + ":" + String(t%60).padStart(2,"0"); };

const gamesEl = document.getElementById("games");
for (const [u,g] of Object.entries(DATA.games).sort((a,b)=>a[1].label.localeCompare(b[1].label,undefined,{numeric:true}))) {
  gamesEl.insertAdjacentHTML("beforeend", \`<div class="game"><b>\${g.label}</b> — \${g.map} <span class="meta">· \${g.rounds} rounds · ~\${g.durationMin} min</span>
    <div class="side"><span>DEF:</span> \${g.defenders.join(", ")}</div>
    <div class="side"><span>ATK:</span> \${g.attackers.join(", ")}</div></div>\`);
}

const list = document.getElementById("list");
let lastAbility = "";
for (const it of DATA.items) {
  const ab = it.agent + " — " + it.abilityName;
  if (ab !== lastAbility) { lastAbility = ab; list.insertAdjacentHTML("beforeend", \`<h2>\${ab} <small>(\${it.actorClass})</small></h2>\`); }
  const opts = it.outcomes.map(([v,l]) =>
    \`<label><input type="radio" name="tag_\${it.id}" value="\${v}"><span>\${l}</span></label>\`).join("");
  const life = (it.lifetimeMs/1000).toFixed(1) + "s" + (it.earlyByMs != null ? \` (ended \${(it.earlyByMs/1000).toFixed(1)}s early)\` : "");
  list.insertAdjacentHTML("beforeend", \`
    <div class="item" id="item_\${it.id}">
      <div class="loc">
        <span class="chip"><b>\${it.game}</b> \${DATA.games[it.replayUuid].map}</span>
        <span class="chip">Round \${it.round}</span>
        <span class="t">@ \${fmt(it.timeMs)}</span>
        <span class="dim">object lived \${life}</span>
      </div>
      <div class="opts">\${opts}</div>
      <textarea data-id="\${it.id}" placeholder="Optional comment — what you saw, uncertainty, anything odd…"></textarea>
    </div>\`);
}

// restore + wire events
document.querySelectorAll('input[type=radio]').forEach(r => {
  const id = r.name.slice(4);
  if (state[id] && state[id].tag === r.value) r.checked = true;
  r.addEventListener("change", () => { (state[id] ||= {}).tag = r.value; save(); });
});
document.querySelectorAll("textarea[data-id]").forEach(t => {
  const id = t.dataset.id;
  if (state[id] && state[id].comment) t.value = state[id].comment;
  t.addEventListener("input", () => { (state[id] ||= {}).comment = t.value; save(); });
});
const gn = document.getElementById("gnotes");
gn.value = state.__globalNotes || "";
gn.addEventListener("input", () => { state.__globalNotes = gn.value; save(); });

function save() { localStorage.setItem(LS, JSON.stringify(state)); refresh(); }
function refresh() {
  let done = 0;
  for (const it of DATA.items) {
    const d = state[it.id] && state[it.id].tag;
    document.getElementById("item_" + it.id).classList.toggle("done", !!d);
    if (d) done++;
  }
  document.getElementById("prog").style.width = (100*done/DATA.items.length) + "%";
  document.getElementById("count").textContent = done + " / " + DATA.items.length + " tagged";
}
refresh();

function buildExport() {
  return JSON.stringify({
    schema: "icarus-ability-tagging-v1",
    exportedAt: new Date().toISOString(),
    globalNotes: state.__globalNotes || "",
    tags: DATA.items.map(it => ({
      id: it.id, replayUuid: it.replayUuid, actorNetGuid: it.actorNetGuid, timeMs: it.timeMs,
      round: it.round, agent: it.agent, slot: it.slot, abilityName: it.abilityName, actorClass: it.actorClass,
      tag: (state[it.id] && state[it.id].tag) || null,
      comment: (state[it.id] && state[it.id].comment) || "",
    })),
  }, null, 1);
}
function doExport() {
  const json = buildExport();
  const out = document.getElementById("out");
  out.style.display = "block"; out.value = json;
  const blob = new Blob([json], {type:"application/json"});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob); a.download = "ability_tagging_results.json"; a.click();
  const untagged = DATA.items.filter(it => !(state[it.id] && state[it.id].tag)).length;
  document.getElementById("xstatus").textContent = "Downloaded" + (untagged ? \` — \${untagged} still untagged (exported as null)\` : " — all " + DATA.items.length + " tagged 🎉");
}
function copyOut() {
  navigator.clipboard.writeText(buildExport()).then(() => {
    document.getElementById("xstatus").textContent = "Copied to clipboard";
  });
}
</script>
</body>
</html>`;

fs.writeFileSync(outPath, html);
console.log("written:", outPath, `(${data.items.length} items, ${Object.keys(data.games).length} games)`);
