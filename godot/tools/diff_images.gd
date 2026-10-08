## Side-by-side and difference of a web and a Godot picture, with numbers:
##   godot --headless --script tools/diff_images.gd -- web.png godot.png out.png
extends SceneTree


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var web := Image.load_from_file(a[0])
	var gd := Image.load_from_file(a[1])
	web.convert(Image.FORMAT_RGB8)
	gd.convert(Image.FORMAT_RGB8)
	if gd.get_size() != web.get_size():
		gd.resize(web.get_width(), web.get_height(), Image.INTERPOLATE_LANCZOS)
	var w := web.get_width()
	var h := web.get_height()
	var out := Image.create(w*3, h, false, Image.FORMAT_RGB8)
	out.blit_rect(web, Rect2i(0, 0, w, h), Vector2i(0, 0))
	out.blit_rect(gd, Rect2i(0, 0, w, h), Vector2i(w, 0))
	var sum_w := Vector3.ZERO
	var sum_g := Vector3.ZERO
	var sum_d := Vector3.ZERO
	var big := 0
	var mx := 0.0
	for y in h:
		for x in w:
			var cw := web.get_pixel(x, y)
			var cg := gd.get_pixel(x, y)
			var d := Vector3(absf(cw.r - cg.r), absf(cw.g - cg.g), absf(cw.b - cg.b))
			sum_w += Vector3(cw.r, cw.g, cw.b)
			sum_g += Vector3(cg.r, cg.g, cg.b)
			sum_d += d
			var m := maxf(d.x, maxf(d.y, d.z))
			mx = maxf(mx, m)
			if m > 8.0/255.0:
				big += 1
			out.set_pixel(w*2 + x, y, Color(minf(d.x*4, 1), minf(d.y*4, 1), minf(d.z*4, 1)))
	var n := float(w*h)
	print("mean web   RGB ", sum_w/n*255.0)
	print("mean godot RGB ", sum_g/n*255.0)
	print("mean |diff| RGB ", sum_d/n*255.0, "  max ", roundi(mx*255))
	print("pixels off by >8 levels: %.2f%%" % (100.0*big/n))
	out.resize(w*3/2, h/2, Image.INTERPOLATE_LANCZOS)
	out.save_png(a[2])
	quit()
