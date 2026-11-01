/* AgentDesk Card Playground (I-904)
 * Interactive card editor, live preview and linter against TaskCard schema. */
import { el, clear, toast } from './dom.js';
import { renderCard } from './render.js';
import { apiUrl, authHeaders } from './net.js';

export const TEMPLATES = {
  'refund-approval': {
    type: 'createTaskCard',
    taskId: 'tmpl_refund_approval',
    nonce: 'tmpl_nonce_refund',
    protocolVersion: 1,
    agent: { name: 'Billing Agent' },
    summary: '返金申請の承認確認',
    severity: 'warning',
    confidence: 0.92,
    components: [
      {
        id: 'root_card',
        component: 'TriageCard',
        children: ['reason', 'details'],
      },
      {
        id: 'reason',
        component: 'Text',
        properties: {
          text: '顧客から返金申請が届いています。',
          variant: 'body',
        },
      },
      {
        id: 'details',
        component: 'DiffBox',
        properties: {
          title: '返金詳細',
          before: '金額: ¥5,000 (請求済み)',
          after: '金額: ¥5,000 (返金予定)',
          highlight: 'warning',
        },
      },
    ],
    actions: {
      onSwipeRight: {
        actionName: 'approve',
        label: '返金を承認',
        payload: { decision: 'APPROVE_REFUND' },
      },
      onSwipeLeft: {
        actionName: 'reject',
        label: '却下',
        payload: { decision: 'REJECT_REFUND' },
      },
      rejectReasons: [
        { id: 'policy', label: 'ポリシー違反' },
        { id: 'insufficient_evidence', label: '証拠不足' },
      ],
    },
    impact: {
      summary: '顧客に ¥5,000 を返金します',
      reversible: false,
      cost: { amount: 5000, currency: 'JPY' },
      scope: '顧客1名',
    },
  },

  'calendar-change': {
    type: 'createTaskCard',
    taskId: 'tmpl_calendar_change',
    nonce: 'tmpl_nonce_calendar',
    protocolVersion: 1,
    agent: { name: 'Calendar & Meeting Agent' },
    summary: 'ミーティングの日程変更リクエスト',
    severity: 'info',
    confidence: 0.94,
    components: [
      {
        id: 'root_card',
        component: 'TriageCard',
        children: ['diff_view', 'reasoning_text'],
      },
      {
        id: 'diff_view',
        component: 'DiffBox',
        properties: {
          title: '定例ミーティング時間',
          before: '2026-10-05 14:00',
          after: '2026-10-05 16:30',
          highlight: 'warning',
        },
      },
      {
        id: 'reasoning_text',
        component: 'Text',
        properties: {
          text: '参加者3名中2名が14:00に重複予定があるため、全員が空いている16:30への変更を提案します。',
          variant: 'caption',
        },
      },
    ],
    actions: {
      onSwipeRight: {
        actionName: 'approve',
        label: '日程変更を承認',
        payload: { decision: 'APPROVE_RESCHEDULE' },
      },
      onSwipeLeft: {
        actionName: 'reject',
        label: '現状維持',
        payload: { decision: 'KEEP_CURRENT' },
      },
    },
    impact: {
      summary: 'カレンダーの予定を16:30に変更し、参加者に通知します',
      reversible: true,
      scope: '社内3名',
    },
  },

  'pr-merge': {
    type: 'createTaskCard',
    taskId: 'tmpl_pr_merge',
    nonce: 'tmpl_nonce_pr',
    protocolVersion: 1,
    agent: { name: 'CI/CD Agent' },
    summary: 'PR #123 のマージ承認',
    severity: 'info',
    confidence: 0.98,
    components: [
      {
        id: 'root_card',
        component: 'TriageCard',
        children: ['reason', 'diff'],
      },
      {
        id: 'reason',
        component: 'Text',
        properties: {
          text: '全てのCIチェックが成功しました。マージしてデプロイしますか？',
          variant: 'body',
        },
      },
      {
        id: 'diff',
        component: 'DiffBox',
        properties: {
          title: '変更内容',
          before: 'main',
          after: 'feature/xyz (3 commits)',
          highlight: 'info',
        },
      },
    ],
    actions: {
      onSwipeRight: {
        actionName: 'approve',
        label: 'マージ',
        payload: { decision: 'MERGE_PR' },
      },
      onSwipeLeft: {
        actionName: 'reject',
        label: '保留',
        payload: { decision: 'HOLD_PR' },
      },
    },
    impact: {
      summary: 'main ブランチへマージし、本番デプロイパイプラインを開始します',
      reversible: true,
      scope: '本番環境',
    },
  },

  'send-email': {
    type: 'createTaskCard',
    taskId: 'tmpl_send_email',
    nonce: 'tmpl_nonce_email',
    protocolVersion: 1,
    agent: { name: 'Communication Agent' },
    summary: 'メール送信の承認',
    severity: 'info',
    confidence: 0.95,
    components: [
      {
        id: 'root_card',
        component: 'TriageCard',
        children: ['reason', 'details'],
      },
      {
        id: 'reason',
        component: 'Text',
        properties: {
          text: '提案されたメール文面の送信を承認してください。',
          variant: 'body',
        },
      },
      {
        id: 'details',
        component: 'DiffBox',
        properties: {
          title: '宛先・件名',
          before: 'To: customer@example.com',
          after: '件名: ご提案の件',
          highlight: 'info',
        },
      },
    ],
    actions: {
      onSwipeRight: {
        actionName: 'approve',
        label: '送信',
        payload: { decision: 'SEND_EMAIL' },
      },
      onSwipeLeft: {
        actionName: 'reject',
        label: 'キャンセル',
        payload: { decision: 'CANCEL_EMAIL' },
      },
    },
    impact: {
      summary: '外部顧客へメールを1通送信します',
      reversible: false,
      scope: '外部顧客1名',
    },
  },
};

/** Lint JSON string against TaskCard schema (returns error string or null) */
export function lintTaskCard(text) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch (err) {
    return `JSON パースエラー: ${err.message}`;
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    return 'ルートは JSON オブジェクトである必要があります';
  }
  if (!obj.agent || typeof obj.agent !== 'object' || !obj.agent.name) {
    return '`agent.name` (文字列) が必須です';
  }
  if (!obj.summary || typeof obj.summary !== 'string') {
    return '`summary` (非空文字列) が必須です';
  }
  if (obj.components !== undefined && !Array.isArray(obj.components)) {
    return '`components` は配列である必要があります';
  }
  if (Array.isArray(obj.components)) {
    for (let i = 0; i < obj.components.length; i++) {
      const c = obj.components[i];
      if (!c || typeof c !== 'object' || !c.id || !c.component) {
        return `components[${i}] に \`id\` と \`component\` (文字列) が必要です`;
      }
    }
  }
  if (obj.confidence !== undefined) {
    const c = Number(obj.confidence);
    if (Number.isNaN(c) || c < 0 || c > 1) {
      return '`confidence` は 0〜1 の数値である必要があります';
    }
  }
  if (obj.severity !== undefined) {
    if (!['info', 'warning', 'critical'].includes(obj.severity)) {
      return '`severity` は "info", "warning", "critical" のいずれかである必要があります';
    }
  }
  return null;
}

function initPlayground() {
  const editor = document.getElementById('json-editor');
  const stage = document.getElementById('pg-card-stage');
  const lintBadge = document.getElementById('lint-badge');
  const lintMsg = document.getElementById('lint-msg');
  const select = document.getElementById('template-select');
  const copyBtn = document.getElementById('copy-json-btn');
  const sendBtn = document.getElementById('send-hub-btn');

  if (!editor || !stage) return;
  if (!document.getElementById('toasts')) {
    const host = el('div', 'toasts');
    host.id = 'toasts';
    document.body.appendChild(host);
  }

  function loadTemplate(key) {
    const tmpl = TEMPLATES[key] || TEMPLATES['refund-approval'];
    editor.value = JSON.stringify(tmpl, null, 2);
    updatePreview();
  }

  function updatePreview() {
    const text = editor.value;
    const err = lintTaskCard(text);
    if (err) {
      lintBadge.className = 'lint-badge error';
      lintBadge.textContent = '⚠ 検証エラー';
      lintMsg.textContent = err;
      lintMsg.hidden = false;
      return;
    }

    lintBadge.className = 'lint-badge ok';
    lintBadge.textContent = '✓ 有効なTaskCard';
    lintMsg.hidden = true;

    try {
      const task = JSON.parse(text);
      clear(stage);
      const cardEl = renderCard(task);
      stage.appendChild(cardEl);
    } catch (e) {
      lintBadge.className = 'lint-badge error';
      lintBadge.textContent = '描画エラー';
      lintMsg.textContent = String(e);
      lintMsg.hidden = false;
    }
  }

  let debounceTimer = null;
  editor.addEventListener('input', () => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(updatePreview, 120);
  });

  select.addEventListener('change', () => {
    loadTemplate(select.value);
  });

  copyBtn.addEventListener('click', () => {
    if (navigator.clipboard) {
      navigator.clipboard.writeText(editor.value).then(() => {
        toast('カード JSON をクリップボードにコピーしました');
      });
    }
  });

  sendBtn.addEventListener('click', async () => {
    const err = lintTaskCard(editor.value);
    if (err) {
      toast(`送信不可: ${err}`);
      return;
    }
    const task = JSON.parse(editor.value);
    // Ensure fresh unique taskId and nonce if still template default
    if (task.taskId && task.taskId.startsWith('tmpl_')) {
      task.taskId = `task_pg_${Date.now()}`;
      task.nonce = `tok_pg_${Math.random().toString(36).slice(2, 10)}`;
      editor.value = JSON.stringify(task, null, 2);
    }
    try {
      sendBtn.disabled = true;
      sendBtn.textContent = '送信中...';
      const hub = localStorage.getItem('agentdesk.hub') || location.origin;
      const token = localStorage.getItem('agentdesk.agentToken') || 'dev-agent-token';
      const res = await fetch(`${hub}/api/v1/tasks`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(task),
      });
      if (res.ok) {
        toast(`ハブに送信完了 (HTTP ${res.status}): ${task.taskId}`);
      } else {
        const data = await res.json().catch(() => ({}));
        toast(`送信エラー (HTTP ${res.status}): ${data.error || '不明'}`);
      }
    } catch (e) {
      toast(`送信失敗: ${e.message}`);
    } finally {
      sendBtn.disabled = false;
      sendBtn.textContent = 'ハブに送信 (POST /tasks)';
    }
  });

  // Initial load
  loadTemplate('refund-approval');
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initPlayground);
} else {
  initPlayground();
}
