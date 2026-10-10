## The log, as Diagnostics.swift keeps it for the web app: the device and what it supports, load steps,
## and every 5 seconds the frame rate, frame times, GPU time per pass, memory and where you are.
## Written to user://universe-log.txt (the previous run's is kept as universe-log-previous.txt); the settings
## panel copies it to the clipboard. Nothing you write in the game ever goes into it.
extends Node

var main: Node
var lines: PackedStringArray = []
var file: FileAccess
var t0 := 0
var window_start := 0
var frames := 0
var frame_max := 0.0
var gpu_sum := {}
var gpu_n := 0
var rt_gpu := {true: [0.0, 0], false: [0.0, 0]}   # GPU ms per frame with ray tracing on / off: sum, count
var vps := {}
var script_sum := 0.0
var render_cpu_sum := 0.0      # CPU time preparing the frame's drawing (setup plus every viewport), ms

const PATH := "user://universe-log.txt"
const PREVIOUS := "user://universe-log-previous.txt"
# written by the native part of ios/plugins/sharelog (thermal state, low power, memory, CPU per core, events)
const NATIVE_STATUS := "user://native-status.json"
const NATIVE_EVENTS := "user://native-events.log"
const BACKGROUND := "App 切到背景"
const QUIT := "App 結束"

var catcher: ErrorCatcher
var error_counts := {}           # message -> times seen since the last report (after the first, which is logged)
var native_events_seen := 0


## Godot's own errors and warnings (engine, script, shader), wherever they happen. Called from any thread,
## so they are queued under a lock and written from the main thread.
class ErrorCatcher extends Logger:
	var mutex := Mutex.new()
	var queue: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var kinds := ["錯誤", "警告", "腳本錯誤", "著色器錯誤"]
		var what := rationale if rationale != "" else code
		var msg := "Godot %s：%s（%s:%d %s）" % [kinds[clampi(error_type, 0, 3)], what, file.get_file(), line, function]
		mutex.lock()
		if queue.size() < 1000:
			queue.append(msg)
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _ready() -> void:
	t0 = Time.get_ticks_msec()
	window_start = t0
	if FileAccess.file_exists(PATH):
		DirAccess.rename_absolute(ProjectSettings.globalize_path(PATH), ProjectSettings.globalize_path(PREVIOUS))
	file = FileAccess.open(PATH, FileAccess.WRITE)
	catcher = ErrorCatcher.new()
	OS.add_logger(catcher)
	var c: Dictionary = main.caps
	note("宇宙 Godot 版 " + version() + "（Godot " + Engine.get_version_info().string + "）")
	note("裝置：%s，%s %s" % [OS.get_model_name(), OS.get_name(), OS.get_version()])
	note("GPU：%s（%s），驅動 %s，%s" % [c.adapter, c.vendor, c.driver, c.method])
	note("螢幕：%s 像素，縮放 %s，更新率 %s Hz；畫面 %s 像素" % [str(DisplayServer.screen_get_size()), str(DisplayServer.screen_get_scale()),
		str(DisplayServer.screen_get_refresh_rate()), str(main.render_size)])
	note("光線追蹤：%s，開關%s" % ["支援" if c.raytracing else "不支援", "開" if c.rt_on else "關"])
	note("升頻：%s，比例 %s%s；MetalFX 時間升頻%s，空間升頻%s" % [c.upscaler, str(c.scale_3d),
		("，MetalFX 允許 " + str(c.metalfx_scale_range)) if c.has("metalfx_scale_range") else "",
		"支援" if c.metalfx_temporal else "不支援", "支援" if c.metalfx_spatial else "不支援"])
	note("HDR：裝置%s，螢幕%s，要求%s" % ["支援" if c.hdr_device else "不支援", "支援" if c.hdr_display else "不支援",
		"開" if DisplayServer.window_is_hdr_output_requested() else "關"])
	note("最高幀率設定 %d，垂直同步 %d" % [Engine.max_fps, DisplayServer.window_get_vsync_mode()])
	_previous_session()
	call_deferred("_measure_setup")


func _measure_setup() -> void:
	vps = {"銀河": main.world_vp, "星點": main.stars_vp}
	for i in main.downs.size():
		vps["光暈↓%d" % i] = main.downs[i].vp
	for i in main.ups.size():
		vps["光暈↑%d" % i] = main.ups[i].vp
	vps["最後"] = get_viewport()
	for k in vps:
		RenderingServer.viewport_set_measure_render_time(vps[k].get_viewport_rid(), true)
	note("HDR：輸出%s，最大線性值 %.2f" % ["開" if DisplayServer.window_is_hdr_output_enabled() else "關", get_window().get_output_max_linear_value()])


## Whether the last run ended the way iOS normally ends an app (sent to the background, then closed while
## suspended), or stopped while on screen: a crash, or iOS closing it for memory or heat. Its last lines come along.
func _previous_session() -> void:
	if not FileAccess.file_exists(PREVIOUS):
		return
	var prev := FileAccess.get_file_as_string(PREVIOUS).strip_edges().split("\n")
	if prev.is_empty():
		return
	var last := prev[prev.size() - 1]
	if last.contains(BACKGROUND) or last.contains(QUIT):
		note("上次執行：切到背景後結束（正常）")
		return
	note("上次執行在畫面上時中斷（可能閃退，或被系統因記憶體、過熱關閉）。上次最後的記錄：")
	for i in range(maxi(0, prev.size() - 15), prev.size()):
		note("    " + prev[i])


func _exit_tree() -> void:
	note(QUIT)
	if catcher:
		OS.remove_logger(catcher)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			note(BACKGROUND)
		NOTIFICATION_APPLICATION_RESUMED:
			note("App 回到前景")
		NOTIFICATION_OS_MEMORY_WARNING:
			note("系統記憶體警告")
		NOTIFICATION_WM_CLOSE_REQUEST:
			note(BACKGROUND + "（關閉）")


## Godot's queued errors: each new message once, repeats counted for the next report.
func _drain_errors() -> void:
	if catcher == null:
		return
	catcher.mutex.lock()
	var q := catcher.queue.duplicate()
	catcher.queue.clear()
	catcher.mutex.unlock()
	for m in q:
		if error_counts.has(m):
			error_counts[m] += 1
		else:
			error_counts[m] = 0
			note(m)


## From the native part: the iPad's thermal state, low power mode, memory and CPU use per core, and events.
func _native_report() -> void:
	if FileAccess.file_exists(NATIVE_STATUS):
		var s = JSON.parse_string(FileAccess.get_file_as_string(NATIVE_STATUS))
		if s is Dictionary:
			var heat := ["正常", "偏熱", "很熱", "危急"]
			var cores := []
			for c in s.get("cores", []):
				cores.append(str(roundi(float(c))))
			note("iPad：溫度 %s，低耗電模式 %s，App 實際用記憶體 %.0f MB，系統還能給 %.0f MB；CPU 各核心 [%s]%%，最忙 %d%%" % [
				heat[clampi(int(s.get("thermal", 0)), 0, 3)], "開" if s.get("lowPower", false) else "關",
				float(s.get("footprintMB", 0)), float(s.get("availableMB", 0)), ", ".join(cores), roundi(float(s.get("busiest", 0)))])
	if FileAccess.file_exists(NATIVE_EVENTS):
		var ev := FileAccess.get_file_as_string(NATIVE_EVENTS).strip_edges().split("\n", false)
		for i in range(native_events_seen, ev.size()):
			note("iPad 系統：" + ev[i])
		native_events_seen = ev.size()


func version() -> String:
	var v := str(ProjectSettings.get_setting("application/config/version", ""))
	return v if v != "" else "dev"


func note(s: String) -> void:
	var line := "[%7.2f] %s" % [(Time.get_ticks_msec() - t0)/1000.0, s]
	lines.append(line)
	if file:
		file.store_line(line)
		file.flush()
	print(line)


## Godot's memory monitors in MB. The texture counter goes below zero (and wraps to a huge number) because the
## panorama's cube is created straight on the rendering device, uncounted, but counted when freed; such values
## show as "?" (the panorama's own size is in its status).
func _mb(monitor: int) -> String:
	var v := Performance.get_monitor(monitor)
	if v < 0 or v > 1e13:
		return "?"
	return "%.0f" % (v/1048576.0)


func full_text() -> String:
	return "\n".join(lines)


func _process(delta: float) -> void:
	_drain_errors()
	frames += 1
	frame_max = maxf(frame_max, delta)
	script_sum += main.script_ms
	if vps.is_empty():
		return
	var total := 0.0
	render_cpu_sum += RenderingServer.get_frame_setup_time_cpu()
	for k in vps:
		render_cpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(vps[k].get_viewport_rid())
		var g := RenderingServer.viewport_get_measured_render_time_gpu(vps[k].get_viewport_rid())
		gpu_sum[k] = gpu_sum.get(k, 0.0) + g
		total += g
	gpu_n += 1
	var r: Array = rt_gpu[bool(main.caps.rt_on)]
	r[0] += total
	r[1] += 1
	var now := Time.get_ticks_msec()
	if now - window_start >= 5000:
		_report(now)


func _report(now: int) -> void:
	var secs := (now - window_start)/1000.0
	var fps := frames/secs
	var parts := []
	var total := 0.0
	for k in gpu_sum:
		var ms: float = gpu_sum[k]/maxi(gpu_n, 1)
		total += ms
		if ms >= 0.05:
			parts.append("%s %.2f" % [k, ms])
	var mem := "記憶體：顯示 %s MB（貼圖 %s，緩衝 %s）" % [_mb(Performance.RENDER_VIDEO_MEM_USED),
		_mb(Performance.RENDER_TEXTURE_MEM_USED), _mb(Performance.RENDER_BUFFER_MEM_USED)]
	var pano: String = main.panorama.status() if main.panorama else ""
	if main.accum:
		pano += "；" + main.accum.status()
	# How busy each side is: its working time per frame over the time between frames. 100% on the GPU means the
	# frame rate is held back by the GPU. The CPU figure is the main thread's work (game script plus preparing the
	# drawing) measured by Godot, not the per-core use iOS reports to native code.
	var interval := secs*1000.0/maxi(frames, 1)
	var script_ms := script_sum/maxi(frames, 1)
	var render_cpu := render_cpu_sum/maxi(gpu_n, 1)
	var cpu_pct := (script_ms + render_cpu)/interval*100.0
	if total > 0.0:
		note("使用率：GPU 約 %.0f%%（每幀工作 %.2f ms／兩幀相隔 %.2f ms），CPU 主執行緒約 %.0f%%（遊戲程式 %.2f + 準備繪圖 %.2f ms）" % [
			total/interval*100.0, total, interval, cpu_pct, script_ms, render_cpu])
	else:
		# Godot's Metal driver gives no GPU timings; with the CPU this idle, the time between frames is the GPU's
		note("使用率：GPU 計時此驅動不提供；兩幀相隔 %.2f ms（120 Hz 為 8.33），CPU 主執行緒約 %.0f%%（遊戲程式 %.2f + 準備繪圖 %.2f ms）%s" % [
			interval, cpu_pct, script_ms, render_cpu, "，卡在 GPU" if interval > 9.0 and cpu_pct < 50.0 else ""])
	note("幀率 %.1f（最慢一幀 %.1f ms），GPU 每幀 %.2f ms：%s；遊戲程式 %.2f ms" % [fps, frame_max*1000.0, total, ", ".join(parts),
		script_sum/maxi(frames, 1)])
	note("位置 log10(距離/光年)=%.2f，%s，望遠鏡 %.1f×，曝光 %.2f；%s；%s" % [main.L, main.hud_place.text, main.tele, main.expo, pano, mem])
	if main.caps.raytracing:
		var on: Array = rt_gpu[true]
		var off: Array = rt_gpu[false]
		var s := "光線追蹤：開關%s" % ("開" if main.caps.rt_on else "關")
		if on[1] > 0 and off[1] > 0:
			s += "，GPU 每幀 開 %.2f ms／關 %.2f ms，多花 %.2f ms" % [on[0]/on[1], off[0]/off[1], on[0]/on[1] - off[0]/off[1]]
		note(s)
	_native_report()
	var repeats := []
	for m in error_counts:
		if error_counts[m] > 0:
			repeats.append("%s ×%d" % [m, error_counts[m]])
			error_counts[m] = 0
	if not repeats.is_empty():
		note("重複的錯誤（這 5 秒）：" + "；".join(repeats))
	window_start = now
	frames = 0
	frame_max = 0.0
	script_sum = 0.0
	render_cpu_sum = 0.0
	gpu_sum.clear()
	gpu_n = 0
