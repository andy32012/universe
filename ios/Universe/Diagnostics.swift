import UIKit
import WebKit

/* A plain-text log of errors and performance in the app's Documents folder, sent with the settings panel's
   分享記錄檔 button. It records no diary text or other content of the game. */
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("universe-log.txt")
    private let queue = DispatchQueue(label: "universe.log")
    private let limit = 512 * 1024
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private var observers: [NSObjectProtocol] = []

    /* waits for the writes already queued, before the file is handed to the share sheet */
    func flush() { queue.sync {} }

    var sizeText: String {
        flush()
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        return bytes < 1024 ? "\(bytes) bytes" : "\(bytes / 1024) KB"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
    }

    func write(_ text: String) {
        let line = "\(stamp.string(from: Date())) \(text)\n"
        queue.async { [url, limit] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
            /* keep the newest half once the file passes the limit */
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > limit,
               let whole = try? Data(contentsOf: url) {
                let tail = whole.suffix(limit / 2)
                let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
                try? tail[start...].write(to: url)
            }
        }
    }

    /* what the device is and what iPadOS reports about heat, power and memory */
    func start() {
        let version = Self.version
        let process = ProcessInfo.processInfo
        let screen = UIScreen.main
        write("===== 開啟 App \(version)｜\(Self.model())｜\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" +
              "｜記憶體 \(process.physicalMemory / 1_073_741_824) GB｜螢幕 \(Int(screen.nativeBounds.width))×\(Int(screen.nativeBounds.height))" +
              " 最高 \(screen.maximumFramesPerSecond) Hz｜溫度狀態 \(Self.thermal(process.thermalState))" +
              "｜低耗電模式 \(process.isLowPowerModeEnabled ? "開" : "關")")
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.write("THERMAL 溫度狀態變成 \(Self.thermal(ProcessInfo.processInfo.thermalState))")
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
                self?.write("POWER 低耗電模式 \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "開" : "關")")
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
                self?.write("MEMORY 系統發出記憶體不足警告")
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.write("APP 切到背景")
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.write("APP 回到前景")
            },
        ]
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "微溫"
        case .serious: return "偏熱（系統開始降速）"
        case .critical: return "過熱（大幅降速）"
        @unknown default: return "未知"
        }
    }

    private static func model() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/* Receives the page's reports (see pageScript) and writes them to the log. */
final class DiagnosticsHandler: NSObject, WKScriptMessageHandler {
    static let name = "log"

    private let cpu = CPUMeter()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        if text.hasPrefix("PERF "), let line = perfLine(String(text.dropFirst(5))) {
            DiagnosticsLog.shared.write(line)
        } else {
            DiagnosticsLog.shared.write(String(text.prefix(12000)))
        }
    }

    /* One line per five seconds: frame rate, the whole system's CPU use over the same five seconds, and the game
       code's time per frame. That time includes waiting: when the GPU falls behind, WebKit holds the page's
       drawing calls until it catches up, so a long time with idle cores means waiting on the GPU. The GPU 分段
       reports say which passes and objects that time goes to. */
    private func perfLine(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fps = p["fps"] as? Double, let worst = p["worst"] as? Double,
              let js = p["js"] as? Double, let jsMax = p["jsMax"] as? Double else { return nil }
        let load = cpu.sample()
        let cpuText = load.map { String(format: "CPU 全部 %.0f%%・最忙的核心 %.0f%%", $0.total, $0.busiest) } ?? "CPU 量測中"
        return String(format: "PERF %.1f 幀/秒｜最慢一幀 %.0f 毫秒｜", fps, worst) + cpuText +
            String(format: "｜遊戲程式每幀 %.1f 毫秒（最多 %.0f）", js, jsMax) + ((p["where"] as? String) ?? "")
    }

    /* Runs in the game page before its own code. It reports errors, files that fail to load, the graphics
       context being lost, how loading went, and every five seconds the frame rate, the slowest frame and the
       game code's time per frame, with where you are and which quality setting is in use. */
    static let pageScript = """
    (function(){
      var sent = {}, count = 0;
      function post(text, always){
        if(always){ try{ window.webkit.messageHandlers.log.postMessage(String(text)); }catch(e){} return; }
        if(count > 400) return;
        var key = text.slice(0, 200); sent[key] = (sent[key] || 0) + 1;
        if(sent[key] > 3){ if(sent[key] === 4) text = '（以下相同訊息不再記錄）' + text; else return; }
        count++;
        try{ window.webkit.messageHandlers.log.postMessage(String(text)); }catch(e){}
      }
      function where(){
        var place = document.getElementById('place'), nep = document.getElementById('nepInfo'), q = null;
        try{ q = localStorage.getItem('universe-quality'); }catch(e){}
        var cv = document.querySelector('canvas:not(#hdr)'), hdrCv = document.getElementById('hdr');
        return '｜位置 ' + (place ? place.textContent.trim() : '?') +
          (cv ? '｜繪圖 ' + cv.width + '×' + cv.height : '') + (hdrCv && hdrCv.style.display === 'block' ? '｜HDR 開' : '') +
          (nep && !nep.hidden && nep.firstChild ? '｜' + String(nep.firstChild.nodeValue).trim() : '') +
          '｜畫質 ' + (q || 'high（預設）');
      }
      window.addEventListener('error', function(e){
        var t = e.target;
        if(t && t !== window && (t.src || t.href)){ post('LOAD 讀取失敗 ' + (t.src || t.href)); return; }
        var file = (e.filename || '').split('/').pop();
        post('ERROR ' + (e.message || '') + ' @ ' + file + ':' + e.lineno + ':' + e.colno + (e.error && e.error.stack ? '\\n' + e.error.stack : ''));
      }, true);
      window.addEventListener('unhandledrejection', function(e){
        var r = e.reason; post('ERROR 未處理的 Promise：' + (r && (r.stack || r.message) || r));
      });
      ['error', 'warn'].forEach(function(kind){
        var original = console[kind];
        console[kind] = function(){
          try{ post('CONSOLE.' + kind.toUpperCase() + ' ' + Array.prototype.map.call(arguments, function(a){
            return a && a.stack ? a.stack : (typeof a === 'object' ? JSON.stringify(a) : String(a)); }).join(' ')); }catch(e){}
          return original.apply(console, arguments);
        };
      });
      /* ---- GPU timing ----
         iPadOS gives web pages no GPU timer, so every fifteen seconds one frame is drawn with the GPU made to finish
         before and after each pass (renderer.render) and each object (renderBufferDirect), which shows how long each
         takes. three.js is caught as it defines itself, so the renderer the game makes is timed without changing it. */
      var profiling = null, profileDue = performance.now() + 15000, ids = new WeakMap(), nextId = {S:0, M:0, T:0}, legend = {};
      function idOf(o, kind){ if(!o) return '?'; var v = ids.get(o); if(!v){ v = kind + (++nextId[kind]); ids.set(o, v); } return v; }
      function add(map, key, ms){ var e = map[key] || (map[key] = {ms:0, n:0}); e.ms += ms; e.n++; }
      function hook(r){
        var gl = r.getContext(), render = r.render, draw = r.renderBufferDirect, px = new Uint8Array(4), syncFb = null;
        /* wait until the GPU has done everything asked of it so far: finish(), and since some browsers return from
           finish() at once, also a one-pixel read from a framebuffer of our own (bindings are put back as they were,
           so three.js's own record of them stays true) */
        function sync(){
          gl.finish();
          if(typeof WebGL2RenderingContext === 'undefined' || !(gl instanceof WebGL2RenderingContext)) return;
          if(!syncFb){
            var unit = gl.getParameter(gl.TEXTURE_BINDING_2D), tex = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, tex);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
            gl.bindTexture(gl.TEXTURE_2D, unit);
            var read = gl.getParameter(gl.READ_FRAMEBUFFER_BINDING);
            syncFb = gl.createFramebuffer();
            gl.bindFramebuffer(gl.READ_FRAMEBUFFER, syncFb);
            gl.framebufferTexture2D(gl.READ_FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
            gl.bindFramebuffer(gl.READ_FRAMEBUFFER, read);
          }
          var before = gl.getParameter(gl.READ_FRAMEBUFFER_BINDING);
          gl.bindFramebuffer(gl.READ_FRAMEBUFFER, syncFb);
          gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
          gl.bindFramebuffer(gl.READ_FRAMEBUFFER, before);
        }
        r.render = function(scene){
          if(!profiling) return render.apply(r, arguments);
          var t = r.getRenderTarget();
          var label = idOf(scene, 'S') + '（' + (scene && scene.children ? scene.children.length : 0) + ' 個物件' +
            (scene && scene.overrideMaterial ? '，覆蓋材質' : '') + '）→ ' + (t ? idOf(t, 'T') + ' ' + t.width + '×' + t.height : '螢幕');
          sync(); var s = performance.now();
          try{ return render.apply(r, arguments); }
          finally{ sync(); add(profiling.passes, label, performance.now() - s); }
        };
        r.renderBufferDirect = function(camera, scene, geometry, material, object){
          if(!profiling) return draw.apply(r, arguments);
          var id = (object && object.name) || idOf(material, 'M');
          if(!legend[id]) legend[id] = (material ? material.type : '?') + '：' + (material && material.uniforms ? Object.keys(material.uniforms).join(',') : '');
          sync(); var s = performance.now();
          try{ return draw.apply(r, arguments); }
          finally{ sync(); add(profiling.objects, id, performance.now() - s); }
        };
      }
      try{
        var three;
        Object.defineProperty(window, 'THREE', {configurable:true, enumerable:true, get:function(){ return three; }, set:function(ns){
          three = ns;
          var Original;
          function Renderer(params){
            var r = new Original(params);
            try{ hook(r); }catch(e){ post('ERROR GPU 計時掛不上去：' + e); }
            return r;
          }
          Object.defineProperty(ns, 'WebGLRenderer', {configurable:true, enumerable:true,
            get:function(){ return Original ? Renderer : undefined; },
            set:function(c){ Original = c; Renderer.prototype = c.prototype; }});
        }});
      }catch(e){ post('ERROR GPU 計時無法準備：' + e); }
      function ranked(map, n){
        return Object.keys(map).map(function(k){ return [k, map[k].ms, map[k].n]; }).sort(function(a, b){ return b[1] - a[1]; }).slice(0, n);
      }
      function report(p, frameMs){
        var passes = ranked(p.passes, 12), objects = ranked(p.objects, 12);
        if(!passes.length){ profileDue = performance.now() + 1000; return; }
        var sum = 0; Object.keys(p.passes).forEach(function(k){ sum += p.passes[k].ms; });
        function line(x){ return '  ' + x[1].toFixed(1) + ' 毫秒  ' + x[0] + (x[2] > 1 ? '（' + x[2] + ' 次）' : ''); }
        post('GPU 分段｜這一幀 ' + Math.round(frameMs) + ' 毫秒，各步驟加起來 ' + Math.round(sum) + ' 毫秒' + where() +
          '\n 步驟（最久的在前）：\n' + passes.map(line).join('\n') +
          '\n 最花時間的繪製：\n' + objects.map(function(x){ return line(x) + '  ' + legend[x[0]]; }).join('\n'), true);
      }

      window.addEventListener('webglcontextlost', function(){ post('GPU 繪圖環境中斷（webglcontextlost）' + where()); }, true);
      window.addEventListener('webglcontextrestored', function(){ post('GPU 繪圖環境恢復' + where()); }, true);

      var t0 = performance.now(), stage = '';
      post('PAGE 開始載入｜視窗 ' + innerWidth + '×' + innerHeight + ' ×' + devicePixelRatio);
      var boot = setInterval(function(){
        var loading = document.getElementById('loading'), fail = document.getElementById('fail');
        var s = document.getElementById('loadingStage'), c = document.getElementById('loadingCount');
        var now = ((performance.now() - t0)/1000).toFixed(1) + ' 秒';
        var text = (s ? s.textContent : '') + ' ' + (c ? c.textContent : '');
        if(text !== stage){ stage = text; post('BOOT ' + now + '｜' + text.trim()); }
        if(fail && !fail.hidden){ post('BOOT 載入失敗 ' + now + '｜' + fail.textContent.trim()); clearInterval(boot); }
        else if(loading && loading.hidden){ post('BOOT 載入完成 ' + now); clearInterval(boot); }
      }, 250);

      /* how long the game's own code takes each frame: every requestAnimationFrame callback is timed */
      var raf = window.requestAnimationFrame.bind(window), busy = 0, busyMax = 0, calls = 0;
      window.requestAnimationFrame = function(cb){
        return raf(function(t){
          var s = performance.now(), timed = false, loading = document.getElementById('loading');
          if(!profiling && s >= profileDue && !document.hidden && loading && loading.hidden){
            profiling = {passes:{}, objects:{}}; timed = true; profileDue = s + 15000;
          }
          try{ return cb(t); }
          finally{
            var d = performance.now() - s;
            if(timed){ var p = profiling; profiling = null; report(p, d); }
            else { busy += d; calls++; if(d > busyMax) busyMax = d; }
          }
        });
      };
      var frames = 0, worst = 0, last = 0, since = 0;
      function reset(){ frames = 0; worst = 0; busy = 0; busyMax = 0; calls = 0; }
      function tick(now){
        if(last && !document.hidden){ frames++; worst = Math.max(worst, now - last); }
        last = document.hidden ? 0 : now;
        if(!since) since = now;
        if(now - since >= 5000){
          if(frames) post('PERF ' + JSON.stringify({fps:frames*1000/(now - since), worst:worst, js:busy/frames, jsMax:busyMax, where:where()}), true);
          reset(); since = now;
        }
        raf(tick);
      }
      raf(tick);
      /* a button at the end of the settings panel that hands the log file to the share sheet, with the
         app's version beside it (window.universeApp is set by the app before this script) */
      document.addEventListener('DOMContentLoaded', function(){
        var after = document.querySelector('.settings-refresh');
        if(!after || !window.webkit || !window.webkit.messageHandlers.shareLog) return;
        var style = document.createElement('style');
        style.textContent = '#shareLog{display:flex;justify-content:space-between;align-items:center;gap:12px;width:100%;min-height:48px;padding:0 12px;' +
          'border:1px solid var(--line);border-radius:9px;color:var(--ink-dim);font-size:12px;text-align:left}';
        document.head.appendChild(style);
        var box = document.createElement('div'), button = document.createElement('button'), note = document.createElement('p');
        box.className = 'settings-refresh'; note.className = 'explorer-muted';
        button.type = 'button'; button.id = 'shareLog'; button.innerHTML = '分享記錄檔 <span aria-hidden="true">↗</span>';
        button.addEventListener('click', function(){ window.webkit.messageHandlers.shareLog.postMessage(''); });
        var app = window.universeApp || {};
        note.textContent = 'App 版本 ' + (app.version || '?') + '｜錯誤與效能的記錄（開啟時 ' + (app.logSize || '?') + '），可以傳給開發者。';
        box.appendChild(button); box.appendChild(note);
        after.parentNode.insertBefore(box, after.nextSibling);
      });
      /* time spent in the background is not counted */
      document.addEventListener('visibilitychange', function(){ reset(); since = 0; last = 0; });
    })();
    """
}

/* The whole system's CPU use since the previous sample, from the kernel's per-core tick counts. The game's
   page runs in WebKit's own processes, so the app's own CPU time would miss it. */
final class CPUMeter {
    private var previous: [UInt32] = []

    func sample() -> (total: Double, busiest: Double)? {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(cores) * states).map { UInt32(bitPattern: info[$0]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        defer { previous = ticks }
        guard previous.count == ticks.count else { return nil }
        var busy = 0.0, total = 0.0, busiest = 0.0
        for core in 0..<Int(cores) {
            let d = (0..<states).map { Double(ticks[core * states + $0] &- previous[core * states + $0]) }
            let all = d.reduce(0, +), idle = d[Int(CPU_STATE_IDLE)]
            guard all > 0 else { continue }
            busy += all - idle; total += all
            busiest = max(busiest, (all - idle) / all)
        }
        return total > 0 ? (busy / total * 100, busiest * 100) : nil
    }
}

/* The settings panel's 分享記錄檔 button: opens the share sheet with the log file, so it can be sent
   (to the Claude app, AirDrop, Mail) or saved to Files without finding the app's folder there. */
final class ShareLogHandler: NSObject, WKScriptMessageHandler {
    static let name = "shareLog"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        DiagnosticsLog.shared.write("SHARE 分享記錄檔")
        DiagnosticsLog.shared.flush()
        let sheet = UIActivityViewController(activityItems: [DiagnosticsLog.shared.url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = webView
        sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
        var top = webView.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(sheet, animated: true)
    }
}
