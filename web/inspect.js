/* Inspect sheet (§3.3): full card + dynamic A2UI form (docs/protocol.md). */
import { el, clear } from './dom.js';
import { state } from './store.js';
import { renderComponent, orderedComponents } from './render.js';
import { triage } from './actions.js';

export function openInspect(task) {
  state.inspectTask = task;
  renderInspect();
  const backdrop = document.getElementById('sheet-backdrop');
  if (backdrop) backdrop.hidden = false;
}

export function closeInspect() {
  state.inspectTask = null;
  const sheet = document.getElementById('inspect-sheet');
  if (sheet) {
    sheet.hidden = true;
    clear(sheet);
  }
  const backdrop = document.getElementById('sheet-backdrop');
  if (backdrop) backdrop.hidden = true;
}

export function renderInspect() {
  const task = state.inspectTask;
  const sheet = document.getElementById('inspect-sheet');
  if (!sheet) return;
  clear(sheet);
  if (!task) {
    sheet.hidden = true;
    return;
  }

  sheet.appendChild(el('div', 'sheet-title', task.summary || 'Inspect'));

  for (const comp of orderedComponents(task)) {
    sheet.appendChild(renderComponent(comp, task));
  }

  // Dynamic form catalog (docs/protocol.md §inspectForm).
  const form = (task.actions && Array.isArray(task.actions.inspectForm)) ? task.actions.inspectForm : [];
  const inputs = new Map(); // componentId → () => value

  for (const comp of form) {
    const p = (comp && comp.properties) || {};
    const field = el('div', 'form-field');
    if (p.label) field.appendChild(el('label', '', p.label));

    switch (comp.component) {
      case 'TimePicker': {
        const input = el('input');
        input.type = 'time';
        input.value = typeof p.default === 'string' ? p.default : '';
        field.appendChild(input);
        inputs.set(comp.id, () => input.value);
        break;
      }
      case 'DatePicker': {
        const input = el('input');
        input.type = 'date';
        input.value = typeof p.default === 'string' ? p.default : '';
        field.appendChild(input);
        inputs.set(comp.id, () => input.value);
        break;
      }
      case 'Slider': {
        const row = el('div', 'range-row');
        const input = el('input');
        input.type = 'range';
        input.min = p.min ?? 0;
        input.max = p.max ?? 100;
        if (p.divisions > 1) {
          const raw = (Number(input.max) - Number(input.min)) / (p.divisions - 1);
          input.step = Math.round(raw * 1e6) / 1e6; // avoid float noise in the UI
        }
        input.value = p.default ?? input.min;
        const fmt = (v) => String(parseFloat(Number(v).toPrecision(10)));
        const val = el('span', 'range-value', fmt(input.value));
        input.addEventListener('input', () => { val.textContent = fmt(input.value); });
        row.append(input, val);
        field.appendChild(row);
        inputs.set(comp.id, () => Number(input.value));
        break;
      }
      case 'Segmented': {
        const options = Array.isArray(p.options) ? p.options : [];
        const seg = el('div', 'segmented');
        let selected = null;
        for (const opt of options) {
          const label = typeof opt === 'string' ? opt : (opt && (opt.label || opt.value)) || '?';
          const b = el('button', 'seg', label);
          b.type = 'button';
          b.addEventListener('click', () => {
            seg.querySelectorAll('.seg').forEach((s) => s.classList.remove('selected'));
            b.classList.add('selected');
            selected = typeof opt === 'string' ? opt : (opt && opt.value !== undefined ? opt.value : label);
          });
          seg.appendChild(b);
        }
        field.appendChild(seg);
        inputs.set(comp.id, () => selected);
        break;
      }
      case 'TextField': {
        const input = p.multiline ? el('textarea') : el('input');
        if (!p.multiline) input.type = 'text';
        input.value = typeof p.default === 'string' ? p.default : '';
        field.appendChild(input);
        inputs.set(comp.id, () => input.value);
        break;
      }
      default: {
        // FR-1.3 fallback inside the form too.
        const f = el('div', 'fallback');
        f.appendChild(el('div', 'fallback-label', `${comp.component || 'unknown'} — 未対応コンポーネント`));
        field.appendChild(f);
        break;
      }
    }
    sheet.appendChild(field);
  }

  const row = el('div', 'sheet-actions');
  const submit = el('button', 'btn primary', '修正して承認');
  submit.type = 'button';
  submit.addEventListener('click', () => {
    const values = {};
    for (const [id, getter] of inputs) {
      const v = getter();
      if (v !== undefined && v !== null && v !== '') values[id] = v;
    }
    const right = task.actions && task.actions.onSwipeRight;
    const merged = Object.assign({}, (right && right.payload) || {}, values);
    closeInspect();
    triage(task, { actionName: 'approve', data: merged, source: 'inspect_form' });
  });
  const cancel = el('button', 'btn dim', 'キャンセル');
  cancel.type = 'button';
  cancel.addEventListener('click', closeInspect);
  row.append(cancel, submit);
  sheet.appendChild(row);

  sheet.hidden = false;
}
