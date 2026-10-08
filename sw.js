/* Keeps a copy of the site so it opens without a connection once installed.
   Online, every file is fetched fresh first, so an update shows at once on the next reload; the copy is kept up to date as files arrive
   and is used only when the network cannot be reached. Fonts, which never change, are served from the copy first.
   Bump VERSION when the list of files below changes. */
var VERSION = 'universe-v2';
var FONTS = 'universe-fonts';
var FILES = ['./', 'manifest.json', 'icon-180.png', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', function(e){
  e.waitUntil(caches.open(VERSION).then(function(c){ return c.addAll(FILES); }).then(function(){ return self.skipWaiting(); }));
});

self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(keys){
    return Promise.all(keys.filter(function(k){ return k !== VERSION && k !== FONTS; }).map(function(k){ return caches.delete(k); }));
  }).then(function(){ return self.clients.claim(); }));
});

/* the network first, keeping a copy; the copy if the network cannot be reached */
function freshThenCache(e, key){
  return caches.open(VERSION).then(function(c){
    return fetch(e.request).then(function(res){
      if(res && res.ok && res.type === 'basic') c.put(key, res.clone());
      return res;
    }).catch(function(){
      return c.match(key, {ignoreSearch:true}).then(function(hit){ return hit || Response.error(); });
    });
  });
}
/* fonts: the copy first, fetched once */
function cacheThenFetch(e){
  return caches.open(FONTS).then(function(c){
    return c.match(e.request).then(function(hit){
      return hit || fetch(e.request).then(function(res){ if(res && (res.ok || res.type === 'opaque')) c.put(e.request, res.clone()); return res; });
    });
  });
}

self.addEventListener('fetch', function(e){
  var req = e.request;
  if(req.method !== 'GET') return;
  var url = new URL(req.url);
  if(req.mode === 'navigate' && url.origin === location.origin) e.respondWith(freshThenCache(e, './'));
  else if(url.origin === location.origin) e.respondWith(freshThenCache(e, req));
  else if(url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') e.respondWith(cacheThenFetch(e));
});
