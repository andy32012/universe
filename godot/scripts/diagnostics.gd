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


func _ready() -> void:
	t0 = Time.get_ticks_msec()
	window_start = t0
	if FileAccess.file_exists(PATH):
		DirAccess.rename_absolute(ProjectSettings.globalize_path(PATH), ProjectSettings.globalize_path("user://universe-log-previous.txt"))
	file = FileAccess.open(PATH, FileAccess.WRITE)
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


func full_text() -> String:
	return "\n".join(lines)


func _process(delta: float) -> void:
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
	var mem := "記憶體：顯示 %.0f MB（貼圖 %.0f，緩衝 %.0f），程式 %.0f MB" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)/1048576.0,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)/1048576.0,
		Performance.get_monitor(Performance.MEMORY_STATIC)/1048576.0]
	var pano: String = main.panorama.status() if main.panorama else ""
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
	window_start = now
	frames = 0
	frame_max = 0.0
	script_sum = 0.0
	render_cpu_sum = 0.0
	gpu_sum.clear()
	gpu_n = 0
