/* Settings panel: hub URL + client token, persisted and reconnected. */
import { state, LS_HUB, LS_TOKEN } from './store.js';

export function wireSettings({ onSave } = {}) {
  const toggle = document.getElementById('settings-toggle');
  const panel = document.getElementById('settings');
  const hubInput = document.getElementById('hub-input');
  const tokenInput = document.getElementById('token-input');
  const save = document.getElementById('save-settings');
  if (!toggle || !panel || !hubInput || !tokenInput || !save) return;

  hubInput.value = state.hub;
  tokenInput.value = state.token;
  panel.hidden = !!state.token; // open until a token exists

  toggle.addEventListener('click', () => {
    panel.hidden = !panel.hidden;
  });
  save.addEventListener('click', () => {
    state.hub = hubInput.value.trim() || location.origin;
    state.token = tokenInput.value.trim();
    localStorage.setItem(LS_HUB, state.hub);
    localStorage.setItem(LS_TOKEN, state.token);
    panel.hidden = true;
    if (onSave) onSave();
  });
}
