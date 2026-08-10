// Q-Tracker Hafazan NFC — Service Worker
// Naikkan nombor versi ini setiap kali index.html dikemaskini supaya
// pengguna dapat versi terbaru dan bukan versi cache lama.
const CACHE_VERSION = 'qtracker-v2';
const CACHE_FILES = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-512 maskable.png'
];

// ── INSTALL: simpan fail asas ke cache ──
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(CACHE_FILES))
  );
  self.skipWaiting();
});

// ── ACTIVATE: buang cache versi lama ──
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key !== CACHE_VERSION)
          .map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

// ── FETCH: strategi berbeza ikut jenis permintaan ──
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Jangan campur tangan permintaan ke Supabase — sentiasa perlu data terkini/live.
  if (url.hostname.includes('supabase.co')) {
    return;
  }

  // Untuk fail app sendiri (HTML/JSON/ikon): cache-first, fallback ke rangkaian.
  if (url.origin === self.location.origin) {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          const clone = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(event.request, clone));
          return response;
        }).catch(() => cached);
      })
    );
    return;
  }

  // Untuk permintaan luar lain (contoh: CDN supabase-js): network-first, fallback cache.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const clone = response.clone();
        caches.open(CACHE_VERSION).then((cache) => cache.put(event.request, clone));
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
