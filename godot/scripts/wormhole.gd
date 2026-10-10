## Travel by wormhole. You pick a place; the view is drawn into the wormhole, and behind the tunnel you are already
## there while its panorama is baked with the whole GPU; the tunnel opens when it is done, so you always arrive
## in full quality. (The loading is the journey: handoff, "蟲洞".)
extends Node

var main: Node

const ENTER := 0.7            # seconds: drawn into the throat
const MIN_INSIDE := 1.2       # at least this long in the tunnel
const EXIT := 0.8             # the far end opening

enum Phase { IDLE, ENTER, INSIDE, EXIT }
var phase := Phase.IDLE
var t := 0.0
var time := 0.0
var dest := {}
var overlay: ColorRect
var mat: ShaderMaterial
var list_panel: PanelContainer
var button: Button


func build(ui: Control) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0                  # over the picture (-1), under the controls (1)
	main.add_child(layer)
	mat = ShaderMaterial.new()
	mat.shader = preload("res://shaders/wormhole.gdshader")
	overlay = main._rect(mat)
	overlay.visible = false
	layer.add_child(overlay)

	button = main._button("蟲洞", func(): list_panel.visible = not list_panel.visible; main.panel.visible = false)
	main._place(button, Control.PRESET_TOP_RIGHT, -176, 24, 72, 36)
	ui.add_child(button)
	list_panel = PanelContainer.new()
	list_panel.visible = false
	list_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	list_panel.offset_left = -360
	list_panel.offset_top = 72
	list_panel.offset_right = -24
	ui.add_child(list_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	list_panel.add_child(box)
	var title := Label.new()
	title.text = "穿越蟲洞到…"
	title.add_theme_font_size_override("font_size", 16)
	box.add_child(title)
	for d in destinations():
		var dd: Dictionary = d
		var b: Button = main._button(dd.name, func(): go(dd))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		box.add_child(b)
	box.add_child(main._button("關閉", func(): list_panel.visible = false))


## Viewpoints for this phase, from the very data the web version generates (galaxy centres and sizes). Their panoramas
## are prebaked into the app (tools/prebake.gd), so arriving at one needs no bake on the device.
func destinations() -> Array:
	var out := []
	var g: Array = main.gal_state
	var earth: Dictionary = main._mark("地球")
	var gc: PackedFloat64Array = g[0].w
	out.append({id = "home", name = "太陽系（家）", p = earth.w if not earth.is_empty() else PackedFloat64Array([0.0, 0.0, 0.0]), face = gc})
	out.append({id = "mw_above", name = "銀河系全貌（從上方）", p = _add(gc, [0.0, 80000.0, 60000.0]), face = gc})
	out.append({id = "mw_edge", name = "銀河系側面", p = _add(gc, [-20000.0, 12000.0, 160000.0]), face = gc})
	# above the disc, closer than the whole view: inside the galaxy's volume the web draws it as a faint band
	out.append({id = "mw_centre", name = "銀河中心（斜看）", p = _add(gc, [0.0, 26000.0, 26000.0]), face = gc})
	var names := ["", "仙女座星系", "三角座星系", "大麥哲倫雲", "小麥哲倫雲"]
	var ids := ["", "m31", "m33", "lmc", "smc"]
	for i in range(1, mini(g.size(), names.size())):
		var e: Dictionary = g[i]
		# a third of the way between face-on and edge-on; the bright irregular clouds from farther out
		var n: Vector3 = e.rows[1]
		var u1: Vector3 = e.rows[0]
		var dir := (n*0.8 + u1*0.6).normalized()
		var k: float = e.R*(4.5 if i >= 3 else 2.6)
		out.append({id = ids[i], name = names[i], p = _add(e.w, [dir.x*k, dir.y*k, dir.z*k]), face = e.w})
	return out


static func _add(w: PackedFloat64Array, d: Array) -> PackedFloat64Array:
	return PackedFloat64Array([w[0] + d[0], w[1] + d[1], w[2] + d[2]])


func active() -> bool:
	return phase != Phase.IDLE


func go(d: Dictionary) -> void:
	if phase != Phase.IDLE:
		return
	list_panel.visible = false
	dest = d
	phase = Phase.ENTER
	t = 0.0
	overlay.visible = true
	if main.diag:
		main.diag.note("蟲洞：前往 " + d.name)


func _process(delta: float) -> void:
	if phase == Phase.IDLE:
		return
	t += delta
	time += delta
	mat.set_shader_parameter("uTime", time)
	mat.set_shader_parameter("uAspect", main.ui.size.x/maxf(main.ui.size.y, 1.0))
	match phase:
		Phase.ENTER:
			var k := clampf(t/ENTER, 0.0, 1.0)
			mat.set_shader_parameter("uSpin", 1.0)
			mat.set_shader_parameter("uWarp", k)
			mat.set_shader_parameter("uMix", k*k)
			if k >= 1.0:
				_arrive_behind_the_tunnel()
				phase = Phase.INSIDE
				t = 0.0
		Phase.INSIDE:
			mat.set_shader_parameter("uMix", 1.0)
			var pano = main.panorama
			var ready: bool = pano == null or not pano.enabled or pano.using_prebaked or (pano.have and not pano.urgent)
			if t >= MIN_INSIDE and ready:
				if main.diag:
					main.diag.note("蟲洞：抵達 %s（隧道 %.1f 秒）" % [dest.name, t])
				phase = Phase.EXIT
				t = 0.0
		Phase.EXIT:
			var k := clampf(t/EXIT, 0.0, 1.0)
			mat.set_shader_parameter("uSpin", -1.0)
			mat.set_shader_parameter("uWarp", 1.0 - k)
			mat.set_shader_parameter("uMix", (1.0 - k)*(1.0 - k))
			if k >= 1.0:
				phase = Phase.IDLE
				overlay.visible = false


## Behind the tunnel: move there, look at it, telescope back to 1x, and have its panorama baked at once.
func _arrive_behind_the_tunnel() -> void:
	main.P = dest.p.duplicate()
	main._face_to(dest.face)
	main.tele = 1.0
	main.tele_t = 1.0
	main._tele_text()
	if main.panorama:
		main.panorama.urgent = true
