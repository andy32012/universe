## Build check: is the font the exported game uses able to draw every Chinese character it shows?
## Run against the exported pack (what the iPad gets), with the repository's scripts and data as the text:
##   godot --headless --main-pack Universe.pck --script tools/check_font.gd -- <repo>/godot
## Prints FONTCHECK ok / FONTCHECK missing ... for the workflow to turn into an annotation.
extends SceneTree


func _init() -> void:
	var root: String = OS.get_cmdline_user_args()[0]
	var text := ""
	for dir in ["scripts", "data"]:
		var d := DirAccess.open(root.path_join(dir))
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".gd") or f.ends_with(".json"):
				text += FileAccess.get_file_as_string(root.path_join(dir).path_join(f))
	var font: Font = ThemeDB.fallback_font
	var custom := str(ProjectSettings.get_setting("gui/theme/custom_font", ""))
	var used := {}
	var missing := {}
	for ch in text:
		var c := ch.unicode_at(0)
		if c < 0x2E80 or used.has(c):
			continue
		used[c] = true
		if not font.has_char(c):
			missing[ch] = true
	var bundled := ResourceLoader.exists("res://fonts/DroidSansFallbackFull.woff2")
	if missing.is_empty() and bundled:
		print("FONTCHECK ok: %d Chinese characters, all in the exported font (%s; bundled font in the pack: %s)" % [used.size(), custom, bundled])
	else:
		print("FONTCHECK missing %d of %d (%s; bundled font in the pack: %s): %s" % [missing.size(), used.size(), custom, bundled, "".join(missing.keys()).left(80)])
	quit()
