## The data the web version generates at start-up, exported by tools/export_web_data.py so the Godot
## universe is the very same one: point clouds, landmarks, labels, nebula sites, galaxies, baked noise.
class_name UniverseData
extends RefCounted

var clouds: Array = []      # {n, pos:PackedFloat32Array, col, siz, a, b, c, d, grow, probe, frame}
var marks: Array = []       # {name, w:PackedFloat64Array(3), r0, cls}
var labels: Array = []      # {text, sub, w, rv, rmin, home}
var sites: Array = []
var galaxies: Array = []    # {w, R, M:PackedFloat64Array(9) column-major, o}
var noise: ImageTexture3D

const DIR := "res://data/"


func load_all() -> bool:
	var meta = JSON.parse_string(FileAccess.get_file_as_string(DIR + "clouds.json"))
	var scene = JSON.parse_string(FileAccess.get_file_as_string(DIR + "scene.json"))
	if meta == null or scene == null:
		push_error("universe data missing: run godot/tools/export_web_data.py")
		return false
	for m in meta:
		var c := _cloud(m)
		if c.is_empty():
			return false
		clouds.append(c)
	for m in scene.marks:
		marks.append({name = m.name, w = _v(m.w), r0 = float(m.r0), cls = m.get("cls", "")})
	for l in scene.labels:
		labels.append({text = l.text, sub = l.sub, w = _v(l.w), rv = float(l.rv), rmin = float(l.rmin), home = bool(l.home)})
	for s in scene.sites:
		s.w = _v(s.w)
		sites.append(s)
	for g in scene.galaxies:
		galaxies.append({w = _v(g.w), R = float(g.R), M = PackedFloat64Array(g.M), o = g.o})
	noise = _noise(DIR + "noise_rg8_96.bin", 96)
	return noise != null


static func _v(a) -> PackedFloat64Array:
	return PackedFloat64Array([float(a[0]), float(a[1]), float(a[2])])


func _cloud(m: Dictionary) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(DIR + m.file)
	if bytes.size() < 4:
		push_error("missing " + m.file)
		return {}
	var n := bytes.decode_u32(0)
	var f := bytes.slice(4).to_float32_array()
	if f.size() != n*7:
		push_error("bad size " + m.file)
		return {}
	return {n = n, pos = f.slice(0, n*3), col = f.slice(n*3, n*6), siz = f.slice(n*6, n*7),
		a = float(m.a), b = float(m.b), c = float(m.c), d = float(m.d), grow = float(m.grow), probe = bool(m.probe), frame = m.frame}


## two fields of four-octave value noise on a repeating 96^3 grid (genKit.bake), as RG8 like the web's 3D texture
static func _noise(path: String, n: int) -> ImageTexture3D:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != n*n*n*2:
		push_error("noise missing or wrong size")
		return null
	var images: Array[Image] = []
	var slice := n*n*2
	for z in n:
		images.append(Image.create_from_data(n, n, false, Image.FORMAT_RG8, bytes.slice(z*slice, (z + 1)*slice)))
	var t := ImageTexture3D.new()
	t.create(Image.FORMAT_RG8, n, n, n, false, images)
	return t
