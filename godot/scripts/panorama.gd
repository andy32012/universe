## The galaxies baked into a panorama (a cube map), so that while you stay put the sky costs one texture read
## a pixel instead of a 96-step march through every galaxy (handoff: "銀河系在載入時烘焙成 360 度全景圖").
##
## The six faces are drawn by the very same sky shader as the live view, through a square 90-degree camera,
## and copied on the GPU into a cube texture. The panorama is used only while it is indistinguishable from the
## live picture:
##  - you are within MOVE_LIMIT light-years of where it was baked (the nearest gas structure is hundreds of
##    light-years across, so the change is far below one display level),
##  - the galaxies, their fade and their glow are what they were at the bake,
##  - its texels are no coarser than the picture's pixels (the telescope at more than a little zoom goes live).
## When you stop somewhere new for a moment, it is baked again in the background, one tile per frame, and used
## when complete. The old one is freed when that bake starts (it no longer applies there), so at most one is ever held;
## on an iOS memory warning the panorama is given back for the rest of the run. Its memory use is in the log.
extends Node

var main: Node

const MOVE_LIMIT := 0.5          # light-years
const SETTLE := 0.75             # seconds still before a new bake starts
const TILE_MAX := 1280           # largest tile side, in texels
# The cube's face convention (+X, -X, +Y, -Y, +Z, -Z; u, v as in Vulkan/Metal) is a mirror image of what a
# camera sees. One reflection fixes all six faces: each face is shot as if z were flipped (look, up below),
# and the sky looks the panorama up with z flipped (galaxy_sky.gdshader).
const FACES := [
	[Vector3(1, 0, 0), Vector3(0, 1, 0)], [Vector3(-1, 0, 0), Vector3(0, 1, 0)],
	[Vector3(0, 1, 0), Vector3(0, 0, 1)], [Vector3(0, -1, 0), Vector3(0, 0, -1)],
	[Vector3(0, 0, -1), Vector3(0, 1, 0)], [Vector3(0, 0, 1), Vector3(0, 1, 0)]]

var enabled := true
var size := 0                    # face size in texels
var have := false                # a complete panorama is in use
var cube_rid := RID()            # the cube in use
var cube_tex: TextureCubemapRD
var bake_rid := RID()            # the cube being baked
var bake_face := -1
var bake_tile := 0
var tiles := 1
var tile := 0
var bake_state := {}             # P and galaxy state of the bake in progress
var state := {}                  # ... of the panorama in use
var vp: SubViewport
var cam: Camera3D
var mat: ShaderMaterial
var still_time := 0.0
var last_p := PackedFloat64Array([INF, INF, INF])
var bakes := 0
var bake_ms := 0.0
var bake_t0 := 0


func _ready() -> void:
	enabled = bool(main.settings.get_value("render", "panorama", true))
	# baked on the rendering device; without one (headless, or a renderer without it) the sky stays live
	if RenderingServer.get_rendering_device() == null:
		enabled = false


func on_resize() -> void:
	# texels no coarser than the 3D picture's pixels at the middle of a face, at 1x
	var h: float = main.render_size.y*main.world_vp.scaling_3d_scale
	var n := int(ceil(h/main.TAN0/256.0))*256
	if n != size:
		size = n
		_release()
		_cancel_bake()


## Lets go of the panorama in use. The sky stops sampling it first, so nothing draws from freed memory.
func _release() -> void:
	main.sky_mat.set_shader_parameter("uPanoOn", 0.0)
	main.sky_mat.set_shader_parameter("uPano", null)
	cube_tex = null
	_drop(cube_rid)
	cube_rid = RID()
	have = false
	state = {}


## iOS warns before it closes an app for using too much memory: give the panorama back and stop baking for
## this run; the sky is then drawn live, as it is everywhere the panorama does not apply.
func _notification(what: int) -> void:
	if what == NOTIFICATION_OS_MEMORY_WARNING and (enabled or have or bake_face >= 0):
		_cancel_bake()
		_release()
		enabled = false
		if vp:
			vp.size = Vector2i(4, 4)
		if main.diag:
			main.diag.note("記憶體警告：放掉全景圖（%.0f MB），這次執行改為即時計算" % (memory_bytes()/1048576.0))


func memory_bytes() -> int:
	return size*size*6*8


func status() -> String:
	if not enabled:
		return "全景圖：關"
	var mb := memory_bytes()/1048576.0
	var s := "全景圖 %d×%d×6（%.0f MB）%s" % [size, size, mb, "使用中" if use_now else ("就緒" if have else "未就緒")]
	if bakes > 0:
		s += "，已烘焙 %d 次，上次 %.0f ms" % [bakes, bake_ms]
	return s


var use_now := false


## Called by main each frame: whether the sky should read the panorama this frame.
func use_for_frame() -> bool:
	use_now = false
	if not enabled or size == 0:
		return false
	var cur := _current_state()
	_maybe_bake(cur)
	if have and _matches(state, cur) and main.tele <= _tele_limit():
		use_now = true
	return use_now


func _tele_limit() -> float:
	var h: float = main.render_size.y*main.world_vp.scaling_3d_scale
	return size*main.TAN0/h


func _current_state() -> Dictionary:
	var list: Array = main.active_galaxies(main.TAN0/main.tele, false)
	var g := []
	for e in list:
		g.append([main.gal_state.find(e.g), e.alpha, e.gain])
	return {p = main.P.duplicate(), gals = g, list = list}


func _matches(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty():
		return false
	var dx: float = a.p[0] - b.p[0]
	var dy: float = a.p[1] - b.p[1]
	var dz: float = a.p[2] - b.p[2]
	if dx*dx + dy*dy + dz*dz > MOVE_LIMIT*MOVE_LIMIT:
		return false
	if a.gals.size() != b.gals.size():
		return false
	for i in a.gals.size():
		var x: Array = a.gals[i]
		var y: Array = b.gals[i]
		if x[0] != y[0] or absf(x[1] - y[1]) > 0.002 or absf(x[2] - y[2]) > 0.002:
			return false
	return true


func _maybe_bake(cur: Dictionary) -> void:
	var dt := get_process_delta_time()
	var moved := false
	for k in 3:
		if cur.p[k] != last_p[k]:
			moved = true
	last_p = cur.p.duplicate()
	still_time = 0.0 if moved else still_time + dt
	if bake_face >= 0:
		# a bake in progress is abandoned if you leave its place
		if not _matches(bake_state, cur):
			_cancel_bake()
		return
	if cur.gals.is_empty() or (have and _matches(state, cur)):
		return
	if still_time < SETTLE and have:
		return
	_start_bake(cur)


func _start_bake(cur: Dictionary) -> void:
	if vp == null:
		_make_viewport()
	# each face is drawn in tiles, a tile a frame, so a bake never adds more than about one live frame's work
	tiles = 1
	while size/tiles > TILE_MAX or size % tiles != 0:
		tiles += 1
	tile = size/tiles
	vp.size = Vector2i(tile, tile)
	var u: Dictionary = main.galaxy_uniforms(cur.list)
	u.uSamples = main.GAL_SAMPLES
	main.apply_uniforms(mat, u)
	mat.set_shader_parameter("uPanoOn", 0.0)
	mat.set_shader_parameter("uFragH", float(tile))
	# A bake starts only when the panorama in use no longer applies where you are; free it first so that at most one
	# panorama (about 970 MB on the iPad) is ever held, never two.
	_release()
	bake_state = cur
	bake_face = 0
	bake_tile = 0
	bake_t0 = Time.get_ticks_msec()
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size
	fmt.height = size
	fmt.array_layers = 6
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	bake_rid = RenderingServer.get_rendering_device().texture_create(fmt, RDTextureView.new())
	if main.diag:
		main.diag.note("開始烘焙全景圖：顯示記憶體 %.0f MB（貼圖 %.0f）" % [Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576.0,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)/1048576.0])
	_render_tile()


func _make_viewport() -> void:
	vp = SubViewport.new()
	vp.name = "Panorama"
	vp.use_hdr_2d = true
	vp.world_3d = World3D.new()
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	vp.positional_shadow_atlas_size = 0
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_FRUSTUM
	cam.near = 0.01
	cam.far = 10.0
	mat = main.sky_mat.duplicate()
	var sky := Sky.new()
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	var env: Environment = main._environment()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	cam.environment = env
	vp.add_child(cam)
	add_child(vp)


## one tile of one face: a 90-degree square view split tiles x tiles, as an off-centre frustum
func _render_tile() -> void:
	var f: Array = FACES[bake_face]
	cam.transform = Transform3D(Basis.looking_at(f[0], f[1]), Vector3.ZERO)
	var i := bake_tile % tiles
	var j := bake_tile/tiles
	var n := cam.near
	cam.size = 2.0*n/tiles
	cam.frustum_offset = Vector2(n*(-1.0 + (2.0*i + 1.0)/tiles), n*(1.0 - (2.0*j + 1.0)/tiles))
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(_tile_drawn, CONNECT_ONE_SHOT)


func _tile_drawn() -> void:
	if bake_face < 0:
		return
	var face := bake_face
	var src := RenderingServer.texture_get_rd_texture(vp.get_texture().get_rid())
	var dst := bake_rid
	var ts := tile
	var to := Vector3((bake_tile % tiles)*ts, (bake_tile/tiles)*ts, 0)
	RenderingServer.call_on_render_thread(func():
		RenderingServer.get_rendering_device().texture_copy(src, dst, Vector3.ZERO, to, Vector3(ts, ts, 1), 0, 0, 0, face))
	bake_tile += 1
	if bake_tile == tiles*tiles:
		bake_tile = 0
		bake_face += 1
	if bake_face < 6:
		_render_tile()
		return
	# complete: put it in use
	cube_rid = bake_rid
	bake_rid = RID()
	bake_face = -1
	state = bake_state
	bake_state = {}
	cube_tex = TextureCubemapRD.new()
	cube_tex.texture_rd_rid = cube_rid
	main.sky_mat.set_shader_parameter("uPano", cube_tex)
	have = true
	bakes += 1
	bake_ms = Time.get_ticks_msec() - bake_t0
	if main.diag:
		main.diag.note("全景圖烘焙完成：%d×%d×6，%d×%d 塊，%.0f MB，%.0f ms" % [size, size, tiles, tiles, memory_bytes()/1048576.0, bake_ms])

func _cancel_bake() -> void:
	if bake_face >= 0:
		bake_face = -1
		_drop(bake_rid)
		bake_rid = RID()
		bake_state = {}


func _drop(rid: RID) -> void:
	if rid.is_valid():
		var r := rid
		RenderingServer.call_on_render_thread(func(): RenderingServer.get_rendering_device().free_rid(r))
