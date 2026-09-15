'use strict';
const $ = id => document.getElementById(id);
const ns = 'http://www.w3.org/2000/svg';
const scene = $('scene');
const draftKey = 'icarus-sightline-review-v1';
let colors, model, board, groups, tool = 'move', drag = null, space = false;
let epoch = 0, dirty = false, running = null, saving = false, zoomBase = 1;
let boards = {}, savedUrl = '', lastDraft = null, savedState = null;
try { lastDraft = JSON.parse(localStorage.getItem(draftKey) || 'null'); boards = lastDraft?.boards || {}; } catch (_) {}

function status(text) { $('status').textContent = text; }
function selected() { return board?.cones.find(c => c.id === board.selected) || board?.cones[0]; }
function uid() { return crypto.randomUUID(); }
function cleanCone(c) { const { result, ...pose } = c; return pose; }
function serialize() {
  return { version: 1, map: model.map, side: model.side, cones: board.cones.map(cleanCone),
    selected: board.selected, annotations: board.annotations, note: $('note').value,
    view: [...board.view], opacity: +$('opacity').value, revision: model.revision };
}
function persist() {
  if (!board || !model) return;
  const snapshot = serialize();
  boards[`${model.map}-${model.side}`] = snapshot;
  if (savedState && JSON.stringify(snapshot) !== savedState) {
    history.replaceState(null, '', '/'); savedState = null;
  }
  try { localStorage.setItem(draftKey, JSON.stringify({ current: `${model.map}-${model.side}`, boards })); }
  catch (_) { status('Browser draft storage is full. Save review to keep this scene.'); }
}
async function api(path, data) {
  const response = await fetch(path, data ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) } : {});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `Request failed: ${response.status}`);
  return result;
}
function el(tag, attributes = {}, parent = scene) {
  const node = document.createElementNS(ns, tag);
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  parent.append(node); return node;
}
function ringsPath(rings) { return rings.map(r => `M${r[0]},${r[1]}` + Array.from({ length: r.length / 2 - 1 }, (_, i) => `L${r[i * 2 + 2]},${r[i * 2 + 3]}`).join('') + 'Z').join(''); }
function world(e) { const p = new DOMPoint(e.clientX, e.clientY).matrixTransform(scene.getScreenCTM().inverse()); return [p.x, p.y]; }
function units(px) { return px * board.view[2] / scene.clientWidth; }
function applyView() {
  scene.setAttribute('viewBox', board.view.join(' '));
  $('zoom').textContent = `${Math.round(zoomBase / board.view[2] * 100)}%`;
  renderHandles();
}
function fit() {
  if (!model) return;
  const [x, y, w, h] = model.viewBox, ratio = scene.clientWidth / Math.max(1, scene.clientHeight);
  let width = w * 1.08, height = h * 1.08;
  if (width / height < ratio) width = height * ratio; else height = width / ratio;
  board.view = [x + w / 2 - width / 2, y + h / 2 - height / 2, width, height];
  zoomBase = width; applyView(); persist();
}
function zoom(factor, point) {
  if (!board) return;
  const [x, y, w, h] = board.view;
  const next = Math.max(2, Math.min(zoomBase * 4, w * factor)), scale = next / w;
  const p = point || [x + w / 2, y + h / 2];
  board.view = [p[0] - (p[0] - x) * scale, p[1] - (p[1] - y) * scale, next, h * scale];
  applyView(); persist();
}
function setTool(value) {
  tool = value; scene.dataset.tool = value;
  document.querySelectorAll('[data-tool]').forEach(button => button.classList.toggle('active', button.dataset.tool === value));
  const help = {
    move: 'Drag the round handle to move. Drag the diamond to aim and resize. Scroll to zoom; Space + drag to pan.',
    pan: 'Drag the map to pan. Scroll to zoom toward the pointer.',
    pen: 'Drag to draw a mark. Scroll to zoom; Space + drag to pan.',
    arrow: 'Drag from the start of the arrow toward the place you want to point out.',
    text: 'Enter text in the sidebar, then click the map to place it.',
  };
  $('help').textContent = help[value];
}
function syncControls() {
  if (!board) return;
  const current = selected();
  $('cone').replaceChildren(...board.cones.map((c, i) => new Option(`Cone ${i + 1}`, c.id)));
  board.selected = current.id; $('cone').value = current.id;
  $('range').value = Math.round(current.range * 10) / 10;
  $('angle').value = Math.round(current.aperture * 180 / Math.PI);
  $('remove').disabled = board.cones.length <= 1;
  $('add').disabled = board.cones.length >= 10;
  updateReadout();
}
function updateReadout() {
  const c = selected(), r = c?.result;
  if (!c) return;
  const supports = r?.supports || [];
  const options = [new Option(`Automatic · ${r?.automaticSupportLabel || 'Ground'}`, '')];
  if (r?.floorMeters != null) options.push(new Option('Ground / lower floor', '__ground__'));
  for (const s of supports) options.push(new Option(`${s.label} · ${s.surfaceMeters?.toFixed(2) ?? '?'} m${s.automaticStandingAllowed ? '' : ' · manual'}`, s.id));
  $('level').replaceChildren(...options); $('level').value = c.surfaceMode === 'ground' ? '__ground__' : c.supportId || '';
  $('height').textContent = r?.eyeMeters == null ? (r?.status || 'Calculating elevation…') :
    `Eye ${r.eyeMeters.toFixed(3)} m · ground ${r.floorMeters?.toFixed(3) ?? '?'} m`;
  $('pose').textContent = `Observer ${c.origin.map(n => n.toFixed(3)).join(', ')} SVG · direction ${(c.direction * 180 / Math.PI).toFixed(1)}°`;
  if (r) status(r.status === 'ready' ? '' : r.status);
}
function buildScene() {
  scene.replaceChildren();
  const defs = el('defs'), clip = el('clipPath', { id: 'floorClip', clipPathUnits: 'userSpaceOnUse' }, defs);
  for (const r of model.receiver) el('path', { d: ringsPath(r.rings), 'clip-rule': r.fillRule || 'evenodd', 'fill-rule': r.fillRule || 'evenodd' }, clip);
  const arrow = el('marker', { id: 'arrowhead', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 5, markerHeight: 5, orient: 'auto-start-reverse' }, defs);
  el('path', { d: 'M0 0 L10 5 L0 10 Z', fill: colors.ink }, arrow);
  el('image', { href: model.artwork, x: model.viewBox[0], y: model.viewBox[1], width: model.viewBox[2], height: model.viewBox[3], 'pointer-events': 'none' });
  groups = { cones: el('g', { 'clip-path': 'url(#floorClip)', 'pointer-events': 'none' }), walls: el('g'), marks: el('g', { 'pointer-events': 'none' }), handles: el('g', { 'data-handles': 'true' }) };
  for (const wall of model.walls) {
    const p = el('path', { d: ringsPath(wall.rings), 'fill-rule': wall.fillRule || 'evenodd', fill: 'transparent', 'pointer-events': 'fill', 'data-wall': wall.id }, groups.walls);
    p.dataset.index = model.walls.indexOf(wall);
  }
  render();
}
function renderCones() {
  if (!groups) return;
  groups.cones.replaceChildren();
  for (const c of board.cones) {
    if (!c.result?.polygon?.length) continue;
    el('polygon', { points: c.result.polygon.map(p => p.join(',')).join(' '), fill: colors.ally, 'fill-opacity': +$('opacity').value / 100 }, groups.cones);
  }
  const active = new Set(selected()?.result?.activeWallIds || []);
  for (const p of groups.walls.children) {
    p.setAttribute('fill', $('walls').checked && active.has(p.dataset.wall) ? colors.accent : 'transparent');
    p.setAttribute('fill-opacity', '.4');
  }
}
function renderHandles() {
  if (!groups || !board) return;
  groups.handles.replaceChildren();
  for (const [i, c] of board.cones.entries()) {
    const active = c.id === board.selected, r = units(active ? 7 : 5), origin = c.origin;
    const a = { cx: origin[0], cy: origin[1], r, fill: active ? colors.accent : colors.text, stroke: colors.bg, 'stroke-width': units(2), 'data-cone': c.id, 'data-handle': 'origin', class: 'origin' };
    el('circle', a, groups.handles);
    const label = el('text', { x: origin[0] + units(11), y: origin[1] - units(9), fill: colors.text, stroke: colors.bg, 'stroke-width': units(3), 'paint-order': 'stroke', 'font-size': units(12), 'font-family': 'system-ui', 'pointer-events': 'none' }, groups.handles);
    label.textContent = String(i + 1);
    if (active) {
      const tip = [origin[0] + Math.cos(c.direction) * c.range, origin[1] + Math.sin(c.direction) * c.range], d = units(7);
      el('line', { x1: origin[0], y1: origin[1], x2: tip[0], y2: tip[1], stroke: colors.text, 'data-guide': 'true', 'stroke-opacity': '.5', 'stroke-width': units(1), 'stroke-dasharray': `${units(4)} ${units(5)}`, 'pointer-events': 'none' }, groups.handles);
      el('path', { d: `M${tip[0]} ${tip[1] - d}l${d} ${d}l${-d} ${d}l${-d} ${-d}Z`, fill: colors.text, stroke: colors.bg, 'stroke-width': units(2), 'data-cone': c.id, 'data-handle': 'aim', 'data-guide': 'true', class: 'aim' }, groups.handles);
    }
  }
}
function renderMarks() {
  if (!groups) return;
  groups.marks.replaceChildren();
  const annotations = drag?.annotation ? [...board.annotations, drag.annotation] : board.annotations;
  for (const a of annotations) {
    if (a.type === 'text') {
      const text = el('text', { x: a.point[0], y: a.point[1], fill: colors.ink, stroke: colors.bg, 'stroke-width': a.width * 2, 'paint-order': 'stroke', 'font-size': a.size, 'font-family': 'system-ui', 'font-weight': '600' }, groups.marks);
      text.textContent = a.text;
    } else {
      const p = el('polyline', { points: a.points.map(p => p.join(',')).join(' '), fill: 'none', stroke: colors.ink, 'stroke-width': a.width, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, groups.marks);
      if (a.type === 'arrow') p.setAttribute('marker-end', 'url(#arrowhead)');
    }
  }
}
function render() { applyView(); renderCones(); renderMarks(); }

function queueQuery() {
  dirty = true;
  if (running) return running;
  const taskEpoch = epoch;
  running = (async () => {
    while (dirty && taskEpoch === epoch) {
      dirty = false;
      const poses = board.cones.map(c => structuredClone(cleanCone(c)));
      const response = await api('/api/query', { map: model.map, side: model.side, cones: poses });
      if (taskEpoch !== epoch) return;
      for (const result of response.cones) {
        const c = board.cones.find(c => c.id === result.id);
        if (!c) continue;
        c.result = result;
        if (c.origin.every((v, i) => v === result.origin[i])) c.supportId = result.supportId;
      }
      renderCones(); updateReadout();
      $('connection').textContent = 'Connected to Icarus';
    }
  })().catch(error => { status(error.message); $('connection').textContent = 'Connection interrupted'; throw error; })
    .finally(() => { running = null; if (dirty && taskEpoch === epoch) queueQuery().catch(() => {}); });
  return running;
}
function changed() { renderHandles(); persist(); queueQuery().catch(() => {}); }

async function loadMap(map, side, restored = null) {
  if (model && board) persist();
  epoch++; dirty = false;
  if (running) { try { await running; } catch (_) {} }
  $('loading').hidden = false; $('loading').textContent = 'Loading map…'; $('save').disabled = true;
  try {
    const next = await api(`/api/model?map=${encodeURIComponent(map)}&side=${encodeURIComponent(side)}`);
    model = next;
    const previous = restored || boards[`${map}-${side}`];
    if (previous) {
      validateScene(previous);
      board = structuredClone(previous);
    } else {
      const c = { id: uid(), origin: [...model.initial], direction: Math.PI, range: 90, aperture: Math.PI / 2, supportId: null };
      board = { cones: [c], selected: c.id, annotations: [], note: '', opacity: 35, view: [...model.viewBox] };
    }
    $('map').value = map; $('side').value = side; $('note').value = board.note;
    $('opacity').value = board.opacity || 35; $('opacityValue').textContent = `${$('opacity').value}%`;
    buildScene();
    const priorView = previous?.view && [...previous.view];
    fit();
    if (priorView) { board.view = priorView; applyView(); }
    syncControls(); await queueQuery(); persist();
    if (previous?.revision && previous.revision.modelSha256 !== model.revision.modelSha256) status('This saved scene used older map data. The current engine has recalculated its cones.');
    $('loading').hidden = true; $('save').disabled = false;
  } catch (error) { $('loading').textContent = `Could not load map: ${error.message}`; status(error.message); }
}
function validateScene(data) {
  const finite = v => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) < 1000000;
  const point = p => Array.isArray(p) && p.length === 2 && p.every(finite);
  if (data.version !== 1 || !Array.isArray(data.cones) || !data.cones.length || data.cones.length > 10 ||
      !data.cones.every(c => typeof c.id === 'string' && point(c.origin) && finite(c.direction) && c.range >= 1 && c.range <= 500 && c.aperture >= .05 && c.aperture <= Math.PI * 2) ||
      !Array.isArray(data.annotations) || data.annotations.length > 2000 ||
      !data.annotations.every(a => finite(a.width) && a.width > 0 && (
        a.type === 'text' ? point(a.point) && typeof a.text === 'string' && a.text.length <= 160 && finite(a.size) :
        ['pen', 'arrow'].includes(a.type) && Array.isArray(a.points) && a.points.length <= 20000 && a.points.every(point))) ||
      typeof data.note !== 'string' || data.note.length > 20000 || !Array.isArray(data.view) || data.view.length !== 4 || !data.view.every(finite) || data.view[2] <= 0 || data.view[3] <= 0) {
    throw new Error('This file is not a valid Icarus review scene.');
  }
}

scene.addEventListener('pointerdown', e => {
  if (!board || saving || e.button > 1) return;
  e.preventDefault(); const p = world(e);
  scene.setPointerCapture(e.pointerId);
  const isPan = space || e.button === 1 || tool === 'pan';
  if (isPan) { drag = { type: 'pan', start: [e.clientX, e.clientY], view: [...board.view] }; return; }
  if (tool === 'text') {
    const text = $('label').value.trim();
    if (!text) { $('label').focus(); status('Enter text in the sidebar first.'); return; }
    board.annotations.push({ type: 'text', text, point: p, width: units(1.4), size: units(16) }); renderMarks(); persist(); return;
  }
  if (tool === 'pen' || tool === 'arrow') { drag = { type: tool, annotation: { type: tool, points: [p, p], width: units(3) } }; renderMarks(); return; }
  const target = e.target.closest('[data-cone]');
  if (target) { board.selected = target.dataset.cone; syncControls(); renderCones(); }
  const c = selected();
  drag = { type: target?.dataset.handle === 'aim' ? 'aim' : 'move', cone: c.id, offset: target ? [p[0] - c.origin[0], p[1] - c.origin[1]] : [0, 0] };
  if (!target) { c.origin = p; c.supportId = null; c.surfaceMode = 'auto'; changed(); }
  renderHandles();
});
scene.addEventListener('pointermove', e => {
  if (!model || saving) return;
  const p = world(e);
  if (!drag) {
    const wallNode = e.target.closest('[data-wall]');
    $('wallInfo').hidden = !wallNode;
    if (wallNode) {
      const wall = model.walls[+wallNode.dataset.index], c = selected(), active = c.result?.activeWallIds.includes(wall.id);
      const bands = wall.bands.map(([a, b]) => `${(a + (wall.floorElevationMeters || 0)).toFixed(2)}–${b == null ? '∞' : (b + (wall.floorElevationMeters || 0)).toFixed(2)} m`).join(', ');
      $('wallInfo').textContent = `${wall.id} · ${active ? 'Blocks' : 'Clear'} at selected eye height · ${bands || 'No blocking interval'}`;
    }
    return;
  }
  $('wallInfo').hidden = true;
  if (drag.type === 'pan') {
    board.view = [drag.view[0] - (e.clientX - drag.start[0]) * drag.view[2] / scene.clientWidth,
      drag.view[1] - (e.clientY - drag.start[1]) * drag.view[3] / scene.clientHeight, drag.view[2], drag.view[3]];
    applyView(); return;
  }
  if (drag.annotation) {
    if (drag.type === 'arrow') drag.annotation.points[1] = p;
    else if (Math.hypot(...p.map((v, i) => v - drag.annotation.points.at(-1)[i])) > units(1)) drag.annotation.points.push(p);
    renderMarks(); return;
  }
  const c = board.cones.find(c => c.id === drag.cone);
  if (drag.type === 'move') c.origin = [p[0] - drag.offset[0], p[1] - drag.offset[1]];
  else { c.direction = Math.atan2(p[1] - c.origin[1], p[0] - c.origin[0]); c.range = Math.max(1, Math.min(500, Math.hypot(p[0] - c.origin[0], p[1] - c.origin[1]))); $('range').value = c.range.toFixed(1); }
  changed();
});
function endDrag() {
  if (!drag) return;
  if (drag.annotation) board.annotations.push(drag.annotation);
  drag = null; renderMarks(); persist();
}
scene.addEventListener('pointerup', endDrag); scene.addEventListener('pointercancel', endDrag);
scene.addEventListener('pointerleave', () => { $('wallInfo').hidden = true; });
scene.addEventListener('wheel', e => { if (!saving) { e.preventDefault(); zoom(Math.exp(e.deltaY * .001), world(e)); } }, { passive: false });
scene.addEventListener('contextmenu', e => e.preventDefault());
window.addEventListener('keydown', e => { if (e.code === 'Space' && !['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) { e.preventDefault(); space = true; } });
window.addEventListener('keyup', e => { if (e.code === 'Space') space = false; });
window.addEventListener('blur', () => { space = false; endDrag(); });
window.addEventListener('resize', () => { if (!board) return; board.view[3] = board.view[2] * scene.clientHeight / scene.clientWidth; applyView(); });
document.querySelectorAll('button[data-tool]').forEach(b => b.onclick = () => setTool(b.dataset.tool));
$('map').onchange = () => loadMap($('map').value, $('side').value);
$('side').onchange = () => loadMap($('map').value, $('side').value);
$('fit').onclick = fit; $('plus').onclick = () => zoom(.75); $('minus').onclick = () => zoom(1.3333);
$('cone').onchange = () => { board.selected = $('cone').value; syncControls(); render(); persist(); };
$('add').onclick = () => {
  if (board.cones.length >= 10) return;
  const c = { ...cleanCone(selected()), id: uid(), origin: [...selected().origin] }; board.cones.push(c); board.selected = c.id;
  syncControls(); setTool('move'); changed(); status('Click the map to place the new cone.');
};
$('remove').onclick = () => { if (board.cones.length <= 1) return; board.cones = board.cones.filter(c => c.id !== board.selected); board.selected = board.cones[0].id; syncControls(); render(); changed(); };
$('level').onchange = () => {
  const value = $('level').value, c = selected();
  c.surfaceMode = value === '__ground__' ? 'ground' : value ? 'support' : 'auto';
  c.supportId = c.surfaceMode === 'support' ? value : null;
  changed();
};
$('range').onchange = () => { selected().range = Math.max(1, Math.min(500, +$('range').value || 90)); syncControls(); changed(); };
$('angle').onchange = () => { selected().aperture = Math.max(5, Math.min(360, +$('angle').value || 90)) * Math.PI / 180; syncControls(); changed(); };
$('opacity').oninput = () => { $('opacityValue').textContent = `${$('opacity').value}%`; renderCones(); persist(); };
$('walls').onchange = renderCones;
$('undo').onclick = () => { board.annotations.pop(); renderMarks(); persist(); };
$('clear').onclick = () => { if (board.annotations.length && confirm('Clear all marks on this map and side?')) { board.annotations = []; renderMarks(); persist(); } };
$('note').oninput = persist;

function download(blob, filename) { const url = URL.createObjectURL(blob), a = document.createElement('a'); a.href = url; a.download = filename; a.click(); setTimeout(() => URL.revokeObjectURL(url), 30000); }
function wrap(ctx, text, maxWidth) {
  const lines = [];
  for (const paragraph of text.split('\n')) {
    let line = '';
    for (const word of paragraph.split(' ')) { if (line && ctx.measureText(`${line} ${word}`).width > maxWidth) { lines.push(line); line = word; } else line += (line ? ' ' : '') + word; }
    lines.push(line);
  }
  return lines;
}
async function screenshot() {
  const clone = scene.cloneNode(true); clone.querySelectorAll('[data-guide]').forEach(e => e.remove());
  clone.setAttribute('width', scene.clientWidth * 2); clone.setAttribute('height', scene.clientHeight * 2);
  const svg = new Blob([new XMLSerializer().serializeToString(clone)], { type: 'image/svg+xml;charset=utf-8' });
  const url = URL.createObjectURL(svg), img = new Image();
  try {
    await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = () => reject(new Error('Could not render the review image.')); img.src = url; });
    const canvas = document.createElement('canvas'); canvas.width = Math.min(2800, Math.max(1200, scene.clientWidth * 2));
    const ctx = canvas.getContext('2d'); ctx.font = '20px system-ui';
    const lines = wrap(ctx, $('note').value, canvas.width - 64);
    const mapHeight = canvas.width * scene.clientHeight / scene.clientWidth;
    canvas.height = 100 + mapHeight + Math.max(65, lines.length * 28 + 40);
    ctx.fillStyle = colors.bg; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = colors.text; ctx.font = '600 26px system-ui'; ctx.fillText(`Icarus sightline review · ${model.map} · ${model.side}`, 32, 40);
    ctx.fillStyle = colors.muted; ctx.font = '18px system-ui'; ctx.fillText(`Eye heights: ${board.cones.map((c, i) => `cone ${i + 1} ${c.result?.eyeMeters?.toFixed(3) ?? '?'} m`).join(' · ')}`, 32, 74);
    ctx.drawImage(img, 0, 100, canvas.width, mapHeight);
    ctx.fillStyle = colors.text; ctx.font = '20px system-ui'; lines.forEach((line, i) => ctx.fillText(line, 32, 100 + mapHeight + 30 + i * 28));
    return canvas.toDataURL('image/png');
  } finally { URL.revokeObjectURL(url); }
}
async function frozen(action) {
  if (saving || !board) return;
  saving = true; endDrag();
  const disabled = [...document.querySelectorAll('button,input,select,textarea')].map(e => [e, e.disabled]);
  disabled.forEach(([e]) => e.disabled = true);
  try { await queueQuery(); if (running) await running; await action(); }
  catch (error) { status(error.message); }
  finally { saving = false; disabled.forEach(([e, value]) => e.disabled = value); }
}
$('save').onclick = () => frozen(async () => {
  status('Saving scene and image…');
  const state = serialize(), png = await screenshot();
  const result = await api('/api/reviews', { ...state, screenshotPng: png });
  savedUrl = new URL(result.url, location.origin).href;
  $('saved').hidden = false; $('savedLink').href = savedUrl; $('savedLink').textContent = `Review ${result.id}`;
  history.replaceState(null, '', result.url); savedState = JSON.stringify(serialize());
  status('Saved scene, notes, and PNG on the host.'); persist();
});
$('copy').onclick = async () => { try { await navigator.clipboard.writeText(savedUrl); status('Review link copied.'); } catch (_) { status('Select and copy the saved review link.'); } };
$('png').onclick = () => frozen(async () => { const data = await screenshot(); download(await (await fetch(data)).blob(), `icarus-${model.map}-${model.side}-review.png`); status('Annotated image downloaded.'); });
$('json').onclick = () => frozen(async () => download(new Blob([JSON.stringify(serialize(), null, 2)], { type: 'application/json' }), `icarus-${model.map}-${model.side}-review.json`));
$('import').onclick = () => $('file').click();
$('file').onchange = async () => {
  try { const file = $('file').files[0]; if (!file) return; if (file.size > 3 * 1024 * 1024) throw new Error('Scene file is too large.'); const data = JSON.parse(await file.text()); validateScene(data); await loadMap(data.map, data.side, data); }
  catch (error) { status(error.message); } finally { $('file').value = ''; }
};

(async () => {
  try {
    const config = await api('/api/config'); colors = config.colors;
    for (const [key, value] of Object.entries(colors)) document.documentElement.style.setProperty(`--${key}`, value);
    $('map').replaceChildren(...config.maps.map(m => new Option(m[0].toUpperCase() + m.slice(1), m)));
    setTool('move');
    const reviewId = new URLSearchParams(location.search).get('review');
    if (reviewId) { const data = await api(`/api/reviews/${encodeURIComponent(reviewId)}`); validateScene(data); await loadMap(data.map, data.side, data); savedState = JSON.stringify(serialize()); savedUrl = location.href; $('saved').hidden = false; $('savedLink').href = savedUrl; $('savedLink').textContent = `Review ${reviewId}`; }
    else { const [map, side] = (lastDraft?.current || 'icebox-attack').split('-'); await loadMap(map, side); }
  } catch (error) { $('loading').textContent = error.message; $('connection').textContent = 'Could not connect'; }
})();
