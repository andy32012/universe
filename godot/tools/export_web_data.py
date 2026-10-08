"""Export the web version's generated data (star points, baked cloud noise) for the Godot port.

The web version draws everything from one seeded random stream, in order, so the only way to get the
very same Milky Way in Godot is to take what the page itself generated. This serves the repository with
a copy of index.html that keeps what it generates, and saves what the page posts back.

    python godot/tools/export_web_data.py        then open http://localhost:18765/export.html
    and, once loaded, run the snippet printed below in the page (or let the page post by itself).

Output goes to godot/data/.
"""
import http.server, os, sys, json, functools

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(ROOT, 'godot', 'data')
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765

HOOKS = [
    # every point cloud, with its fade range, as the page builds it
    ('function cloudArrays(pos, col, siz, a, b, c, d, parent, grow, probe){',
     'function cloudArrays(pos, col, siz, a, b, c, d, parent, grow, probe){'
     ' (window.__clouds = window.__clouds || []).push({pos:pos, col:col, siz:siz, a:a, b:b, c:c, d:d, grow:grow || 2.5, probe:!!probe,'
     ' frame:(!parent || parent === lyRoot) ? "ly" : (parent === auRoot ? "au" : "other")});'),
    # the baked cloud noise
    ("genJob('bake', VN, bakeFrom, function(data){",
     "genJob('bake', VN, bakeFrom, function(data){ window.__bake = data;"),
    # landmarks (they set the flight speed) and labels
    ('function mark(name, w, r0, cls){ var record={name:name,w:w,r0:r0,cls:cls};',
     'function mark(name, w, r0, cls){ var record={name:name,w:w,r0:r0,cls:cls}; (window.__marks = window.__marks || []).push(record);'),
    ('labels.push({el:el, w:w, rv:Math.pow(10, hi), rmin:home && lo > -8 ? Math.pow(10, lo) : 0, hidden:true});',
     'labels.push({el:el, w:w, rv:Math.pow(10, hi), rmin:home && lo > -8 ? Math.pow(10, lo) : 0, hidden:true});'
     ' (window.__labels = window.__labels || []).push({text:text, sub:sub || "", w:w, rv:Math.pow(10, hi), rmin:home && lo > -8 ? Math.pow(10, lo) : 0, home:!!home});'),
    # the nebula sites of the Milky Way, and the galaxies drawn as volumes
    ('    sites.push(site);', '    sites.push(site); (window.__sites = window.__sites || []).push(site);'),
    # reference pictures for comparing with Godot: ?view=px,py,pz,fx,fy,fz,tele,expo&snap=name.png&n=frames
    # puts you at P (light-years) facing F, holds the exposure, and saves the canvas after n frames
    ('function frame(now){',
     'function frame(now){ var __q = new URLSearchParams(location.search), __v = __q.get("view");'
     ' if(__v){ var a = __v.split(",").map(Number); P.set(a[0], a[1], a[2]); faceTo(new THREE.Vector3(a[3], a[4], a[5]));'
     ' if(a[6] > 0){ tele = teleT = a[6]; } if(a[7] > 0){ finU.uExpo.value = a[7]; surfaceMeterExposure = a[7]; }'
     ' if(window.__snapLeft === undefined) window.__snapLeft = +(__q.get("n") || 30);'
     # draw only what the Godot port draws so far: the galaxy volumes and the three point clouds of phase 1
     ' var __keep = {46860:1, 164:1, 3760:1};'
     ' [scene, volScene, topScene].forEach(function(root){ root.traverse(function(o){ var m = o.material; if(!m || Array.isArray(m)) return;'
     '  var keep = (o.isPoints && o.geometry.attributes.position && __keep[o.geometry.attributes.position.count]) || (m.uniforms && m.uniforms.uM);'
     '  if(!keep) m.visible = false; }); }); }'),
    ('    try{ drawFrame(); }',
     '    try{ drawFrame(); if(window.__snapLeft !== undefined && window.__snapLeft-- === 0){'
     ' fetch("/save/" + (new URLSearchParams(location.search).get("snap") || "web.png"), {method:"POST", body:canvas.toDataURL("image/png")})'
     '.then(function(){ document.title = "SNAP-DONE"; }); } }'),
    # For reference pictures, compile only what the view draws: this PC's Chrome GPU process overflows its
    # stack compiling some of the start-up shaders (surfaces, comets), which the galaxy pictures do not need.
    ('await bootYield();renderer.compile(stages[i],camera);',
     'await bootYield();if(!/view=/.test(location.search))renderer.compile(stages[i],camera);'),
    ('await bootYield();postQuad.material=postMaterials[i];renderer.compile(postScene,postCam);',
     'await bootYield();postQuad.material=postMaterials[i];if(!/view=/.test(location.search) || i < 4)renderer.compile(postScene,postCam);'),
    ('if(warmSmallBodies){', 'if(warmSmallBodies && !/view=/.test(location.search)){'),
    ('if(warmComets){', 'if(warmComets && !/view=/.test(location.search)){'),
    ('if(warmObservedClusters){', 'if(warmObservedClusters && !/view=/.test(location.search)){'),
    ('mesh.userData.volumeBounds = {record:rec, nebula:false}; gals.push(rec);',
     'mesh.userData.volumeBounds = {record:rec, nebula:false}; gals.push(rec);'
     ' (window.__gals = window.__gals || []).push({w:rec.w, R:rec.R, M:Array.from(M.elements), o:o});'),
]

POST_JS = r"""
<script>
window.__exportWeb = async function(){
  function wait(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
  for(var i=0;i<600 && !window.__bake;i++) await wait(100);
  if(!window.__bake) throw new Error('no bake');
  async function put(name, buf){ var r = await fetch('/save/' + name, {method:'POST', body:buf}); if(!r.ok) throw new Error(name); }
  await put('noise_rg8_96.bin', window.__bake);
  var meta = [];
  for(var k=0;k<window.__clouds.length;k++){
    var c = window.__clouds[k], n = c.siz.length;
    var buf = new ArrayBuffer(4 + n*7*4), dv = new DataView(buf), f = new Float32Array(buf, 4);
    dv.setUint32(0, n, true);
    f.set(c.pos, 0); f.set(c.col, n*3); f.set(c.siz, n*6);
    var name = 'cloud_' + k + '.bin';
    await put(name, buf);
    meta.push({file:name, n:n, a:c.a, b:c.b, c:c.c, d:c.d, grow:c.grow, probe:c.probe, frame:c.frame});
  }
  await put('clouds.json', JSON.stringify(meta, null, 1));
  function v(w){ return [w.x, w.y, w.z]; }
  var scene = {
    marks: window.__marks.map(function(m){ return {name:m.name, w:v(m.w), r0:m.r0, cls:m.cls}; }),
    labels: window.__labels.map(function(l){ return {text:l.text, sub:l.sub, w:v(l.w), rv:l.rv, rmin:l.rmin, home:l.home}; }),
    sites: window.__sites.map(function(s){ return {name:s.name, type:s.type, R:s.R, a:s.a, b:s.b, extra:s.extra, col:s.col, w:v(s.w), seed:s.seed}; }),
    galaxies: window.__gals.map(function(g){ return {w:v(g.w), R:g.R, M:g.M, o:g.o}; })
  };
  await put('scene.json', JSON.stringify(scene));
  return meta.length + ' clouds';
};
</script>
"""


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def do_GET(self):
        if self.path.split('?')[0] == '/export.html':
            html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
            for old, new in HOOKS:
                if html.count(old) != 1:
                    self.send_error(500, 'hook not found: ' + old[:60]); return
                html = html.replace(old, new)
            html = html.replace('</body>', POST_JS + '</body>', 1)
            # the page waits for screen refreshes before it builds; a background tab gets none, so use a timer
            html = html.replace('<script>', '<script>Object.defineProperty(document, "hidden", {get:function(){ return false; }});'
                                ' window.requestAnimationFrame = function(cb){'
                                ' return setTimeout(function(){ cb(performance.now()); }, 16); };</script><script>', 1)
            data = html.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        return super().do_GET()

    def do_POST(self):
        if not self.path.startswith('/save/'):
            self.send_error(404); return
        name = os.path.basename(self.path[6:])
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n)
        out = OUT
        if body.startswith(b'data:image/png;base64,'):
            # reference pictures go to the scratch folder given by SNAP_DIR, not into the game's data
            import base64
            body = base64.b64decode(body[len(b'data:image/png;base64,'):])
            out = os.environ.get('SNAP_DIR', OUT)
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, name), 'wb') as f:
            f.write(body)
        print('saved', name, n, flush=True)
        self.send_response(200); self.end_headers()


if __name__ == '__main__':
    print('serving', ROOT, 'on', PORT, flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
