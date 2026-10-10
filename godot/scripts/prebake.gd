## Prebakes the panoramas of home and every wormhole destination, for shipping in the app (panorama.gd reads them).
## Run with the GPU (not headless):  godot --path godot -- --prebake=prebaked [--panosize=4608]
## Each place is baked by the game itself with the very sky shader it uses on the iPad, at the iPad's face size,
## then compressed to ASTC 4x4 HDR (indistinguishable after the tone curve: mean 0.05 levels, max 2.7, measured on
## the home panorama) and written as godot/prebaked/<id>/face0..5.astc with an index.
extends Node

var main: Node
var out_dir := ""
var places := []
var i := -1
var index := []
var waiting := false
var t0 := 0


func start(dir: String) -> void:
	out_dir = ProjectSettings.globalize_path(dir) if dir.begins_with("res://") else dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	places = main.wormhole.destinations()
	main.panorama.use_prebaked = false
	if main.panorama.size_override <= 0:
		main.panorama.size_override = 4608            # the iPad Pro M5's face size (2064-pixel-high picture, 50°)
		main.panorama.on_resize()
	t0 = Time.get_ticks_msec()
	_next()


func _next() -> void:
	i += 1
	if i >= places.size():
		var f := FileAccess.open(out_dir.path_join("index.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify(index, " "))
		f.close()
		main.diag.note("預先烘焙完成：%d 個地點，%.0f 秒" % [index.size(), (Time.get_ticks_msec() - t0)/1000.0])
		get_tree().quit()
		return
	var d: Dictionary = places[i]
	main.P = d.p.duplicate()
	main._face_to(d.face)
	main.tele = 1.0
	main.tele_t = 1.0
	main.panorama.urgent = true
	waiting = true
	main.diag.note("預先烘焙 %d/%d：%s" % [i + 1, places.size(), d.name])


func _process(_delta: float) -> void:
	if not waiting:
		return
	var pano = main.panorama
	if pano.urgent or not pano.have or pano.bake_face >= 0:
		return
	waiting = false
	# the bake's copy into the cube finishes with this frame
	await RenderingServer.frame_post_draw
	_save(places[i])
	_next()


func _save(d: Dictionary) -> void:
	var pano = main.panorama
	var rd := RenderingServer.get_rendering_device()
	var dir: String = out_dir.path_join(d.id)
	DirAccess.make_dir_recursive_absolute(dir)
	var bytes_total := 0
	for face in 6:
		var img := Image.create_from_data(pano.size, pano.size, false, Image.FORMAT_RGBAH, rd.texture_get_data(pano.cube_rid, face))
		img.compress(Image.COMPRESS_ASTC, Image.COMPRESS_SOURCE_GENERIC, Image.ASTC_FORMAT_4x4)
		var data := img.get_data()
		bytes_total += data.size()
		var f := FileAccess.open(dir.path_join("face%d.astc" % face), FileAccess.WRITE)
		f.store_buffer(data)
		f.close()
	var gals := []
	for g in pano.state.gals:
		gals.append([int(g[0]), float(g[1]), float(g[2])])
	index.append({id = d.id, name = d.name, p = [d.p[0], d.p[1], d.p[2]], size = pano.size, gals = gals})
	main.diag.note("  已存 %s：%.0f MB" % [d.id, bytes_total/1048576.0])
