// The galaxies, drawn as the sky: every pixel is a direction, as in the web version, and Godot derives the
// sky's motion vectors from the camera's turn, which the temporal upscaler (MetalFX / FSR 2) needs.
shader_type sky;

#include "res://shaders/galaxy_common.gdshaderinc"

// a panorama of the galaxies baked at load time (see panorama.gd), used while you stay near where it was baked
uniform samplerCube uPano : filter_linear;
uniform float uPanoOn = 0.0;
// which of its faces are complete (+X, -X, +Y / -Y, +Z, -Z): while one is being baked, the finished faces are
// read and the rest are computed live
uniform vec3 uFaceOkA = vec3(1.0);
uniform vec3 uFaceOkB = vec3(1.0);
// the height of the picture the sky is drawn at: the web counts pixel rows from the bottom, Godot from the top
uniform float uFragH = 1.0;

void sky(){
	if(AT_CUBEMAP_PASS){
		// nothing in the scene reflects the sky; keep Godot's radiance map black and cheap
		COLOR = vec3(0.0);
	} else {
		vec3 s = EYEDIR*vec3(1.0, 1.0, -1.0);   // the panorama is looked up with z flipped: see panorama.gd
		vec3 a = abs(s);
		float ok;
		if(a.x >= a.y && a.x >= a.z) ok = s.x > 0.0 ? uFaceOkA.x : uFaceOkA.y;
		else if(a.y >= a.z) ok = s.y > 0.0 ? uFaceOkA.z : uFaceOkB.x;
		else ok = s.z > 0.0 ? uFaceOkB.y : uFaceOkB.z;
		if(uPanoOn > 0.5 && ok > 0.5){
			COLOR = texture(uPano, s).rgb;
		} else {
			COLOR = galaxies(EYEDIR, web_dither(vec2(FRAGCOORD.x, uFragH - FRAGCOORD.y))).rgb;
		}
	}
}
