## The App Store icon needs 1024x1024; this makes it from the repository's 512 icon:
##   godot --headless --path godot --script res://tools/make_icon.gd
extends SceneTree


func _init() -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path("res://icon.png"))
	img.resize(1024, 1024, Image.INTERPOLATE_LANCZOS)
	img.convert(Image.FORMAT_RGB8)      # App Store icons may not have transparency
	img.save_png(ProjectSettings.globalize_path("res://icon_1024.png"))
	quit()
