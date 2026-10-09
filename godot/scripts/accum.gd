## The live galaxies, accumulated over frames (handoff: "分幀累積"): where the panorama does not apply, each
## frame marches only one pixel of every N×N block (galaxy_march.gdshader) and fills in the rest from the last
## full picture (galaxy_resolve.gdshader). Standing still, every pixel is recomputed once every N² frames and the
## picture is the full-resolution one exactly; while you fly it is held to this frame's samples, so it may look
## a little softer, never smeared. The galaxies' picture is added in the finishing passes, where the sky used to
## be (the sky is the background, so the sum is the same), and is not upscaled a second time.
##
## N follows the measured frame time: up while frames take longer than 12 ms (120 Hz is 8.3), down while they
## take under 4 ms.
extends Node

var main: Node

const ORDERS := {
	1: [Vector2i(0, 0)],
	2: [Vector2i(0, 0), Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 1)],
	3: [Vector2i(0, 0), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2), Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 0), Vector2i(0, 2), Vector2i(1, 1)],
	# a Bayer matrix's order, for an even spread at every step
	4: [Vector2i(0, 0), Vector2i(2, 2), Vector2i(2, 0), Vector2i(0, 2), Vector2i(1, 1), Vector2i(3, 3), Vector2i(3, 1), Vector2i(1, 3),
		Vector2i(1, 0), Vector2i(3, 2), Vector2i(3, 0), Vector2i(1, 2), Vector2i(0, 1), Vector2i(2, 3), Vector2i(2, 1), Vector2i(0, 3)]}
const N_MAX := 4
const SLOW := 0.012               # seconds a frame: more frames per full picture
const FAST := 0.004               # seconds a frame: fewer

var enabled := false
var auto_n := true
var n := 2
var active := false
var frame := 0
var full := Vector2i(4, 4)
var march_vp: SubViewport
var march_mat: ShaderMaterial
var resolve_vp: SubViewport
var resolve_mat: ShaderMaterial
var hist_rid := RID()
var hist_tex: Texture2DRD
var hist_ok := false
var drawn := false                # the resolve pass drew this frame (copy it to the history after the frame)
var prev := {}
var last_p := PackedFloat64Array()
var last_look := []
var dt_sum := 0.0
var dt_n := 0
var changes := 0


func build(parent: Node) -> void:
	# off by default: in motion it may look a little softer, and the galaxy's picture is not traded for speed
	enabled = bool(main.settings.get_value("render", "accumulate", false))
	march_vp = main._viewport("GalaxyMarch")
	march_vp.disable_3d = true
	march_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	march_mat = ShaderMaterial.new()
	march_mat.shader = preload("res://shaders/galaxy_march.gdshader")
	march_mat.set_shader_parameter("uVol", main.data.noise)
	march_vp.add_child(main._rect(march_mat))
	resolve_vp = main._viewport("GalaxyResolve")
	resolve_vp.disable_3d = true
	resolve_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	resolve_mat = ShaderMaterial.new()
	resolve_mat.shader = preload("res://shaders/galaxy_resolve.gdshader")
	resolve_mat.set_shader_parameter("tCur", march_vp.get_texture())
	resolve_vp.add_child(main._rect(resolve_mat))
	resolve_vp.add_child(march_vp)        # drawn before the viewport that contains it
	parent.add_child(resolve_vp)
	RenderingServer.frame_post_draw.connect(_after_draw)


func texture() -> Texture2D:
	return resolve_vp.get_texture()


func resize(size: Vector2i) -> void:
	full = size
	resolve_vp.size = full
	march_vp.size = Vector2i(int(ceil(full.x/float(n))), int(ceil(full.y/float(n))))
	resolve_mat.set_shader_parameter("uFull", Vector2(full))
	resolve_mat.set_shader_parameter("uLow", Vector2(march_vp.size))
	march_mat.set_shader_parameter("uFull", Vector2(full))
	reset()


func reset() -> void:
	hist_ok = false
	frame = 0
	prev = {}


func status() -> String:
	if not enabled:
		return "分幀累積：關"
	return "分幀累積 %d×%d%s，換過 %d 次" % [n, n, "（使用中）" if active else "", changes]


## Draw this frame's share. u: the galaxies' uniforms; basis: the camera's; p: where you are (64-bit).
func update(u: Dictionary, basis: Basis, tan_f: float, aspect: float, p: PackedFloat64Array) -> void:
	if not active:
		active = true
		march_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		resolve_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		reset()
	_adapt()
	# moving through space, or the galaxies' fade or glow changing: last picture's values need holding in range
	var look := []
	for k in u.uLook:
		look.append(k)
	var clamp_now := last_p.size() != 3 or p[0] != last_p[0] or p[1] != last_p[1] or p[2] != last_p[2] or look != last_look
	last_p = p.duplicate()
	last_look = look
	var order: Array = ORDERS[n]
	var off: Vector2i = order[frame % order.size()]
	var right := basis.x
	var up := basis.y
	var fwd := -basis.z
	main.apply_uniforms(march_mat, u)
	for m in [march_mat, resolve_mat]:
		m.set_shader_parameter("uRight", right)
		m.set_shader_parameter("uUp", up)
		m.set_shader_parameter("uFwd", fwd)
		m.set_shader_parameter("uTanF", tan_f)
		m.set_shader_parameter("uAspect", aspect)
		m.set_shader_parameter("uN", n)
		m.set_shader_parameter("uOffset", off)
	var pv: Dictionary = prev if not prev.is_empty() else {right = right, up = up, fwd = fwd, tan = tan_f}
	resolve_mat.set_shader_parameter("uPRight", pv.right)
	resolve_mat.set_shader_parameter("uPUp", pv.up)
	resolve_mat.set_shader_parameter("uPFwd", pv.fwd)
	resolve_mat.set_shader_parameter("uPTanF", pv.tan)
	resolve_mat.set_shader_parameter("uHistOk", 1.0 if hist_ok else 0.0)
	resolve_mat.set_shader_parameter("uClamp", 1.0 if clamp_now else 0.0)
	if hist_tex:
		resolve_mat.set_shader_parameter("tHist", hist_tex)
	prev = {right = right, up = up, fwd = fwd, tan = tan_f}
	frame += 1
	drawn = true


func disable() -> void:
	if not active:
		return
	active = false
	march_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	resolve_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	reset()
	dt_sum = 0.0
	dt_n = 0


func _adapt() -> void:
	if not auto_n:
		return
	dt_sum += get_process_delta_time()
	dt_n += 1
	if dt_sum < 1.5:
		return
	var avg := dt_sum/dt_n
	dt_sum = 0.0
	dt_n = 0
	var want := n
	if avg > SLOW and n < N_MAX:
		want = n + 1
	elif avg < FAST and n > 1:
		want = n - 1
	if want != n:
		n = want
		changes += 1
		resize(full)
		if main.diag:
			main.diag.note("分幀累積改為 %d×%d（平均每幀 %.1f ms）" % [n, n, avg*1000.0])


## After the frame: keep this frame's full picture for the next one (a GPU copy, about 45 MB on the iPad).
func _after_draw() -> void:
	if not drawn:
		return
	drawn = false
	var rd := RenderingServer.get_rendering_device()
	var src := RenderingServer.texture_get_rd_texture(resolve_vp.get_texture().get_rid())
	if rd == null or not src.is_valid():
		return
	if not hist_rid.is_valid() or hist_tex == null or hist_tex.get_width() != full.x or hist_tex.get_height() != full.y:
		if hist_rid.is_valid():
			rd.free_rid(hist_rid)
		var fmt: RDTextureFormat = rd.texture_get_format(src)
		var mine := RDTextureFormat.new()
		mine.format = fmt.format
		mine.width = fmt.width
		mine.height = fmt.height
		mine.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		hist_rid = rd.texture_create(mine, RDTextureView.new())
		hist_tex = Texture2DRD.new()
		hist_tex.texture_rd_rid = hist_rid
		resolve_mat.set_shader_parameter("tHist", hist_tex)
		hist_ok = false
		if fmt.width != full.x or fmt.height != full.y:
			return
	var dst := hist_rid
	var size := Vector3(full.x, full.y, 1)
	RenderingServer.call_on_render_thread(func():
		RenderingServer.get_rendering_device().texture_copy(src, dst, Vector3.ZERO, Vector3.ZERO, size, 0, 0, 0, 0))
	hist_ok = true
