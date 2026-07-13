import {
  AGENTS,
  MAPS,
  abilityForEvent,
  agentForEvent,
  castLocations,
  eventLabel,
  formatTime,
  groupAbilityEvents,
  identityWarnings,
  isCastActive,
  isUtilityActive,
  mapKeyFromTrack,
  normalizeAbilityEvents,
  ownerPlayer,
  playerSampleAt,
  replayPositionToWorld,
  spectatorKey,
  trackDuration,
  utilityPositionAt,
  worldToPercent,
} from './replay-audit-core.js';

const $ = (selector) => document.querySelector(selector);
const elements = {
  file: $('#track-file'),
  url: $('#track-url'),
  loadUrl: $('#load-url'),
  mapName: $('#map-name'),
  summary: $('#track-summary'),
  coverageWarning: $('#coverage-warning'),
  mapArt: $('#map-art'),
  callouts: $('#map-callouts'),
  markerLayer: $('#marker-layer'),
  trailLayer: $('#trail-layer'),
  empty: $('#empty-state'),
  stage: $('#map-stage'),
  showCallouts: $('#show-callouts'),
  showPlayers: $('#show-players'),
  showTrails: $('#show-trails'),
  previousEvent: $('#previous-event'),
  nextEvent: $('#next-event'),
  rewind: $('#rewind'),
  forward: $('#forward'),
  play: $('#play'),
  timeline: $('#timeline'),
  currentTime: $('#current-time'),
  duration: $('#duration'),
  eventLabel: $('#event-label'),
  eventTiming: $('#event-timing'),
  eventFacts: $('#event-facts'),
  abilityIcon: $('#ability-icon'),
  spectatorCallout: $('#spectator-callout'),
  spectatorKey: $('#spectator-key'),
  casterName: $('#caster-name'),
  eventFilter: $('#event-filter'),
  eventList: $('#event-list'),
  eventCount: $('#event-count'),
  note: $('#audit-note'),
  saveVerdict: $('#save-verdict'),
  exportAudit: $('#export-audit'),
  snapshot: $('#snapshot-json'),
  dropOverlay: $('#drop-overlay'),
  status: $('#status'),
};

const state = {
  track: null,
  source: null,
  mapKey: null,
  durationMs: 0,
  timeMs: 0,
  events: [],
  filteredEvents: [],
  groups: [],
  filteredGroups: [],
  selectedIndex: -1,
  isPlaying: false,
  playStartedAt: 0,
  playStartedTimeMs: 0,
  selectedVerdict: null,
  auditEntries: [],
  renderTimer: null,
};

function showStatus(message, timeout = 2600) {
  elements.status.textContent = message;
  elements.status.classList.add('visible');
  clearTimeout(showStatus.timer);
  showStatus.timer = setTimeout(() => elements.status.classList.remove('visible'), timeout);
}

function safeText(value, fallback = '—') {
  const text = String(value ?? '').trim();
  return text || fallback;
}

async function fetchSvg(url, replacements = null) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Unable to load ${url}: ${response.status}`);
  let svg = await response.text();
  if (replacements) {
    for (const [source, replacement] of Object.entries(replacements)) {
      svg = svg.replaceAll(source, replacement).replaceAll(source.toLowerCase(), replacement);
    }
  }
  return svg;
}

async function renderMapAssets() {
  const map = MAPS[state.mapKey];
  if (!map) return;
  const palette = { '#271406': '#231943', '#B27C40': '#7565a8', '#F08234': '#a78bfa' };
  const [mapSvg, calloutsSvg] = await Promise.all([
    fetchSvg(map.asset, palette),
    fetchSvg(map.calloutsAsset).catch(() => ''),
  ]);
  elements.mapArt.innerHTML = mapSvg;
  elements.callouts.innerHTML = calloutsSvg;
  elements.callouts.style.display = elements.showCallouts.checked ? '' : 'none';
}

function currentEvent() {
  return state.selectedIndex >= 0 ? state.events[state.selectedIndex] : null;
}

function currentGroup() {
  const event = currentEvent();
  return event ? state.groups.find((group) => group.events.includes(event)) ?? null : null;
}

function setTime(timeMs, { render = true } = {}) {
  state.timeMs = Math.max(0, Math.min(state.durationMs, Math.round(Number(timeMs) || 0)));
  elements.timeline.value = String(state.timeMs);
  elements.currentTime.value = formatTime(state.timeMs);
  if (state.isPlaying) {
    state.playStartedAt = performance.now();
    state.playStartedTimeMs = state.timeMs;
  }
  if (render) renderFrame();
}

function setPlaying(next) {
  if (!state.track) return;
  state.isPlaying = Boolean(next);
  state.playStartedAt = performance.now();
  state.playStartedTimeMs = state.timeMs;
  elements.play.textContent = state.isPlaying ? 'Pause' : 'Play';
  if (state.isPlaying) schedulePlayback();
  else clearTimeout(state.renderTimer);
  updateSnapshot();
}

function schedulePlayback() {
  clearTimeout(state.renderTimer);
  if (!state.isPlaying) return;
  state.renderTimer = setTimeout(() => {
    const elapsed = performance.now() - state.playStartedAt;
    const next = state.playStartedTimeMs + elapsed;
    if (next >= state.durationMs) {
      setTime(state.durationMs);
      setPlaying(false);
      return;
    }
    setTime(next);
    schedulePlayback();
  }, 100);
}

function nearestGroup(direction) {
  if (!state.groups.length) return null;
  if (direction < 0) {
    for (let i = state.groups.length - 1; i >= 0; i -= 1) {
      if (state.groups[i].timeMs < state.timeMs - 25) return state.groups[i];
    }
    return state.groups[0];
  }
  for (let i = 0; i < state.groups.length; i += 1) {
    if (state.groups[i].timeMs > state.timeMs + 25) return state.groups[i];
  }
  return state.groups.at(-1);
}

function selectEvent(idOrIndex, { seek = true } = {}) {
  if (!state.events.length) return;
  const index = typeof idOrIndex === 'string'
    ? state.events.findIndex((event) => event.id === idOrIndex)
    : Number(idOrIndex);
  if (!Number.isInteger(index) || index < 0 || index >= state.events.length) {
    throw new RangeError(`Unknown ability event: ${idOrIndex}`);
  }
  state.selectedIndex = index;
  const event = currentEvent();
  if (seek) {
    setPlaying(false);
    setTime(event.timeMs);
  }
  renderEventDetails();
  renderEventList();
  renderFrame();
  return snapshotObject();
}

function selectGroup(group, options) {
  if (!group) return null;
  return selectEvent(state.events.indexOf(group.representative), options);
}

function seekEvent(direction) {
  selectGroup(nearestGroup(direction));
}

function eventIcon(event) {
  return abilityForEvent(event?.source, state.track)?.icon ?? agentForEvent(event?.source, state.track)?.icon ?? '';
}

function normalizeSearch(value) {
  return String(value ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function eventHaystack(event) {
  return [
    event.label,
    event.source.phase,
    event.kind,
  ].filter(Boolean).join(' ');
}

function applyEventFilter() {
  const tokens = normalizeSearch(elements.eventFilter.value).split(/\s+/).filter(Boolean);
  state.filteredGroups = tokens.length
    ? state.groups.filter((group) => {
        const haystack = normalizeSearch(group.events.map(eventHaystack).join(' '));
        return tokens.every((token) => haystack.includes(token));
      })
    : state.groups;
  renderEventList();
}

function renderEventList() {
  const filteredPhaseCount = state.filteredGroups.reduce((sum, group) => sum + group.events.length, 0);
  elements.eventCount.textContent = `${state.filteredGroups.length.toLocaleString()} actions · ${filteredPhaseCount.toLocaleString()} phases`;
  elements.eventList.replaceChildren();
  if (!state.filteredGroups.length) {
    const empty = document.createElement('p');
    empty.className = 'event-row';
    empty.textContent = 'No matching ability events';
    elements.eventList.append(empty);
    return;
  }

  const selected = currentGroup();
  let center = selected ? state.filteredGroups.indexOf(selected) : 0;
  if (center < 0) center = 0;
  const start = Math.max(0, center - 25);
  const visible = state.filteredGroups.slice(start, start + 50);
  for (const group of visible) {
    const event = group.representative;
    const sourceIndex = state.events.indexOf(event);
    const groupSelected = group === selected;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `event-row${groupSelected ? ' selected' : ''}`;
    button.dataset.eventId = event.id;
    button.dataset.groupId = group.id;
    button.dataset.eventIndex = String(sourceIndex);
    button.setAttribute('role', 'option');
    button.setAttribute('aria-selected', String(groupSelected));
    button.innerHTML = `
      <img src="${eventIcon(event)}" alt="" />
      <span><strong>${safeText(group.label)}</strong><small>${group.events.length} phase${group.events.length === 1 ? '' : 's'} · ${safeText(event.source.phase ?? event.kind)}</small></span>
      <time>${formatTime(group.timeMs)}</time>
    `;
    button.addEventListener('click', () => selectGroup(group));
    elements.eventList.append(button);
  }
  queueMicrotask(() => {
    const row = elements.eventList.querySelector('.selected');
    if (!row) return;
    const rowTop = row.offsetTop;
    const rowBottom = rowTop + row.offsetHeight;
    const viewportTop = elements.eventList.scrollTop;
    const viewportBottom = viewportTop + elements.eventList.clientHeight;
    if (rowTop < viewportTop) elements.eventList.scrollTop = rowTop;
    else if (rowBottom > viewportBottom) {
      elements.eventList.scrollTop = rowBottom - elements.eventList.clientHeight;
    }
  });
}

function fact(label, value) {
  const dt = document.createElement('dt');
  dt.textContent = label;
  const dd = document.createElement('dd');
  dd.textContent = safeText(value);
  elements.eventFacts.append(dt, dd);
}

function renderEventDetails() {
  const event = currentEvent();
  elements.eventFacts.replaceChildren();
  elements.spectatorCallout.hidden = true;
  if (!event) {
    elements.eventLabel.textContent = 'No ability selected';
    elements.eventTiming.textContent = state.track ? 'No decoded ability events.' : 'Load a replay to begin.';
    elements.abilityIcon.removeAttribute('src');
    updateSnapshot();
    return;
  }
  const source = event.source;
  const owner = ownerPlayer(source, state.track);
  const key = spectatorKey(owner, state.track);
  elements.eventLabel.textContent = event.label;
  elements.eventTiming.textContent = `${formatTime(event.timeMs)} · ${event.kind === 'utilityActor' ? 'spatial actor' : 'cast signal'}`;
  elements.abilityIcon.src = eventIcon(event);
  elements.abilityIcon.alt = event.label;
  fact('Event ID', event.id);
  fact('Phase', source.phase ?? source.roundPhase);
  fact('Logical action', `${currentGroup()?.events.length ?? 1} phase(s)`);
  fact('5s pre-roll', formatTime(Math.max(0, event.timeMs - 5000)));
  fact('Visible window', `${formatTime(event.timeMs)} – ${formatTime(event.endTimeMs ?? event.timeMs)}`);
  fact('Duration', event.endTimeMs == null ? null : `${Math.max(0, event.endTimeMs - event.timeMs)} ms`);
  fact('Confidence', source.confidence ?? source.identityConfidence);
  fact('Lifecycle', source.lifecycleEvidence ?? source.durationSource);
  fact('Source cast', source.sourceCastId);
  const conflicts = identityWarnings(event, state.track);
  if (conflicts.length) fact('Identity warning', conflicts.join(' '));
  if (key) {
    elements.spectatorCallout.hidden = false;
    elements.spectatorKey.textContent = key;
    elements.casterName.textContent = `${safeText(owner.displayName)} · ${safeText(owner.agent)}`;
  }
  elements.note.value = state.auditEntries.find((entry) => entry.eventId === event.id)?.note ?? '';
  state.selectedVerdict = state.auditEntries.find((entry) => entry.eventId === event.id)?.verdict ?? null;
  document.querySelectorAll('[data-verdict]').forEach((button) =>
    button.classList.toggle('selected', button.dataset.verdict === state.selectedVerdict),
  );
  updateSnapshot();
}

function markerButton({ event, position, sourcePosition, icon, kind, label }) {
  const percent = worldToPercent(position);
  const marker = document.createElement('button');
  marker.type = 'button';
  marker.className = `map-marker ability-marker ${kind}${event === currentEvent() ? ' selected' : ''}`;
  marker.style.left = `${percent.left}%`;
  marker.style.top = `${percent.top}%`;
  marker.style.width = `${Math.max(28, 34 * (MAPS[state.mapKey]?.scale ?? 1))}px`;
  marker.style.height = marker.style.width;
  marker.dataset.eventId = event.id;
  marker.dataset.kind = event.kind;
  marker.dataset.worldX = position.x.toFixed(3);
  marker.dataset.worldY = position.y.toFixed(3);
  marker.dataset.sourceX = Number(sourcePosition?.x).toFixed(3);
  marker.dataset.sourceY = Number(sourcePosition?.y).toFixed(3);
  if (identityWarnings(event, state.track).length) marker.dataset.identityConflict = 'true';
  marker.setAttribute('aria-label', `${label} at ${formatTime(event.timeMs)}`);
  marker.innerHTML = `<img src="${icon}" alt="" /><span class="marker-label">${safeText(label)}</span>`;
  marker.addEventListener('click', () => selectEvent(state.events.indexOf(event), { seek: false }));
  return marker;
}

function drawTrail(event) {
  const samples = event.source.samples ?? [];
  if (samples.length < 2 || !elements.showTrails.checked) return;
  const points = samples.map((sample) => {
    const position = replayPositionToWorld(state.track, sample.position ?? sample);
    return `${position.x.toFixed(2)},${position.y.toFixed(2)}`;
  }).join(' ');
  const line = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
  line.setAttribute('points', points);
  line.setAttribute('fill', 'none');
  line.setAttribute('stroke', event === currentEvent() ? '#a78bfa' : '#7ce7c3');
  line.setAttribute('stroke-width', event === currentEvent() ? '5' : '2.5');
  line.setAttribute('stroke-linecap', 'round');
  line.setAttribute('stroke-linejoin', 'round');
  line.setAttribute('opacity', event === currentEvent() ? '.95' : '.5');
  line.dataset.eventId = event.id;
  elements.trailLayer.append(line);
}

function renderFrame() {
  if (!state.track) return;
  elements.markerLayer.replaceChildren();
  elements.trailLayer.replaceChildren();
  const activeActorIds = new Set();

  for (const event of state.events) {
    if (event.kind !== 'utilityActor' || !isUtilityActive(event.source, state.timeMs)) continue;
    activeActorIds.add(event.id);
    const sourcePosition = utilityPositionAt(event.source, state.timeMs);
    const position = replayPositionToWorld(state.track, sourcePosition);
    const phase = String(event.source.phase ?? event.source.utilityKind ?? '').toLowerCase();
    const kind = phase.includes('projectile') ? 'projectile' : 'utility';
    elements.markerLayer.append(markerButton({
      event,
      position,
      sourcePosition,
      icon: eventIcon(event),
      kind,
      label: event.label,
    }));
    drawTrail(event);
  }

  for (const event of state.events) {
    if (event.kind !== 'abilityCast' || !isCastActive(event.source, state.timeMs)) continue;
    const linked = event.source.linkedUtilityActorIds ?? [];
    if (linked.some((id) => activeActorIds.has(id))) continue;
    for (const location of castLocations(event.source)) {
      elements.markerLayer.append(markerButton({
        event,
        position: replayPositionToWorld(state.track, location),
        sourcePosition: location,
        icon: eventIcon(event),
        kind: 'cast',
        label: event.label,
      }));
    }
  }

  if (elements.showPlayers.checked) {
    for (const player of state.track.players ?? []) {
      const sample = playerSampleAt(player, state.timeMs);
      if (!sample) continue;
      const position = worldToPercent(replayPositionToWorld(state.track, sample));
      const agent = AGENTS[String(player.agent ?? '').toLowerCase()];
      if (!agent) continue;
      const marker = document.createElement('div');
      marker.className = `map-marker player-marker ${String(player.initialSide ?? '').toLowerCase()}`;
      marker.style.left = `${position.left}%`;
      marker.style.top = `${position.top}%`;
      marker.dataset.playerId = player.id;
      marker.dataset.spectatorKey = spectatorKey(player, state.track) ?? '';
      marker.title = `${player.displayName} · ${player.agent}`;
      marker.innerHTML = `<img src="${agent.icon}" alt="${safeText(player.agent)}" />`;
      elements.markerLayer.append(marker);
    }
  }
  updateSnapshot();
}

function snapshotObject() {
  const event = currentEvent();
  const owner = event ? ownerPlayer(event.source, state.track) : null;
  const activeMarkers = [...elements.markerLayer.querySelectorAll('.ability-marker')].map((marker) => ({
    eventId: marker.dataset.eventId,
    kind: marker.dataset.kind,
    sourcePosition: { x: Number(marker.dataset.sourceX), y: Number(marker.dataset.sourceY) },
    mapPoint: { x: Number(marker.dataset.worldX), y: Number(marker.dataset.worldY) },
    mapPercent: {
      x: Number(marker.style.left.replace('%', '')),
      y: Number(marker.style.top.replace('%', '')),
    },
    identityConflict: marker.dataset.identityConflict === 'true',
  }));
  const lastEventTimeMs = state.events.at(-1)?.timeMs ?? 0;
  return {
    ready: Boolean(state.track),
    source: state.source,
    map: state.mapKey,
    coordinateSpace: state.track?.coordinateSpace ?? null,
    timeMs: state.timeMs,
    formattedTime: formatTime(state.timeMs),
    isPlaying: state.isPlaying,
    selectedEvent: event ? {
      eventIndex: state.selectedIndex,
      id: event.id,
      groupId: currentGroup()?.id ?? event.groupId,
      groupEventIds: currentGroup()?.events.map((item) => item.id) ?? [event.id],
      kind: event.kind,
      label: event.label,
      timeMs: event.timeMs,
      endTimeMs: event.endTimeMs,
      caster: owner?.displayName ?? null,
      agent: owner?.agent ?? agentForEvent(event.source, state.track)?.name ?? null,
      spectatorKey: spectatorKey(owner, state.track),
      abilityIcon: eventIcon(event),
      phase: event.source.phase ?? null,
      confidence: event.source.confidence ?? null,
      identityWarnings: identityWarnings(event, state.track),
    } : null,
    activeAbilityMarkers: activeMarkers,
    eventCount: state.events.length,
    actionCount: state.groups.length,
    coverage: {
      lastEventTimeMs,
      durationMs: state.durationMs,
      ratio: state.durationMs ? lastEventTimeMs / state.durationMs : 0,
      incomplete: state.durationMs > 0 && lastEventTimeMs < state.durationMs * .9,
    },
    mapReference: state.mapKey ? {
      width: 1777.7777777778,
      height: 1000,
      asset: MAPS[state.mapKey].asset,
      calloutsAsset: MAPS[state.mapKey].calloutsAsset,
      transform: MAPS[state.mapKey].transform,
      importCwQuarterTurns: MAPS[state.mapKey].importCwQuarterTurns,
      viewBox: MAPS[state.mapKey].viewBox,
      padding: MAPS[state.mapKey].padding,
    } : null,
    sourceDiagnostics: {
      sourceLabel: state.track?.sourceLabel ?? null,
      notes: state.track?.notes ?? null,
    },
    auditCount: state.auditEntries.length,
  };
}

function updateSnapshot() {
  const snapshot = snapshotObject();
  elements.snapshot.textContent = JSON.stringify(snapshot, null, 2);
  elements.stage.dataset.map = state.mapKey ?? '';
  elements.stage.dataset.timeMs = String(state.timeMs);
  elements.stage.dataset.selectedEventId = snapshot.selectedEvent?.id ?? '';
}

async function loadTrack(track, source = 'memory') {
  const mapKey = mapKeyFromTrack(track);
  if (!mapKey || !MAPS[mapKey]) throw new Error(`Unsupported map: ${track?.mapId ?? track?.mapName ?? 'unknown'}`);
  setPlaying(false);
  state.track = track;
  state.source = source;
  state.mapKey = mapKey;
  state.durationMs = trackDuration(track);
  state.events = normalizeAbilityEvents(track);
  state.groups = groupAbilityEvents(state.events);
  state.filteredEvents = state.events;
  state.filteredGroups = state.groups;
  state.selectedIndex = state.groups.length ? state.events.indexOf(state.groups[0].representative) : -1;
  state.auditEntries = [];
  elements.timeline.max = String(Math.max(1, state.durationMs));
  elements.duration.value = formatTime(state.durationMs);
  elements.mapName.textContent = MAPS[mapKey].name;
  elements.summary.textContent = `${(track.players ?? []).length} players · ${state.groups.length.toLocaleString()} actions / ${state.events.length.toLocaleString()} phases · ${safeText(track.coordinateSpace, 'game')} coordinates`;
  const lastEventTimeMs = state.events.at(-1)?.timeMs ?? 0;
  const incomplete = state.durationMs > 0 && lastEventTimeMs < state.durationMs * .9;
  elements.coverageWarning.hidden = !incomplete;
  elements.coverageWarning.textContent = incomplete
    ? `Warning: decoded ability coverage ends at ${formatTime(lastEventTimeMs)} (${Math.round(lastEventTimeMs / state.durationMs * 100)}% of replay).`
    : '';
  elements.empty.style.display = 'none';
  await renderMapAssets();
  setTime(state.groups[0]?.timeMs ?? 0, { render: false });
  renderEventDetails();
  renderEventList();
  renderFrame();
  showStatus(`Loaded ${source}: ${state.events.length.toLocaleString()} ability events`);
  return snapshotObject();
}

async function loadFile(file) {
  if (!file) return;
  showStatus(`Reading ${file.name}…`, 10000);
  const text = await file.text();
  return loadTrack(JSON.parse(text), file.name);
}

async function loadUrl(url) {
  const normalized = String(url ?? '').trim();
  if (!normalized) return;
  showStatus(`Loading ${normalized}…`, 10000);
  const response = await fetch(normalized);
  if (!response.ok) throw new Error(`Unable to load track: ${response.status} ${response.statusText}`);
  return loadTrack(await response.json(), normalized);
}

function saveVerdict() {
  const event = currentEvent();
  if (!event || !state.selectedVerdict) return showStatus('Choose a verdict first.');
  const entry = {
    id: `audit-${event.id}`,
    eventId: event.id,
    targetType: event.kind,
    verdict: state.selectedVerdict,
    timeMs: state.timeMs,
    parsedTimeMs: event.timeMs,
    parsedLabel: event.label,
    note: elements.note.value.trim() || null,
    evidence: snapshotObject().selectedEvent,
  };
  const existing = state.auditEntries.findIndex((candidate) => candidate.eventId === event.id);
  if (existing >= 0) state.auditEntries.splice(existing, 1, entry);
  else state.auditEntries.push(entry);
  showStatus(`Saved ${state.selectedVerdict} for ${event.label}`);
  updateSnapshot();
}

function exportAudit() {
  if (!state.track) return;
  const payload = {
    schemaVersion: 1,
    source: state.source,
    map: state.mapKey,
    coordinateSpace: state.track.coordinateSpace ?? 'game',
    generatedAt: new Date().toISOString(),
    entries: state.auditEntries,
  };
  const url = URL.createObjectURL(new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = `${state.mapKey}-ability-audit.json`;
  anchor.click();
  URL.revokeObjectURL(url);
}

elements.file.addEventListener('change', () => loadFile(elements.file.files?.[0]).catch(handleError));
elements.loadUrl.addEventListener('click', () => loadUrl(elements.url.value).catch(handleError));
elements.url.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') loadUrl(elements.url.value).catch(handleError);
});
elements.timeline.addEventListener('input', () => { setPlaying(false); setTime(elements.timeline.value); });
elements.play.addEventListener('click', () => setPlaying(!state.isPlaying));
elements.rewind.addEventListener('click', () => { setPlaying(false); setTime(state.timeMs - 5000); });
elements.forward.addEventListener('click', () => { setPlaying(false); setTime(state.timeMs + 5000); });
elements.previousEvent.addEventListener('click', () => seekEvent(-1));
elements.nextEvent.addEventListener('click', () => seekEvent(1));
elements.showCallouts.addEventListener('change', () => { elements.callouts.style.display = elements.showCallouts.checked ? '' : 'none'; });
elements.showPlayers.addEventListener('change', renderFrame);
elements.showTrails.addEventListener('change', renderFrame);
elements.eventFilter.addEventListener('input', applyEventFilter);
elements.saveVerdict.addEventListener('click', saveVerdict);
elements.exportAudit.addEventListener('click', exportAudit);
document.querySelectorAll('[data-verdict]').forEach((button) => button.addEventListener('click', () => {
  state.selectedVerdict = button.dataset.verdict;
  document.querySelectorAll('[data-verdict]').forEach((candidate) => candidate.classList.toggle('selected', candidate === button));
}));

document.addEventListener('keydown', (event) => {
  if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return;
  if (event.key === ' ') { event.preventDefault(); setPlaying(!state.isPlaying); }
  else if (event.key.toLowerCase() === 'j') { setPlaying(false); setTime(state.timeMs - 5000); }
  else if (event.key.toLowerCase() === 'l') { setPlaying(false); setTime(state.timeMs + 5000); }
  else if (event.key === '[') seekEvent(-1);
  else if (event.key === ']') seekEvent(1);
});

for (const type of ['dragenter', 'dragover']) document.addEventListener(type, (event) => {
  event.preventDefault();
  elements.dropOverlay.hidden = false;
});
document.addEventListener('dragleave', (event) => {
  if (!event.relatedTarget) elements.dropOverlay.hidden = true;
});
document.addEventListener('drop', (event) => {
  event.preventDefault();
  elements.dropOverlay.hidden = true;
  loadFile(event.dataTransfer?.files?.[0]).catch(handleError);
});

function handleError(error) {
  console.error(error);
  showStatus(error?.message ?? String(error), 8000);
}

window.replayAudit = Object.freeze({
  loadTrack,
  loadUrl,
  setTime: (timeMs) => setTime(timeMs),
  selectEvent: (idOrIndex) => selectEvent(idOrIndex),
  selectEventById: (id) => selectEvent(String(id)),
  nextEvent: () => seekEvent(1),
  previousEvent: () => seekEvent(-1),
  play: () => setPlaying(true),
  pause: () => setPlaying(false),
  getSnapshot: snapshotObject,
  getEvents: () => state.events.map(({ source, ...event }, eventIndex) => ({ ...event, eventIndex, source })),
  getActions: () => state.groups.map((group, actionIndex) => ({
    actionIndex,
    id: group.id,
    label: group.label,
    timeMs: group.timeMs,
    endTimeMs: group.endTimeMs,
    eventIds: group.events.map((event) => event.id),
    representativeEventId: group.representative.id,
  })),
  getPlayers: () => structuredClone(state.track?.players ?? []),
  getAuditEntries: () => structuredClone(state.auditEntries),
});

const params = new URLSearchParams(location.search);
if (params.get('track')) {
  elements.url.value = params.get('track');
  loadUrl(params.get('track')).catch(handleError);
}
