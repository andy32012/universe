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
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
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

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String { DiagnosticsLog.shared.write(String(text.prefix(4000))) }
    }

    /* Runs in the game page before its own code. It reports errors, files that fail to load, the graphics
       context being lost, how loading went, and every five seconds the frame rate and the slowest frame,
       with where you are and which quality setting is in use. */
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

      var frames = 0, worst = 0, last = 0, since = 0;
      function tick(now){
        if(last && !document.hidden){ frames++; worst = Math.max(worst, now - last); }
        last = document.hidden ? 0 : now;
        if(!since) since = now;
        if(now - since >= 5000){
          if(frames) post('PERF ' + (frames*1000/(now - since)).toFixed(1) + ' 幀/秒｜最慢一幀 ' + Math.round(worst) + ' 毫秒' + where(), true);
          frames = 0; worst = 0; since = now;
        }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
      /* time spent in the background is not counted */
      document.addEventListener('visibilitychange', function(){ frames = 0; worst = 0; since = 0; last = 0; });
    })();
    """
}
