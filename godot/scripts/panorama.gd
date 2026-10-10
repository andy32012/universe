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
const TILE_MAX := 1280           # largest tile side, in texels, while you fly (a tile costs about a live frame)
const TILE_MAX_FIRST := 2304     # at start-up nothing else is drawn, so larger tiles: fewer frames
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
var bake_face := -1              # step of the bake in progress (0..5; the face is face_order[bake_face])
var face_order := [0, 1, 2, 3, 4, 5]
var face_ok := PackedFloat32Array([0, 0, 0, 0, 0, 0])   # faces of the bake in progress already complete
var partial := false             # this frame uses a bake in progress: its complete faces, live elsewhere
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
	_load_prebaked_index()


# ---------- prebaked panoramas ----------
# Home and every wormhole destination are baked ahead of time on GitHub's Mac with this same sky shader and
# shipped compressed (ASTC 4x4 HDR: 127 MB on the GPU instead of 972, indistinguishable after the tone curve; see
# tools/prebake.gd). Where one applies, it is loaded instead of baking.
var prebaked := []               # {id, name, p, size, gals}
var use_prebaked := true
var pre_id := ""                 # the prebaked place loaded
var pre_tex: Cubemap
var pre_size := 0
var using_prebaked := false      # this frame reads it


## Where the prebaked panoramas are: next to the app's executable on the iPad (copied into the bundle as separate
## files by the build, because AltServer failed to install them packed into one 1 GB .pck), else in the project.
var prebaked_dir := "res://prebaked"


func _load_prebaked_index() -> void:
	var bundle := OS.get_executable_path().get_base_dir().path_join("prebaked")
	if not OS.has_feature("editor") and FileAccess.file_exists(bundle.path_join("index.json")):
		prebaked_dir = bundle
	var path := prebaked_dir.path_join("index.json")
	if not FileAccess.file_exists(path):
		return
	var list = JSON.parse_string(FileAccess.get_file_as_string(path))
	if list == null:
		return
	for e in list:
		prebaked.append({id = e.id, name = e.name, p = PackedFloat64Array(e.p), size = int(e.size), gals = e.gals})
	if main.diag:
		main.diag.note("預先烘焙的全景圖：%d 個地點（%s）" % [prebaked.size(), prebaked_dir])


func _prebaked_for(cur: Dictionary) -> Dictionary:
	if not use_prebaked:
		return {}
	for e in prebaked:
		if _matches({p = e.p, gals = e.gals}, cur):
			return e
	return {}


func _load_prebaked(e: Dictionary) -> bool:
	var t0 := Time.get_ticks_msec()
	var images: Array[Image] = []
	for face in 6:
		var bytes := FileAccess.get_file_as_bytes(prebaked_dir.path_join("%s/face%d.astc" % [e.id, face]))
		if bytes.is_empty():
			return false
		images.append(Image.create_from_data(e.size, e.size, false, Image.FORMAT_ASTC_4x4_HDR, bytes))
	var cm := Cubemap.new()
	if cm.create_from_images(images) != OK:
		return false
	pre_tex = cm
	pre_id = e.id
	pre_size = e.size
	if main.diag:
		main.diag.note("載入預先烘焙的全景圖：%s（%d×%d×6，%.0f ms）" % [e.name, e.size, e.size, Time.get_ticks_msec() - t0])
	return true


func on_resize() -> void:
	# texels no coarser than the 3D picture's pixels at the middle of a face, at 1x
	var h: float = main.render_size.y*main.world_vp.scaling_3d_scale
	var n := int(ceil(h/main.TAN0/256.0))*256
	if size_override > 0:
		n = size_override
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


## The first bake, at start-up: the sky waits for it rather than share the GPU with it.
func _leave_prebaked() -> void:
	if using_prebaked:
		using_prebaked = false
		main.sky_mat.set_shader_parameter("uPano", cube_tex)    # (the last prebaked cube stays loaded for a return)


func first_bake() -> bool:
	return enabled and size > 0 and not using_prebaked and (bakes == 0 or urgent) and (bake_face >= 0 or not have or urgent)


func progress() -> float:
	if bake_face < 0:
		return 0.0
	var done := bake_face*tiles*tiles + bake_tile
	return done*1.0/(6*tiles*tiles)


func memory_bytes() -> int:
	return size*size*6*8


func status() -> String:
	if not enabled:
		return "全景圖：關"
	if using_prebaked:
		return "全景圖：預先烘焙的 %s（%d×%d×6，ASTC，%.0f MB）使用中" % [pre_id, pre_size, pre_size, pre_size*pre_size*6/1048576.0]
	var mb := memory_bytes()/1048576.0
	var s := "全景圖 %d×%d×6（%.0f MB）%s" % [size, size, mb, "使用中" if use_now else ("就緒" if have else "未就緒")]
	if bakes > 0:
		s += "，已烘焙 %d 次，上次 %.0f ms" % [bakes, bake_ms]
	return s


var use_now := false
var urgent := false               # a wormhole arrival: bake here now, with the whole GPU (wormhole.gd)
var hold_after := -1              # test hook only
var save_dir := ""                # tool: save the next completed panorama's faces here
var size_override := 0            # tool: bake at this face size (the iPad's is 4608)
signal saved


## Called by main each frame: whether the sky should read the panorama this frame.
func use_for_frame() -> bool:
	use_now = false
	partial = false
	if not enabled or size == 0:
		_leave_prebaked()
		return false
	var cur := _current_state()
	var pre := _prebaked_for(cur)
	if not pre.is_empty() and (pre_id == pre.id or _load_prebaked(pre)):
		# a prebaked place: nothing to bake here, and the device's own cube (972 MB) is given back
		urgent = false
		if bake_face >= 0:
			_cancel_bake()
		if have:
			_release()
		using_prebaked = true
		main.sky_mat.set_shader_parameter("uPano", pre_tex)
		var h: float = main.render_size.y*main.world_vp.scaling_3d_scale
		use_now = main.tele <= pre_size*main.TAN0/h
		return use_now
	_leave_prebaked()
	_maybe_bake(cur)
	if main.tele > _tele_limit():
		return false
	if have and _matches(state, cur):
		use_now = true
	elif bake_face >= 0 and bakes > 0 and _matches(bake_state, cur) and face_ok.has(1.0):
		# a bake in progress for this very place: its complete faces are already exact
		use_now = true
		partial = true
	return use_now


## Which faces the sky may read: all of a complete panorama, the finished ones of a bake in progress.
func face_mask() -> Array:
	if not partial:
		return [Vector3.ONE, Vector3.ONE]
	return [Vector3(face_ok[0], face_ok[1], face_ok[2]), Vector3(face_ok[3], face_ok[4], face_ok[5])]


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
	if urgent:
		if bake_face >= 0:
			if not _matches(bake_state, cur):
				_cancel_bake()
				_start_bake(cur)
		elif have and _matches(state, cur):
			urgent = false
		else:
			_start_bake(cur)
		return
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
	# whole faces where they fit: a bake mostly runs while you stand still, when nothing else is drawn (main.gd)
	var most := TILE_MAX_FIRST
	while size/tiles > most or size % tiles != 0:
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
	# the faces you are looking at first, so that what you see becomes the panorama soonest
	var fwd: Vector3 = -main.camera.transform.basis.z
	face_order = [0, 1, 2, 3, 4, 5]
	face_order.sort_custom(func(a, b): return FACES[a][0].dot(fwd) > FACES[b][0].dot(fwd))
	face_ok = PackedFloat32Array([0, 0, 0, 0, 0, 0])
	bake_t0 = Time.get_ticks_msec()
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size
	fmt.height = size
	fmt.array_layers = 6
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	bake_rid = RenderingServer.get_rendering_device().texture_create(fmt, RDTextureView.new())
	if main.diag:
		main.diag.note("開始烘焙全景圖：顯示記憶體 %.0f MB（貼圖 %.0f）" % [Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576.0,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)/1048576.0])
	# the cube is shown face by face as they complete (see use_for_frame)
	cube_tex = TextureCubemapRD.new()
	cube_tex.texture_rd_rid = bake_rid
	main.sky_mat.set_shader_parameter("uPano", cube_tex)
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
	var f: Array = FACES[face_order[bake_face]]
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
	var face: int = face_order[bake_face]
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
		face_ok[face] = 1.0
	if bake_face < 6:
		if hold_after >= 0 and bakes > 0 and bake_face >= hold_after:
			return                        # test hook: leave this bake half done (--holdbake=K)
		_render_tile()
		return
	# complete: put it in use
	cube_rid = bake_rid
	bake_rid = RID()
	bake_face = -1
	state = bake_state
	bake_state = {}
	have = true
	bakes += 1
	urgent = false
	bake_ms = Time.get_ticks_msec() - bake_t0
	vp.size = Vector2i(4, 4)          # the tile-sized picture (up to 2304² on the iPad) is not needed until the next bake
	if main.diag:
		main.diag.note("全景圖烘焙完成：%d×%d×6，%d×%d 塊，%.0f MB，%.0f ms" % [size, size, tiles, tiles, memory_bytes()/1048576.0, bake_ms])
	if save_dir != "":
		RenderingServer.frame_post_draw.connect(_save_faces, CONNECT_ONE_SHOT)


## Tool: the six faces of the panorama in use, as half-float EXR files (for prebaking; --savepano=dir).
func _save_faces() -> void:
	var rd := RenderingServer.get_rendering_device()
	for face in 6:
		var bytes := rd.texture_get_data(cube_rid, face)
		var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBAH, bytes)
		img.save_exr(save_dir.path_join("face%d.exr" % face), false)
	if main.diag:
		main.diag.note("全景圖六面已存到 " + save_dir)
	saved.emit()

func _cancel_bake() -> void:
	if bake_face >= 0:
		bake_face = -1
		partial = false
		# the sky may be reading its finished faces: stop that before the cube goes
		main.sky_mat.set_shader_parameter("uPanoOn", 0.0)
		main.sky_mat.set_shader_parameter("uPano", null)
		cube_tex = null
		_drop(bake_rid)
		bake_rid = RID()
		bake_state = {}


func _drop(rid: RID) -> void:
	if rid.is_valid():
		var r := rid
		RenderingServer.call_on_render_thread(func(): RenderingServer.get_rendering_device().free_rid(r))
