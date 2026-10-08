// The galaxies, drawn as the sky: every pixel is a direction, as in the web version, and Godot derives the
// sky's motion vectors from the camera's turn, which the temporal upscaler (MetalFX / FSR 2) needs.
shader_type sky;

#include "res://shaders/galaxy_common.gdshaderinc"

// a panorama of the galaxies baked at load time (see panorama.gd), used while you stay near where it was baked
uniform samplerCube uPano : filter_linear;
uniform float uPanoOn = 0.0;
// the height of the picture the sky is drawn at: the web counts pixel rows from the bottom, Godot from the top
uniform float uFragH = 1.0;

void sky(){
	if(AT_CUBEMAP_PASS){
		// nothing in the scene reflects the sky; keep Godot's radiance map black and cheap
		COLOR = vec3(0.0);
	} else if(uPanoOn > 0.5){
		COLOR = texture(uPano, EYEDIR*vec3(1.0, 1.0, -1.0)).rgb;   // z flipped: see panorama.gd
	} else {
		COLOR = galaxies(EYEDIR, web_dither(vec2(FRAGCOORD.x, uFragH - FRAGCOORD.y))).rgb;
	}
}
