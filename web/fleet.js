/* Fleet lanes (I-603 / I-122, client-side): per-agent pending counts and a
 * tap-to-filter stack. The agent list is derived from card.agent fields —
 * no backend changes. */
import { state } from './store.js';
import { el, clear } from './dom.js';
import { render } from './render.js';

function agentKey(task) {
  return (task.agent && task.agent.name) || 'Agent';
}

function laneEl(lane, selected) {
  const node = el('button', 'fleet-lane' + (selected ? ' sel' : ''));
  node.type = 'button';
  node.setAttribute('aria-pressed', String(selected));

  const avatar = el('span', 'fleet-avatar');
  if (lane.avatarUrl) {
    const img = el('img');
    img.src = lane.avatarUrl;
    img.alt = '';
    img.referrerPolicy = 'no-referrer';
    avatar.appendChild(img);
  } else {
    avatar.textContent = String(lane.name || '?').slice(0, 1).toUpperCase();
  }
  node.appendChild(avatar);
  node.appendChild(el('span', 'fleet-name', lane.name));
  node.appendChild(el('span', 'fleet-count', lane.count));
  return node;
}

export function toggleFleet() {
  state.fleetOpen = !state.fleetOpen;
  if (!state.fleetOpen) state.fleet = null;
  state.selected = 0;
  const btn = document.getElementById('fleet-toggle');
  if (btn) {
    btn.setAttribute('aria-pressed', String(state.fleetOpen));
    btn.classList.toggle('on', state.fleetOpen);
  }
  render();
}

export function selectAgent(name) {
  state.fleet = state.fleet === name ? null : name;
  state.selected = 0;
  render();
}

export function renderFleet() {
  const panel = document.getElementById('fleet-panel');
  if (!panel) return;
  clear(panel);
  panel.hidden = !state.fleetOpen;
  if (!state.fleetOpen) return;

  const lanes = new Map(); // agent name → { name, count, avatarUrl }
  for (const t of state.stack) {
    const name = agentKey(t);
    const lane = lanes.get(name) || { name, count: 0, avatarUrl: null };
    lane.count += 1;
    if (!lane.avatarUrl && t.agent && t.agent.avatarUrl) lane.avatarUrl = t.agent.avatarUrl;
    lanes.set(name, lane);
  }
  const list = [...lanes.values()].sort(
    (a, b) => b.count - a.count || a.name.localeCompare(b.name, 'ja'),
  );

  const all = laneEl({ name: 'すべて', count: state.stack.length, avatarUrl: null }, state.fleet === null);
  all.addEventListener('click', () => {
    state.fleet = null;
    state.selected = 0;
    render();
  });
  panel.appendChild(all);

  for (const lane of list) {
    const node = laneEl(lane, state.fleet === lane.name);
    node.addEventListener('click', () => selectAgent(lane.name));
    panel.appendChild(node);
  }
  if (!list.length) panel.appendChild(el('div', 'fleet-empty', 'エージェントはいません'));
}

export function wireFleet() {
  const btn = document.getElementById('fleet-toggle');
  if (btn) btn.addEventListener('click', toggleFleet);
}
