## The on-screen flight controls: the left pad that turns your view, and the round fly buttons. They are only
## drawn here; main.gd routes touches and the mouse to them, so several fingers can act at once.
class_name TouchPad
extends Control

enum Kind { STICK, BUTTON }

var kind := Kind.BUTTON
var text := ""
var gold := false
var pressed := false
var knob := Vector2.ZERO          # stick: -1..1 each way

const INK := Color(0.933, 0.941, 0.965)
const GOLD := Color(0.953, 0.851, 0.635)


func _init(k: Kind, t := "", is_gold := false) -> void:
	kind = k
	text = t
	gold = is_gold
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var c := size*0.5
	var r := minf(size.x, size.y)*0.5
	if kind == Kind.STICK:
		draw_circle(c, r, Color(0.047, 0.063, 0.094, 0.25))
		draw_arc(c, r - 0.5, 0, TAU, 64, Color(INK, 0.16), 1.0, true)
		draw_arc(c, r - 14, 0, TAU, 64, Color(INK, 0.10), 1.0, true)
		draw_circle(c + knob*r*0.55, r*0.30, Color(INK, 0.22))
	else:
		var edge := Color(GOLD, 0.35) if gold else Color(INK, 0.18)
		draw_circle(c, r, Color(0.04, 0.055, 0.086, 0.55 if pressed else 0.35))
		draw_arc(c, r - 0.5, 0, TAU, 64, edge, 1.5 if pressed else 1.0, true)
		var font := get_theme_default_font()
		var fs := 14 if gold else 12
		var col := GOLD if gold else Color(INK, 0.72)
		draw_string(font, Vector2(0, c.y + fs*0.35), text, HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, col)


func set_knob(v: Vector2) -> void:
	knob = v
	queue_redraw()


func set_pressed(p: bool) -> void:
	pressed = p
	queue_redraw()
