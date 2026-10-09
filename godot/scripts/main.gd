## Phase 1 of the Godot port: the Milky Way and the Local Group, flown in first person, drawn as the web
## version draws them (index.html: 20-volumes.js, 60-universe.js, 70-renderer.js, 80-flight.js, 90-frame.js).
##
## Precision: GDScript floats are 64-bit, Godot's vectors 32-bit. Where you are (P) and every position in the
## universe stay in 64-bit numbers here; each frame the scene is redrawn around you (the camera sits at the
## origin and the light-year frame is shifted by -P and scaled by 1/S, S the distance to the nearest
## landmark), and the galaxies get your position in their own units. Nothing large ever reaches the GPU.
extends Node

const AU_LY := 1.0/63241.077
const TAN0 := 0.46630765815499864   # tan(25 deg): the web's 50 degree vertical field of view
const TELE_MAX := 20000.0
const MAX_PITCH := PI/2 - 1e-7
const PIXEL_CAP := 8388608.0          # the web's high-quality limit on the main picture's pixels
const BLOOM_N := 5
const GAL_SAMPLES := 96.0             # the web's fixed high quality
const MAXG := 5
# the fade range (layer a, b, c, d) of each galaxy volume, in the order the web builds them
const GAL_LAYERS := [[-9.0, -8.0, 6.9, 7.7], [4.2, 5.0, 7.2, 7.9], [4.2, 5.0, 7.2, 7.9], [3.6, 4.4, 7.0, 7.7], [3.6, 4.4, 7.0, 7.7]]
# the point clouds of this phase, by fade range: the Milky Way's stars, its nebula sites, the Local Group
const STAR_LAYERS := [[2.9, 3.6, 6.0, 6.8], [1.6, 2.4, 6.0, 6.8], [4.3, 5.0, 7.2, 7.9]]
const BRIGHT := [
	{key = "natural", label = "自然", exposure = 1.0, auto = true, gain = 1.0},
	{key = "photo", label = "攝影", exposure = 3.0, auto = true, gain = 1.7},
	{key = "guide", label = "固定曝光", exposure = 1.6, auto = false, gain = 1.3}]
const PLACES := [
	[-3.35, "太陽系"], [-2.5, "太陽系的邊緣"], [0.3, "歐特雲"], [1.6, "鄰近的恆星"], [3.3, "太陽附近的星空"],
	[5.4, "銀河系"], [7.0, "本星系群"], [8.75, "拉尼亞凱亞超星系團"], [10.64, "宇宙網"], [99.0, "可觀測宇宙"]]

var data := UniverseData.new()
var caps := {}                # what this device can do (see _detect)
var settings := ConfigFile.new()

# flight state, all 64-bit
var P := PackedFloat64Array([0.0, 0.0, 0.0])
var yaw := 0.0
var pitch := 0.0
var tele := 1.0
var tele_t := 1.0
var thrust := 0.0
var held := 0.0
var look := Vector2.ZERO
var S := 1.0
var L := 0.0
var bright_i := 0
var expo := 1.0
var meter_expo := 1.0
var edge_ly := 4.65e10
var cosmo := {}

# rendering
var world := World3D.new()
var world_vp: SubViewport
var stars_vp: SubViewport
var camera: Camera3D
var stars_camera: Camera3D
var sky_mat: ShaderMaterial
var star_nodes: Array = []    # {node, mat, layer}
var gal_state: Array = []     # per galaxy: {w, R, rows, shape, look, core, arm, layer}
var downs: Array = []
var ups: Array = []
var final_rect: ColorRect
var final_mat: ShaderMaterial
var render_size := Vector2i(4, 4)
var pr := 1.0                 # render pixels per UI point (the web's devicePixelRatio)
var time_acc := 0.0
var panorama: Node
var accum: Node
var wormhole: Node
var last_view := []
var still_for := 0.0
var allow_freeze := true
var script_ms := 0.0          # this script's own time in the last frame

# input
var touches := {}             # index -> {pos, role}
var pinch_d := 0.0
var stick_index := -1
var fly_index := {}           # index -> thrust direction

# ui
var ui: Control
var hud_place: Label
var hud_stats: Label
var hud_near: Label
var stick: TouchPad
var btn_fwd: TouchPad
var btn_back: TouchPad
var tele_button: Button
var settings_button: Button
var panel: PanelContainer
var panel_items := {}
var label_nodes: Array = []
var loading_label: Label
var diag: Node


func _ready() -> void:
	# Chinese text: Godot does not fall back to the system's CJK fonts by itself on iOS (every character showed
	# as a box), so name them: PingFang on the iPad, JhengHei on Windows; the default font stays for Latin text.
	var cjk := SystemFont.new()
	cjk.font_names = PackedStringArray(["PingFang TC", "PingFang SC", "Heiti TC", "Hiragino Sans", "Microsoft JhengHei", "Noto Sans CJK TC", "Noto Sans TC"])
	cjk.font_weight = 400
	ThemeDB.fallback_font = cjk
	settings.load("user://settings.cfg")
	bright_i = int(settings.get_value("view", "bright", 0))
	_build_cosmology()
	if not data.load_all():
		_fatal("宇宙資料沒有載入：請先執行 godot/tools/export_web_data.py")
		return
	_detect()
	_build_world()
	_build_post()
	_build_ui()
	panorama = preload("res://scripts/panorama.gd").new()
	panorama.main = self
	add_child(panorama)
	_start_position()
	_apply_bright()
	get_viewport().size_changed.connect(_resize)
	_resize()
	diag = preload("res://scripts/diagnostics.gd").new()
	diag.main = self
	add_child(diag)
	_test_hooks()


## For checking on a desktop from the command line (after "--"):
##   --pos=x,y,z (light-years)  --face=x,y,z  --tele=N  --bright=0|1|2  --shot=path.png  --frames=N  --rt=on|off
func _test_hooks() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.has("pos"):
		P = PackedFloat64Array(Array(args.pos.split(",")).map(func(x): return float(x)))
	if args.has("face"):
		_face_to(PackedFloat64Array(Array(args.face.split(",")).map(func(x): return float(x))))
	if args.has("tele"):
		tele = float(args.tele)
		tele_t = tele
	if args.has("bright"):
		bright_i = int(args.bright)
		_apply_bright()
	if args.has("expo"):
		expo = float(args.expo)
		meter_expo = expo
	if args.has("noui"):
		ui.get_parent().visible = false
	if args.has("dumpui"):
		await get_tree().process_frame
		for c in [ui, stick, btn_fwd, btn_back, tele_button, settings_button]:
			print(c.name, " ", c.get_global_rect(), " anchors ", [c.anchor_left, c.anchor_top, c.anchor_right, c.anchor_bottom], " offs ", [c.offset_left, c.offset_top, c.offset_right, c.offset_bottom])
	if args.has("upscale"):
		caps.upscaler = args.upscale
		if args.has("scale"):
			caps.scale_3d = float(args.scale)
		_resize()
	if args.has("seconds"):
		get_tree().create_timer(float(args.seconds)).timeout.connect(func(): diag._report(Time.get_ticks_msec()); get_tree().quit())
	if args.has("hop"):
		# after 3 seconds, jump there (to test the panorama's re-bake)
		var to := PackedFloat64Array(Array(args.hop.split(",")).map(func(x): return float(x)))
		get_tree().create_timer(3.0).timeout.connect(func(): P = to; diag.note("跳到 " + str(to)))
	if args.has("accum"):
		# off, or a fixed N (frames per full picture: N²)
		if args.accum == "off":
			accum.enabled = false
		else:
			accum.enabled = true
			accum.auto_n = false
			accum.n = int(args.accum)
			accum.resize(render_size)
	if args.has("wormhole"):
		var wi := int(args.wormhole)
		get_tree().create_timer(2.0).timeout.connect(func(): wormhole.go(wormhole.destinations()[wi]))
	if args.has("nofreeze"):
		allow_freeze = false
	if args.has("holdbake"):
		panorama.hold_after = int(args.holdbake)
	if args.has("pano"):
		panorama.enabled = args.pano == "on"
	if args.has("hdr"):
		get_window().hdr_output_requested = args.hdr == "on"
	if args.has("rt"):
		set_raytracing(args.rt == "on")
	if args.has("shot"):
		get_tree().create_timer(60.0).timeout.connect(func(): get_tree().quit(1))
		if args.has("shotat"):
			await get_tree().create_timer(float(args.shotat)).timeout
		else:
			var n := int(args.get("frames", "60"))
			for i in n:
				await get_tree().process_frame
		final_mat.set_shader_parameter("uEncodedOut", 1.0)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		img.save_png(args.shot)
		if args.has("raw"):
			# the galaxies' own picture, unclamped, to check the HDR values survive the 3D pass
			var w := world_vp.get_texture().get_image()
			var mx := 0.0
			for y in range(0, w.get_height(), 7):
				for x in range(0, w.get_width(), 7):
					var c := w.get_pixel(x, y)
					mx = maxf(mx, maxf(c.r, maxf(c.g, c.b)))
			diag.note("銀河畫面最大值 %.3f，格式 %d" % [mx, w.get_format()])
		diag.note("截圖 " + args.shot)
		get_tree().quit()


# ---------- what this device can do ----------
func _detect() -> void:
	var rd := RenderingServer.get_rendering_device()
	caps.driver = RenderingServer.get_current_rendering_driver_name()
	caps.method = RenderingServer.get_current_rendering_method()
	caps.adapter = RenderingServer.get_video_adapter_name()
	caps.vendor = RenderingServer.get_video_adapter_vendor()
	caps.raytracing = rd != null and rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	caps.metalfx_temporal = rd != null and rd.has_feature(RenderingDevice.SUPPORTS_METALFX_TEMPORAL)
	caps.metalfx_spatial = rd != null and rd.has_feature(RenderingDevice.SUPPORTS_METALFX_SPATIAL)
	caps.hdr_device = rd != null and rd.has_feature(RenderingDevice.SUPPORTS_HDR_OUTPUT)
	caps.hdr_display = DisplayServer.has_feature(DisplayServer.FEATURE_HDR_OUTPUT) and DisplayServer.window_is_hdr_output_supported()
	caps.rt_on = caps.raytracing and bool(settings.get_value("render", "raytracing", false))
	# the temporal upscaler: MetalFX where Godot offers it; otherwise FSR 2, the same kind of upscaler (motion vectors,
	# history) in compute shaders, which also runs on Metal (the M5 iPad reported no MetalFX temporal in Godot 4.7.2)
	var mode = settings.get_value("render", "upscale", "auto")
	caps.scale_3d = float(settings.get_value("render", "upscale_scale", 0.75))
	if mode == "off":
		caps.upscaler = "off"
	elif caps.metalfx_temporal:
		caps.upscaler = "metalfx_temporal"
		var lo := rd.limit_get(RenderingDevice.LIMIT_METALFX_TEMPORAL_SCALER_MIN_SCALE)
		var hi := rd.limit_get(RenderingDevice.LIMIT_METALFX_TEMPORAL_SCALER_MAX_SCALE)
		caps.metalfx_scale_range = [lo, hi]
		if hi > 0:
			caps.scale_3d = clampf(caps.scale_3d, float(lo), float(hi))
	else:
		caps.upscaler = "fsr2"


func set_raytracing(on: bool) -> void:
	caps.rt_on = caps.raytracing and on
	settings.set_value("render", "raytracing", caps.rt_on)
	settings.save("user://settings.cfg")
	# Phase 1: the switch and the detection only. The traced shadows (rock swarms, comet nuclei, Ceres, Vesta,
	# Bennu, Saturn's rings) arrive with those bodies in phase 3; ray-marched gas and black holes stay ray-marched.
	if diag:
		diag.note("光線追蹤開關：" + ("開" if caps.rt_on else "關"))


# ---------- the 3D scene ----------
func _build_world() -> void:
	world_vp = _viewport("World")
	world_vp.world_3d = world
	stars_vp = _viewport("Stars")
	stars_vp.world_3d = world
	stars_vp.transparent_bg = false

	camera = Camera3D.new()
	camera.near = 0.0005
	camera.far = 1e4
	camera.fov = 50.0
	camera.cull_mask = 1
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/galaxy_sky.gdshader")
	sky_mat.set_shader_parameter("uVol", data.noise)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	var env := _environment()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	camera.environment = env
	world_vp.add_child(camera)

	stars_camera = Camera3D.new()
	# points only: no depth test, so only the far plane matters (and Godot's culler needs a sane ratio)
	stars_camera.near = 1.0
	stars_camera.far = 1e4
	stars_camera.cull_mask = 2
	var env2 := _environment()
	env2.background_mode = Environment.BG_COLOR
	env2.background_color = Color.BLACK
	stars_camera.environment = env2
	stars_vp.add_child(stars_camera)

	var shader := preload("res://shaders/stars.gdshader")
	for layer in STAR_LAYERS:
		var c := _find_cloud(layer)
		if c.is_empty():
			push_warning("cloud not found " + str(layer))
			continue
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("uVol", data.noise)
		mat.set_shader_parameter("uGrow", c.grow)
		mat.set_shader_parameter("uSamples", GAL_SAMPLES)
		var mi := MeshInstance3D.new()
		mi.mesh = _points_mesh(c)
		mi.material_override = mat
		mi.layers = 2
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world_vp.add_child(mi)
		star_nodes.append({node = mi, mat = mat, layer = layer})

	for i in data.galaxies.size():
		var g = data.galaxies[i]
		var o: Dictionary = g.o
		var e: PackedFloat64Array = g.M
		gal_state.append({
			w = g.w, R = g.R,
			# rows of the web's Matrix3 (stored column-major): u1, the disc's normal, u2
			rows = [Vector3(e[0], e[3], e[6]), Vector3(e[1], e[4], e[7]), Vector3(e[2], e[5], e[8])],
			rows64 = [[e[0], e[3], e[6]], [e[1], e[4], e[7]], [e[2], e[5], e[8]]],
			shape = Vector4(float(o.get("arms", 2)), float(o.get("b", 0.2)), float(o.get("r0", 0.2)), float(o.get("seed", 1))),
			kind = float(o.get("kind", 0)),
			core = _vec3(o.core), arm = _vec3(o.arm),
			layer = GAL_LAYERS[i] if i < GAL_LAYERS.size() else [4.2, 5.0, 7.2, 7.9]})


func _environment() -> Environment:
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.BLACK
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.glow_enabled = false
	return env


func _viewport(n: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = n
	vp.use_hdr_2d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.disable_3d = false
	vp.audio_listener_enable_3d = false
	vp.positional_shadow_atlas_size = 0
	return vp


func _find_cloud(layer: Array) -> Dictionary:
	for c in data.clouds:
		if c.frame == "ly" and is_equal_approx(c.a, layer[0]) and is_equal_approx(c.b, layer[1]) and is_equal_approx(c.c, layer[2]) and is_equal_approx(c.d, layer[3]):
			return c
	return {}


func _points_mesh(c: Dictionary) -> ArrayMesh:
	var n: int = c.n
	var verts := PackedVector3Array()
	verts.resize(n)
	var custom := PackedFloat32Array()
	custom.resize(n*4)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in n:
		var v := Vector3(c.pos[i*3], c.pos[i*3 + 1], c.pos[i*3 + 2])
		verts[i] = v
		lo = lo.min(v)
		hi = hi.max(v)
		custom[i*4] = c.col[i*3]
		custom[i*4 + 1] = c.col[i*3 + 1]
		custom[i*4 + 2] = c.col[i*3 + 2]
		custom[i*4 + 3] = c.siz[i]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	mesh.custom_aabb = AABB(lo, hi - lo).grow(1.0)
	return mesh


# ---------- finishing: glow chain and tone curve (70-renderer.js) ----------
# Godot draws a sub-viewport before the viewport that contains it, so the chain is nested inside out:
# up0 > up1 > up2 > up3 > down4 > ... > down0 > (world, stars).
func _build_post() -> void:
	var down_shader := preload("res://shaders/bloom_down.gdshader")
	var up_shader := preload("res://shaders/bloom_up.gdshader")
	for i in BLOOM_N:
		var vp := _viewport("Down%d" % i)
		vp.disable_3d = true
		var m := ShaderMaterial.new()
		m.shader = down_shader
		vp.add_child(_rect(m))
		downs.append({vp = vp, mat = m})
	for i in BLOOM_N - 1:
		var vp := _viewport("Up%d" % i)
		vp.disable_3d = true
		var m := ShaderMaterial.new()
		m.shader = up_shader
		vp.add_child(_rect(m))
		ups.append({vp = vp, mat = m})
	# nesting
	downs[0].vp.add_child(world_vp)
	downs[0].vp.add_child(stars_vp)
	for i in range(1, BLOOM_N):
		downs[i].vp.add_child(downs[i - 1].vp)
	ups[BLOOM_N - 2].vp.add_child(downs[BLOOM_N - 1].vp)
	for i in range(BLOOM_N - 3, -1, -1):
		ups[i].vp.add_child(ups[i + 1].vp)
	add_child(ups[0].vp)
	# wiring, as drawFrame does
	downs[0].mat.set_shader_parameter("tSrc", world_vp.get_texture())
	downs[0].mat.set_shader_parameter("tSrc2", stars_vp.get_texture())
	downs[0].mat.set_shader_parameter("uTwo", 1.0)
	downs[0].mat.set_shader_parameter("uThr", 0.85)
	accum = preload("res://scripts/accum.gd").new()
	accum.main = self
	add_child(accum)
	accum.build(downs[0].vp)
	downs[0].mat.set_shader_parameter("tSrc3", accum.texture())
	for i in range(1, BLOOM_N):
		downs[i].mat.set_shader_parameter("tSrc", downs[i - 1].vp.get_texture())
		downs[i].mat.set_shader_parameter("uThr", 0.0)
	var low: SubViewport = downs[BLOOM_N - 1].vp
	for i in range(BLOOM_N - 2, -1, -1):
		ups[i].mat.set_shader_parameter("tA", downs[i].vp.get_texture())
		ups[i].mat.set_shader_parameter("tB", low.get_texture())
		low = ups[i].vp

	final_mat = ShaderMaterial.new()
	final_mat.shader = preload("res://shaders/final.gdshader")
	final_mat.set_shader_parameter("tWorld", world_vp.get_texture())
	final_mat.set_shader_parameter("tStars", stars_vp.get_texture())
	final_mat.set_shader_parameter("tBloom", ups[0].vp.get_texture())
	var layer := CanvasLayer.new()
	layer.layer = -1
	final_mat.set_shader_parameter("tGalaxy", accum.texture())
	final_rect = _rect(final_mat)
	layer.add_child(final_rect)
	add_child(layer)


func _rect(m: Material) -> ColorRect:
	var r := ColorRect.new()
	r.material = m
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	return r


func _resize() -> void:
	var win := get_window()
	var native := DisplayServer.window_get_size()
	var scale := DisplayServer.screen_get_scale()
	if scale <= 0.0:
		scale = 1.0
	win.content_scale_factor = scale
	# the web: pixel density at most 2 and at most 8.4 million pixels in the main picture
	var k := minf(1.0, sqrt(PIXEL_CAP/maxf(float(native.x*native.y), 1.0)))
	k = minf(k, 2.0/scale)
	render_size = Vector2i(maxi(4, roundi(native.x*k)), maxi(4, roundi(native.y*k)))
	pr = scale*k
	world_vp.size = render_size
	stars_vp.size = render_size
	match caps.upscaler:
		"metalfx_temporal":
			world_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
			world_vp.scaling_3d_scale = caps.scale_3d
		"fsr2":
			world_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			world_vp.scaling_3d_scale = caps.scale_3d
		_:
			world_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			world_vp.scaling_3d_scale = 1.0
	sky_mat.set_shader_parameter("uFragH", float(roundi(render_size.y*world_vp.scaling_3d_scale)))
	stars_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	stars_vp.scaling_3d_scale = 1.0
	var w := render_size.x
	var h := render_size.y
	var src := render_size
	for i in BLOOM_N:
		var d := pow(2.0, i + 1)
		var s := Vector2i(maxi(2, roundi(w/d)), maxi(2, roundi(h/d)))
		downs[i].vp.size = s
		downs[i].mat.set_shader_parameter("uPx", Vector2(1.0/src.x, 1.0/src.y))
		if i < BLOOM_N - 1:
			ups[i].vp.size = s
		src = s
	var low: Vector2i = downs[BLOOM_N - 1].vp.size
	for i in range(BLOOM_N - 2, -1, -1):
		ups[i].mat.set_shader_parameter("uPx", Vector2(1.0/low.x, 1.0/low.y))
		low = ups[i].vp.size
	final_mat.set_shader_parameter("uAspect", float(w)/h)
	final_mat.set_shader_parameter("uRes", Vector2(w, h))
	accum.resize(render_size)
	for s in star_nodes:
		s.mat.set_shader_parameter("uPR", pr)
	if panorama:
		panorama.on_resize()


# ---------- where you start ----------
func _start_position() -> void:
	var earth := _mark("地球")
	if earth.is_empty():
		P = PackedFloat64Array([0.9, 0.55, 1.6])
		_set_len(P, 3.2*AU_LY)
	else:
		# the web starts seven Earth radii from Earth; here, with no planets yet, look toward the galactic centre
		P = earth.w.duplicate()
	var gc: PackedFloat64Array = gal_state[0].w
	_face_to(gc)


func _mark(n: String) -> Dictionary:
	for m in data.marks:
		if m.name == n:
			return m
	return {}


func _face_to(t: PackedFloat64Array) -> void:
	var d := [t[0] - P[0], t[1] - P[1], t[2] - P[2]]
	var l := sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2])
	pitch = asin(clampf(d[1]/l, -1, 1))
	yaw = atan2(-d[0]/l, -d[2]/l)


# ---------- each frame (90-frame.js) ----------
func _process(delta: float) -> void:
	if world_vp == null:
		return
	var t_start := Time.get_ticks_usec()
	var dt := minf(delta, 0.1)
	time_acc += dt
	# turning
	var lx := look.x + float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
	var ly := look.y + float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP))
	tele += (tele_t - tele)*(1.0 - exp(-dt*9.0))
	if absf(tele - tele_t) < tele_t*0.001:
		tele = tele_t
	var tan_f := TAN0/tele
	camera.fov = rad_to_deg(2.0*atan(tan_f))
	stars_camera.fov = camera.fov
	yaw -= lx*0.75*dt/tele
	pitch = clampf(pitch - ly*0.575*dt/tele, -MAX_PITCH, MAX_PITCH)
	var cp := cos(pitch)
	var fwd := [-sin(yaw)*cp, sin(pitch), -cos(yaw)*cp]

	# how fast you fly depends on how far the nearest landmark is, so you slow down as you arrive somewhere
	var nd: float = _nearest()[0]
	var plen := _len(P)
	var gap := absf(edge_ly - plen)
	var sm := minf(nd, maxf(gap, edge_ly*0.004))
	var th := thrust + float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
	for idx in fly_index:
		th += fly_index[idx]
	th = clampf(th, -1, 1)
	if th != 0.0:
		held = minf(held + dt, 6.0)
		var step := th*sm*(0.375 + 0.1*held)*dt
		for k in 3:
			P[k] += fwd[k]*step
		if _len(P) > edge_ly*2.2:
			_set_len(P, edge_ly*2.2)
	else:
		held = 0.0
	var near := _nearest()
	S = maxf(near[0], 1e-15)
	var D := maxf(_len(P), 1e-8)
	L = log(D)/log(10.0)
	var s := 1.0/S

	var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	camera.transform = Transform3D(basis, Vector3.ZERO)
	stars_camera.transform = camera.transform

	_update_exposure(dt)
	_update_stars(s)
	_update_galaxies(tan_f)
	final_mat.set_shader_parameter("uExpo", expo)
	final_mat.set_shader_parameter("uTime", time_acc)
	var hdr_on := DisplayServer.window_is_hdr_output_enabled()
	final_mat.set_shader_parameter("uHdr", 1.0 if hdr_on else 0.0)
	final_mat.set_shader_parameter("uMaxLinear", get_window().get_output_max_linear_value())
	_update_labels(s, tan_f)
	if Engine.get_process_frames() % 4 == 0:
		_update_hud(D, near[1])
	script_ms = (Time.get_ticks_usec() - t_start)/1000.0


func _len(v: PackedFloat64Array) -> float:
	return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2])


func _set_len(v: PackedFloat64Array, l: float) -> void:
	var k := l/maxf(_len(v), 1e-300)
	for i in 3:
		v[i] *= k


func _dist(w: PackedFloat64Array) -> float:
	var x := w[0] - P[0]
	var y := w[1] - P[1]
	var z := w[2] - P[2]
	return sqrt(x*x + y*y + z*z)


func _nearest() -> Array:
	var nd := INF
	var best = null
	for m in data.marks:
		var d := maxf(_dist(m.w), m.r0)
		if d < nd:
			nd = d
			best = m
	return [nd, best]


static func sstep(a: float, b: float, x: float) -> float:
	var t := clampf((x - a)/(b - a), 0.0, 1.0)
	return t*t*(3.0 - 2.0*t)


func _layer_alpha(layer: Array) -> float:
	return sstep(layer[0], layer[1], L + log(tele)/log(10.0))*(1.0 - sstep(layer[2], layer[3], L))


func _update_stars(s: float) -> void:
	var origin := Vector3(-P[0]*s, -P[1]*s, -P[2]*s)
	var gain: float = BRIGHT[bright_i].gain
	var far := 1.0
	for st in star_nodes:
		var a := _layer_alpha(st.layer)
		var node: MeshInstance3D = st.node
		node.visible = a > 0.003
		if not node.visible:
			continue
		# the farthest corner of this cloud, in the scaled frame
		var box: AABB = node.mesh.custom_aabb
		for k in 8:
			var c := box.get_endpoint(k)
			var rel := Vector3((c.x - P[0])*s, (c.y - P[1])*s, (c.z - P[2])*s)
			far = maxf(far, rel.length())
		node.transform = Transform3D(Basis.from_scale(Vector3(s, s, s)), origin)
		st.mat.set_shader_parameter("uAlpha", a)
		st.mat.set_shader_parameter("uSz", clampf(0.75 + (st.layer[2] - L)*0.16, 0.75, 1.5))
		st.mat.set_shader_parameter("uGain", gain)
	# Points are drawn without a depth test, so only the far plane matters; Godot's light culler cannot take
	# a near/far ratio much beyond a million, so the range follows the clouds in view.
	stars_camera.far = far*1.01
	stars_camera.near = far*1e-6


## The galaxies the web would draw this frame, in its order, with its per-frame uniforms (90-frame.js and
## renderVisibleVolumes). With the panorama in use, the view-dependent skips are left out: the panorama holds
## every direction.
func active_galaxies(tan_f: float, for_view: bool) -> Array:
	var out := []
	var tele_reach := log(tele)/log(10.0)
	for g in gal_state:
		var lay: Array = g.layer
		var a := sstep(lay[0], lay[1], L + tele_reach)*(1.0 - sstep(lay[2], lay[3], L))
		var pix := _volume_pixels(g, tan_f)
		if for_view and tele > 1.01 and a < 1.0 and _sphere_in_view(g.w, g.R, tan_f):
			a = maxf(a, sstep(40, 80, pix)*(1.0 - sstep(lay[2], lay[3], L)))
		if a <= 0.003:
			continue
		var rel := [(P[0] - g.w[0])/g.R, (P[1] - g.w[1])/g.R, (P[2] - g.w[2])/g.R]
		var ro := []
		for r in g.rows64:
			ro.append(r[0]*rel[0] + r[1]*rel[1] + r[2]*rel[2])
		var ro_len := sqrt(ro[0]*ro[0] + ro[1]*ro[1] + ro[2]*ro[2])
		if ro_len > minf(500.0*tele, 3000.0):
			continue
		if pix < 10.0:
			continue
		if for_view and not _sphere_in_view(g.w, g.R, tan_f):
			continue
		# from inside a galaxy its light surrounds you; hold it down so it reads as a soft band, not a wall
		var inside := 1.0 - sstep(0.9, 1.6, sqrt(ro[0]*ro[0] + ro[1]*ro[1]*10.24 + ro[2]*ro[2]))
		out.append({g = g, ro = Vector3(ro[0], ro[1], ro[2]), alpha = a, gain = 1.0 - 0.93*inside})
	return out


func _volume_pixels(g: Dictionary, tan_f: float) -> float:
	var d := _dist(g.w)
	if d <= g.R*1.05:
		return 1e9
	return g.R/sqrt(d*d - g.R*g.R)/tan_f*(render_size.y/2.0)


func _sphere_in_view(w: PackedFloat64Array, radius: float, tan_f: float) -> bool:
	var v := [w[0] - P[0], w[1] - P[1], w[2] - P[2]]
	if v[0]*v[0] + v[1]*v[1] + v[2]*v[2] <= radius*radius:
		return true
	var b := camera.transform.basis
	var right := b.x
	var up := b.y
	var fwd := -b.z
	var z: float = v[0]*fwd.x + v[1]*fwd.y + v[2]*fwd.z
	if z < -radius:
		return false
	var aspect := float(render_size.x)/render_size.y
	var tx := tan_f*aspect
	var ty := tan_f
	if absf(v[0]*right.x + v[1]*right.y + v[2]*right.z) > z*tx + radius*sqrt(1 + tx*tx):
		return false
	if absf(v[0]*up.x + v[1]*up.y + v[2]*up.z) > z*ty + radius*sqrt(1 + ty*ty):
		return false
	return true


func galaxy_uniforms(list: Array) -> Dictionary:
	var u := {
		uCount = list.size(), uRo = PackedVector3Array(), uM0 = PackedVector3Array(), uM1 = PackedVector3Array(),
		uM2 = PackedVector3Array(), uShape = PackedVector4Array(), uLook = PackedVector4Array(),
		uCore = PackedVector3Array(), uArmCol = PackedVector3Array()}
	for i in MAXG:
		if i < list.size():
			var e = list[i]
			var g = e.g
			u.uRo.append(e.ro)
			u.uM0.append(g.rows[0])
			u.uM1.append(g.rows[1])
			u.uM2.append(g.rows[2])
			u.uShape.append(g.shape)
			u.uLook.append(Vector4(g.kind, e.gain, e.alpha, 0.0))
			u.uCore.append(g.core)
			u.uArmCol.append(g.arm)
		else:
			u.uRo.append(Vector3.ZERO)
			u.uM0.append(Vector3.ZERO)
			u.uM1.append(Vector3.ZERO)
			u.uM2.append(Vector3.ZERO)
			u.uShape.append(Vector4.ZERO)
			u.uLook.append(Vector4.ZERO)
			u.uCore.append(Vector3.ZERO)
			u.uArmCol.append(Vector3.ZERO)
	return u


static func apply_uniforms(mat: ShaderMaterial, u: Dictionary) -> void:
	for k in u:
		mat.set_shader_parameter(k, u[k])


func _update_galaxies(tan_f: float) -> void:
	var view_list := active_galaxies(tan_f, true)
	var u := galaxy_uniforms(view_list)
	u.uSamples = GAL_SAMPLES
	# the stars are dimmed by every galaxy along their line of sight, as the web's composite dims them
	for st in star_nodes:
		if st.node.visible:
			apply_uniforms(st.mat, u)
	# (use_for_frame also starts and advances the bakes, so it runs every frame)
	var use_pano: bool = panorama != null and panorama.use_for_frame()
	var first_bake: bool = panorama != null and panorama.first_bake()
	# (inside a wormhole the tunnel covers the wait)
	loading_label.visible = first_bake and not (wormhole and wormhole.active())
	if first_bake:
		# At start-up the GPU goes to the panorama alone (on the iPad a live sky costs as much as a whole tile);
		# the sky waits, black, behind a progress note.
		loading_label.text = "正在準備銀河全景圖… %d%%" % roundi(panorama.progress()*100.0)
		sky_mat.set_shader_parameter("uPanoOn", 0.0)
		sky_mat.set_shader_parameter("uCount", 0)
	elif use_pano:
		var mask: Array = panorama.face_mask()
		sky_mat.set_shader_parameter("uPanoOn", 1.0)
		sky_mat.set_shader_parameter("uFaceOkA", mask[0])
		sky_mat.set_shader_parameter("uFaceOkB", mask[1])
		if panorama.partial:
			apply_uniforms(sky_mat, u)       # the faces still being baked are drawn live
		else:
			sky_mat.set_shader_parameter("uCount", 0)
	elif accum.enabled:
		# live, accumulated over frames; the sky itself stays black
		sky_mat.set_shader_parameter("uPanoOn", 0.0)
		sky_mat.set_shader_parameter("uCount", 0)
		accum.update(u, camera.transform.basis, tan_f, float(render_size.x)/render_size.y, P)
	else:
		sky_mat.set_shader_parameter("uPanoOn", 0.0)
		apply_uniforms(sky_mat, u)
	var galaxy_on: bool = not first_bake and not use_pano and accum.enabled
	if not galaxy_on:
		accum.disable()
	downs[0].mat.set_shader_parameter("uThree", 1.0 if galaxy_on else 0.0)
	final_mat.set_shader_parameter("uGalaxyOn", 1.0 if galaxy_on else 0.0)
	# Standing quite still while a panorama bakes (same place, view and zoom), the live picture cannot change:
	# keep the last one instead of computing it again, and the GPU goes to the bake. Any move draws it again.
	var view_now := [camera.transform, tele, P[0], P[1], P[2]]
	if view_now == last_view:
		still_for += get_process_delta_time()
	else:
		still_for = 0.0
	last_view = view_now
	var freeze: bool = allow_freeze and not first_bake and panorama != null and panorama.bake_face >= 0 and still_for > 0.25
	var mode := SubViewport.UPDATE_DISABLED if freeze else SubViewport.UPDATE_ALWAYS
	if world_vp.render_target_update_mode != mode:
		world_vp.render_target_update_mode = mode


# ---------- exposure (updateExposure; no lit bodies in this phase) ----------
func _apply_bright() -> void:
	var preset: Dictionary = BRIGHT[bright_i]
	expo = preset.exposure
	meter_expo = preset.exposure
	if panel_items.has("bright"):
		panel_items.bright.text = "觀感：" + preset.label


func _update_exposure(dt: float) -> void:
	var preset: Dictionary = BRIGHT[bright_i]
	var base: float = preset.exposure
	var target := base
	if preset.auto:
		# an otherwise dark star field keeps its baseline instead of driving exposure to infinity
		var lum := 0.0
		var coverage := 0.0
		var adapt := 0.5/maxf(lum, 0.00002)
		if lum < 0.1:
			adapt = 2.2 + (adapt - 2.2)*sstep(0.005, 0.18, coverage)
		target = base*clampf(adapt, 0.04, 2048.0)
	var rate := 3.0 if target < meter_expo else 0.65
	var blend := 1.0 - exp(-maxf(0.0, dt)*rate)
	meter_expo += (target - meter_expo)*blend
	var sky_target := minf(target, base*3.0)
	expo += (sky_target - expo)*blend


# ---------- labels (90-frame.js) ----------
func _update_labels(s: float, tan_f: float) -> void:
	var pick := []
	if wormhole and wormhole.active():
		for l in label_nodes:
			l.visible = false
		return
	for b in data.labels:
		var dc := _dist(b.w)
		if dc < b.rv and dc >= b.rmin and b.rv < S*3e4*tele*tele:
			pick.append([dc/b.rv, b])
	pick.sort_custom(func(p, q): return p[0] < q[0])
	var shown := 0
	var ui_size := ui.size
	var to_ui := Vector2(ui_size.x/render_size.x, ui_size.y/render_size.y)
	for item in pick:
		if shown >= 14:
			break
		var b = item[1]
		var rel := Vector3((b.w[0] - P[0])*s, (b.w[1] - P[1])*s, (b.w[2] - P[2])*s)
		if camera.is_position_behind(rel):
			continue
		var px := camera.unproject_position(rel)*to_ui
		if px.x < 0 or px.x > ui_size.x - 30 or px.y < 0 or px.y > ui_size.y:
			continue
		var lab: Label = _label_node(shown)
		lab.text = b.text
		lab.modulate = Color(0.953, 0.851, 0.635) if b.home else Color(0.933, 0.941, 0.965, 0.72)
		lab.modulate.a *= 1.0 - sstep(0.6, 1.0, item[0])
		lab.position = px + Vector2(-3, -lab.size.y*0.5)
		lab.visible = true
		shown += 1
	for i in range(shown, label_nodes.size()):
		label_nodes[i].visible = false


func _label_node(i: int) -> Label:
	while label_nodes.size() <= i:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 11)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui.add_child(l)
		ui.move_child(l, 0)
		label_nodes.append(l)
	return label_nodes[i]


# ---------- HUD ----------
func _update_hud(D: float, near) -> void:
	var place = PLACES[PLACES.size() - 1][1]
	for p in PLACES:
		if L < p[0]:
			place = p[1]
			break
	hud_place.text = place
	var left := edge_ly - D
	var lines := "離家　" + fmt_dist(D) + "\n光行　" + fmt_light(D)
	if left > 0:
		lines += "\n到視界　" + ly_text(left)
	hud_stats.text = lines
	if near:
		var real := _dist(near.w)
		hud_near.text = "最近的地標：" + near.name + ("，還有 " + fmt_dist(real) if real > near.r0*1.02 else "，就在眼前")


static func commas(x: float) -> String:
	var s := str(roundi(x))
	var out := ""
	var n := s.length()
	for i in n:
		out += s[i]
		var rest := n - 1 - i
		if rest > 0 and rest % 3 == 0 and s[i] != "-":
			out += ","
	return out


static func _trim(x: float, digits: int) -> String:
	var s := String.num(x, digits)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


static func ly_text(d: float) -> String:
	if d < 100:
		return (String.num(d, 1) if d < 10 else str(roundi(d))) + " 光年"
	if d < 1e4:
		return commas(d) + " 光年"
	if d < 1e8:
		return (_trim(d/1e4, 1) if d/1e4 < 100 else commas(d/1e4)) + " 萬光年"
	return (_trim(d/1e8, 1) if d/1e8 < 100 else commas(d/1e8)) + " 億光年"


static func fmt_dist(ly: float) -> String:
	var au := ly/AU_LY
	var km := au*1.495979e8
	if km < 1:
		return _trim(km*1000, 2 if km < 0.01 else 1) + " 公尺"
	if km < 1e4:
		return commas(km) + " 公里"
	if au < 0.1:
		return (_trim(km/1e4, 1) if km/1e4 < 100 else commas(km/1e4)) + " 萬公里"
	if au < 1000:
		return (String.num(au, 2) if au < 10 else commas(au)) + " 天文單位"
	if ly < 1:
		return String.num(ly, 2) + " 光年"
	return ly_text(ly)


func fmt_light(ly: float) -> String:
	if ly >= 1e8:
		var h = cosmo_at_distance(ly)
		if h.is_empty():
			return "超出此地球觀測模型範圍"
		return "宇宙學回溯約 " + String.num(h.lookback/1e8, 1) + " 億年 · z≈" + (String.num(h.z, 2) if h.z < 10 else str(roundi(h.z)))
	var hrs := ly*8766.0
	if hrs*3600 < 90:
		return "光要走 " + (String.num(hrs*3600, 1) if hrs*3600 < 10 else str(roundi(hrs*3600))) + " 秒"
	if hrs < 1:
		return "光要走 " + str(roundi(hrs*60)) + " 分鐘"
	if hrs < 48:
		return "光要走 " + (String.num(hrs, 1) if hrs < 10 else str(roundi(hrs))) + " 小時"
	if ly < 1:
		return "光要走 " + str(roundi(hrs/24)) + " 天"
	if ly < 1e4:
		return "光要走 " + ((String.num(ly, 1) if ly < 10 else str(roundi(ly))) if ly < 100 else commas(ly)) + " 年"
	if ly < 1e8:
		return "光要走 " + (_trim(ly/1e4, 1) if ly/1e4 < 100 else commas(ly/1e4)) + " 萬年"
	return "光要走 " + (_trim(ly/1e8, 1) if ly/1e8 < 100 else commas(ly/1e8)) + " 億年"


# Flat Lambda-CDM (Planck-like), as COSMOLOGY in 60-universe.js
func _build_cosmology() -> void:
	var matter := 0.315
	var radiation := 0.000092
	var vacuum := 1.0 - matter - radiation
	var hubble_years := 3.0856775814913673e19/67.4/31557600.0
	var hubble_ly := 299792.458/67.4*3.261563777e6
	var count := 4096
	var dx := log(10000001.0)/count
	var dist := PackedFloat64Array([0.0])
	var look := PackedFloat64Array([0.0])
	var zs := PackedFloat64Array([0.0])
	var distance := 0.0
	var time := 0.0
	var f := func(x: float) -> Array:
		var zp1 := exp(x)
		var e := sqrt(radiation*pow(zp1, 4) + matter*pow(zp1, 3) + vacuum)
		return [zp1/e, 1.0/e]
	for i in count:
		var a: Array = f.call(i*dx)
		var b: Array = f.call((i + 0.5)*dx)
		var c: Array = f.call((i + 1)*dx)
		distance += dx*(a[0] + 4*b[0] + c[0])/6.0*hubble_ly
		time += dx*(a[1] + 4*b[1] + c[1])/6.0*hubble_years
		dist.append(distance)
		look.append(time)
		zs.append(exp((i + 1)*dx) - 1.0)
	cosmo = {dist = dist, look = look, z = zs, horizon = distance, age = time}
	edge_ly = distance


func cosmo_at_distance(d: float) -> Dictionary:
	var dist: PackedFloat64Array = cosmo.dist
	if d < 0 or d > cosmo.horizon:
		return {}
	var lo := 0
	var hi := dist.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if dist[mid] < d:
			lo = mid
		else:
			hi = mid
	var f := (d - dist[lo])/(dist[hi] - dist[lo])
	return {lookback = cosmo.look[lo] + (cosmo.look[hi] - cosmo.look[lo])*f, z = cosmo.z[lo] + (cosmo.z[hi] - cosmo.z[lo])*f}


# ---------- input (80-flight.js) ----------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position, event.relative)
	elif event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_touch(1000, event.position, event.pressed)
		elif event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var delta_y := -100.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 100.0
			set_tele(tele_t*exp(-delta_y*event.factor*0.0022))
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		if touches.has(1000):
			_drag(1000, event.position, event.relative)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		panel.visible = false


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		if _over_buttons(pos):
			return
		var role := "sky"
		if stick.get_global_rect().has_point(pos):
			role = "stick"
			stick_index = index
			_stick_move(pos)
		elif btn_fwd.get_global_rect().has_point(pos):
			role = "fly"
			fly_index[index] = 1.0
			btn_fwd.set_pressed(true)
		elif btn_back.get_global_rect().has_point(pos):
			role = "fly"
			fly_index[index] = -1.0
			btn_back.set_pressed(true)
		touches[index] = {pos = pos, role = role}
		if _sky_count() == 2:
			pinch_d = _pinch_dist()
	else:
		if not touches.has(index):
			return
		var t = touches[index]
		touches.erase(index)
		if t.role == "stick":
			stick_index = -1
			look = Vector2.ZERO
			stick.set_knob(Vector2.ZERO)
		elif t.role == "fly":
			fly_index.erase(index)
			btn_fwd.set_pressed(fly_index.values().has(1.0))
			btn_back.set_pressed(fly_index.values().has(-1.0))
		pinch_d = 0.0


func _drag(index: int, pos: Vector2, rel: Vector2) -> void:
	if not touches.has(index):
		return
	var t = touches[index]
	t.pos = pos
	if t.role == "stick":
		_stick_move(pos)
	elif t.role == "sky":
		var n := _sky_count()
		if n == 1:
			# a swipe steers the same way as the pad; zoom makes turning finer
			yaw -= rel.x*0.0035/tele
			pitch = clampf(pitch - rel.y*0.0035/tele, -MAX_PITCH, MAX_PITCH)
		elif n == 2:
			var d := _pinch_dist()
			if pinch_d > 0 and d > 0:
				set_tele(tele_t*pow(d/pinch_d, 1.6))
			pinch_d = d


func _sky_count() -> int:
	var n := 0
	for k in touches:
		if touches[k].role == "sky":
			n += 1
	return n


func _pinch_dist() -> float:
	var pts := []
	for k in touches:
		if touches[k].role == "sky":
			pts.append(touches[k].pos)
	return pts[0].distance_to(pts[1]) if pts.size() >= 2 else 0.0


func _stick_move(pos: Vector2) -> void:
	var r := stick.get_global_rect()
	var R := r.size.x/2
	var d := (pos - (r.position + Vector2(R, R)))/(R*0.72)
	if d.length() > 1:
		d = d.normalized()
	look = d
	stick.set_knob(d)


func _over_buttons(pos: Vector2) -> bool:
	for c in [tele_button, settings_button, wormhole.button]:
		if c.visible and c.get_global_rect().has_point(pos):
			return true
	if wormhole.list_panel.visible and wormhole.list_panel.get_global_rect().has_point(pos):
		return true
	return panel.visible and panel.get_global_rect().has_point(pos)


func set_tele(v: float) -> void:
	tele_t = clampf(v, 1.0, TELE_MAX)
	_tele_text()


func _tele_text() -> void:
	var active := tele > 1.0 or tele_t > 1.0
	var v := tele_t
	var t := (_trim(v, 1) if v < 10 else commas(v)) + "×"
	tele_button.text = ("關閉望遠鏡" if active else "開啟望遠鏡") + "\n" + t


func _on_tele_pressed() -> void:
	if tele > 1.0 or tele_t > 1.0:
		tele = 1.0
		tele_t = 1.0
	else:
		tele_t = 10.0
	_tele_text()


# ---------- UI ----------
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)

	var hud := VBoxContainer.new()
	hud.position = Vector2(24, 24)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud)
	hud_place = Label.new()
	hud_place.add_theme_font_size_override("font_size", 30)
	hud.add_child(hud_place)
	hud_stats = Label.new()
	hud_stats.add_theme_font_size_override("font_size", 12)
	hud_stats.modulate = Color(0.933, 0.941, 0.965, 0.72)
	hud.add_child(hud_stats)
	hud_near = Label.new()
	hud_near.add_theme_font_size_override("font_size", 12)
	hud_near.modulate = Color(0.933, 0.941, 0.965, 0.55)
	hud.add_child(hud_near)

	stick = TouchPad.new(TouchPad.Kind.STICK)
	_place(stick, Control.PRESET_BOTTOM_LEFT, 24, -140, 112, 112)
	ui.add_child(stick)
	btn_fwd = TouchPad.new(TouchPad.Kind.BUTTON, "前進", true)
	_place(btn_fwd, Control.PRESET_BOTTOM_RIGHT, -112, -176, 88, 88)
	ui.add_child(btn_fwd)
	btn_back = TouchPad.new(TouchPad.Kind.BUTTON, "後退")
	_place(btn_back, Control.PRESET_BOTTOM_RIGHT, -98, -82, 60, 60)
	ui.add_child(btn_back)

	tele_button = _button("開啟望遠鏡\n1×", _on_tele_pressed)
	_place(tele_button, Control.PRESET_CENTER_BOTTOM, -51, -96, 102, 44)
	ui.add_child(tele_button)
	settings_button = _button("設定", func(): panel.visible = not panel.visible; _refresh_panel())
	_place(settings_button, Control.PRESET_TOP_RIGHT, -96, 24, 72, 36)
	ui.add_child(settings_button)
	_build_panel()
	loading_label = Label.new()
	loading_label.add_theme_font_size_override("font_size", 14)
	loading_label.modulate = Color(0.933, 0.941, 0.965, 0.72)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(loading_label, Control.PRESET_CENTER, -200, -12, 400, 24)
	loading_label.visible = false
	ui.add_child(loading_label)
	wormhole = preload("res://scripts/wormhole.gd").new()
	wormhole.main = self
	add_child(wormhole)
	wormhole.build(ui)


## anchors, then offsets from those anchors
func _place(c: Control, preset: int, x: float, y: float, w: float, h: float) -> void:
	c.set_anchors_preset(preset)
	c.offset_left = x
	c.offset_top = y
	c.offset_right = x + w
	c.offset_bottom = y + h


func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(cb)
	return b


func _build_panel() -> void:
	panel = PanelContainer.new()
	panel.visible = false
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -360
	panel.offset_top = 72
	panel.offset_right = -24
	ui.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := Label.new()
	title.text = "設定"
	title.add_theme_font_size_override("font_size", 16)
	box.add_child(title)

	panel_items.bright = _button("觀感：", func():
		bright_i = (bright_i + 1) % BRIGHT.size()
		settings.set_value("view", "bright", bright_i)
		settings.save("user://settings.cfg")
		_apply_bright())
	box.add_child(panel_items.bright)

	panel_items.hdr = _button("HDR", func():
		var want := not DisplayServer.window_is_hdr_output_requested()
		get_window().hdr_output_requested = want
		settings.set_value("render", "hdr", want)
		settings.save("user://settings.cfg")
		_refresh_panel())
	box.add_child(panel_items.hdr)

	var rt_row := VBoxContainer.new()
	var rt := CheckButton.new()
	rt.text = "光線追蹤"
	rt.focus_mode = Control.FOCUS_NONE
	rt.add_theme_font_size_override("font_size", 12)
	rt.button_pressed = caps.rt_on
	rt.disabled = not caps.raytracing
	rt.toggled.connect(func(on): set_raytracing(on); _refresh_panel())
	rt_row.add_child(rt)
	var rt_note := Label.new()
	rt_note.add_theme_font_size_override("font_size", 10)
	rt_note.modulate = Color(1, 1, 1, 0.55)
	rt_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt_row.add_child(rt_note)
	box.add_child(rt_row)
	panel_items.rt = rt
	panel_items.rt_note = rt_note

	panel_items.info = Label.new()
	panel_items.info.add_theme_font_size_override("font_size", 10)
	panel_items.info.modulate = Color(1, 1, 1, 0.55)
	panel_items.info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(panel_items.info)

	box.add_child(_button("分享記錄檔", _share_log))
	box.add_child(_button("複製記錄檔", func():
		DisplayServer.clipboard_set(diag.full_text())
		panel_items.copied.text = "已複製，可以貼到訊息或備忘錄"))
	panel_items.copied = Label.new()
	panel_items.copied.add_theme_font_size_override("font_size", 10)
	panel_items.copied.modulate = Color(1, 1, 1, 0.55)
	box.add_child(panel_items.copied)
	box.add_child(_button("關閉", func(): panel.visible = false))
	if settings.has_section_key("render", "hdr"):
		get_window().hdr_output_requested = bool(settings.get_value("render", "hdr"))


## The log as a file through the iPad's share sheet (AirDrop, Messages, Mail, Save to Files), by way of the
## small native plugin in ios/plugins/sharelog; on a computer, the file shown in the file manager.
func _share_log() -> void:
	diag._report(Time.get_ticks_msec())       # the latest numbers first
	var path := ProjectSettings.globalize_path(diag.PATH)
	var ok := false
	if OS.get_name() == "iOS":
		ok = OS.shell_open("universe-share://file?path=" + path.uri_encode()) == OK
	else:
		ok = OS.shell_show_in_file_manager(path) == OK
	if ok:
		panel_items.copied.text = ""
	else:
		DisplayServer.clipboard_set(diag.full_text())
		panel_items.copied.text = "無法開啟分享，已改為複製到剪貼簿"
	diag.note("分享記錄檔：" + ("已開啟" if ok else "失敗，改為複製"))


func _refresh_panel() -> void:
	panel_items.bright.text = "觀感：" + BRIGHT[bright_i].label
	if caps.hdr_display:
		panel_items.hdr.disabled = false
		panel_items.hdr.text = "HDR：" + ("開" if DisplayServer.window_is_hdr_output_requested() else "關")
	else:
		panel_items.hdr.disabled = true
		panel_items.hdr.text = "HDR：這個螢幕不支援"
	panel_items.rt.set_pressed_no_signal(caps.rt_on)
	if caps.raytracing:
		panel_items.rt_note.text = "預設關閉。目前還沒有使用光線追蹤的天體（第三階段加入碎石群、彗星等的陰影）。"
	else:
		panel_items.rt_note.text = "這台裝置目前不支援"
	var up := {"metalfx_temporal": "MetalFX 時間升頻", "fsr2": "FSR 2 時間升頻", "off": "關"}
	panel_items.info.text = "升頻：%s（%d%%）\nGPU：%s（%s）\n版本：%s" % [up.get(caps.upscaler, caps.upscaler),
		roundi(caps.scale_3d*100) if caps.upscaler != "off" else 100, caps.adapter, caps.driver, diag.version() if diag else ""]


func _vec3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _fatal(msg: String) -> void:
	var l := Label.new()
	l.text = msg
	l.position = Vector2(24, 24)
	add_child(l)
