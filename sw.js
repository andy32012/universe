/* Keeps a copy of the site so it opens without a connection once installed.
   The page is shown from the copy at once and refreshed in the background, so an update appears on the next visit.
   Bump VERSION when the list of files below changes. */
var VERSION = 'universe-v1';
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

/* answer from the cache, and fetch a fresh copy into it in the background */
function fromCacheThenRefresh(e, cacheName, key){
  return caches.open(cacheName).then(function(c){
    return c.match(key, {ignoreSearch:true}).then(function(hit){
      var fresh = fetch(e.request).then(function(res){
        if(res && res.ok) c.put(key, res.clone());
        return res;
      });
      if(hit){ e.waitUntil(fresh.catch(function(){})); return hit; }
      return fresh;
    });
  });
}

self.addEventListener('fetch', function(e){
  var req = e.request;
  if(req.method !== 'GET') return;
  var url = new URL(req.url);
  if(req.mode === 'navigate' && url.origin === location.origin){
    e.respondWith(fromCacheThenRefresh(e, VERSION, './'));
  } else if(url.origin === location.origin){
    e.respondWith(fromCacheThenRefresh(e, VERSION, req));
  } else if(url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com'){
    e.respondWith(fromCacheThenRefresh(e, FONTS, req));
  }
});
