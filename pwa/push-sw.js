/* МеталлРасчёт — приём пуш-уведомлений (оператору: «на станок пришёл чертёж»).
   Работает, даже когда сайт закрыт: браузер будит этот файл, когда сервер присылает уведомление. */
const ROOT = new URL('../', self.registration.scope).href; // pwa/ → корень сайта

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'МеталлРасчёт', {
    body: d.body || '',
    tag: d.tag || 'mr',
    renotify: true,
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    vibrate: [200, 100, 200],
    data: { url: d.url || ROOT },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || ROOT;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) if (c.url.startsWith(ROOT) && 'focus' in c) return c.focus();
    return self.clients.openWindow(url);
  }));
});
