import UIKit
import WebKit

/* A plain-text log of errors and performance, kept at 檔案 → 我的 iPad → 宇宙 → universe-log.txt,
   so it can be attached to a message. It records no diary text or other content of the game. */
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
            DiagnosticsLog.shared.write(String(text.prefix(4000)))
        }
    }

    /* One line per five seconds: frame rate, the whole system's CPU use over the same five seconds, the game
       code's time per frame, and a guess at the bottleneck. iPadOS gives apps no GPU use figure, so a slow
       frame with an idle CPU and quick game code is put down to the GPU. */
    private func perfLine(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fps = p["fps"] as? Double, let worst = p["worst"] as? Double,
              let js = p["js"] as? Double, let jsMax = p["jsMax"] as? Double else { return nil }
        let load = cpu.sample()
        let cpuText = load.map { String(format: "CPU 全部 %.0f%%・最忙的核心 %.0f%%", $0.total, $0.busiest) } ?? "CPU 量測中"
        let frameMs = 1000 / max(fps, 0.1)
        let bottleneck: String
        if fps >= 55 { bottleneck = "無（順暢）" }
        else if js >= frameMs * 0.7 || (load?.busiest ?? 0) >= 90 { bottleneck = "CPU（推測）" }
        else { bottleneck = "GPU（推測）" }
        return String(format: "PERF %.1f 幀/秒｜最慢一幀 %.0f 毫秒｜", fps, worst) + cpuText +
            String(format: "｜遊戲程式每幀 %.1f 毫秒（最多 %.0f）｜瓶頸 ", js, jsMax) + bottleneck + ((p["where"] as? String) ?? "")
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
        return '｜位置 ' + (place ? place.textContent.trim() : '?') +
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
          var s = performance.now();
          try{ return cb(t); }finally{ var d = performance.now() - s; busy += d; calls++; if(d > busyMax) busyMax = d; }
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
