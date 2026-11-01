/* AgentDesk service worker (I-701): offline PWA shell + push handling.
 *
 * - Cache-first for the static zero-build shell (/, style, modules, manifest).
 * - Network-first for hub API reads (/api/* GET except the SSE stream).
 * - Never caches POST; never intercepts /api/v1/stream (EventSource must
 *   stream straight through) — those fetch through untouched.
 */
const VERSION = 'v2';
const SHELL_CACHE = `agentdesk-shell-${VERSION}`;
const API_CACHE = `agentdesk-api-${VERSION}`;
const SHELL = [
  '/',
  '/index.html',
  '/style.css',
  '/manifest.webmanifest',
  '/app.js',
  '/net.js',
  '/store.js',
  '/util.js',
  '/dom.js',
  '/actions.js',
  '/render.js',
  '/inspect.js',
  '/history.js',
  '/fleet.js',
  '/pause.js',
  '/keyboard.js',
  '/settings.js',
  '/stamp.js',
  '/qr.js',
  '/capture.js',
  '/guardrails.js',
  '/automation.js',
  '/playground.html',
  '/playground.js',
  '/playground.css',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((k) => k !== SHELL_CACHE && k !== API_CACHE)
          .map((k) => caches.delete(k)),
      ))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return; // POST/PUT/DELETE pass through
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return; // avatars etc. untouched
  if (url.pathname === '/api/v1/stream') return; // SSE must stream through

  if (url.pathname.startsWith('/api/')) {
    // Hub reads: fresh when online, cached copy when offline.
    event.respondWith(
      fetch(request)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(API_CACHE).then((cache) => cache.put(request, copy));
          }
          return res;
        })
        .catch(() => caches.match(request)),
    );
    return;
  }
  // Static shell: cache-first.
  event.respondWith(
    caches.match(request).then((hit) => hit || fetch(request).then((res) => {
      if (res && res.ok) {
        const copy = res.clone();
        caches.open(SHELL_CACHE).then((cache) => cache.put(request, copy));
      }
      return res;
    })),
  );
});

/* ---------------- Web Push (I-701, hub side delivery) ---------------- */

self.addEventListener('push', (event) => {
  let title = 'AgentDesk';
  let body = '新しい要求があります';
  let taskId = null;
  try {
    const data = event.data ? event.data.json() : null;
    if (data) {
      if (data.title) title = String(data.title);
      if (data.body) body = String(data.body);
      if (data.taskId) taskId = String(data.taskId);
    }
  } catch {
    /* text payload or none — keep defaults */
  }
  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      data: { taskId, url: '/' },
      tag: taskId || 'agentdesk',
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if ('focus' in w) {
          w.focus();
          return;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    }),
  );
});
