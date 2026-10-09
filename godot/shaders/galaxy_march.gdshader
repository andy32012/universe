// The galaxies for one pixel of every N×N block of the picture (the block's pixel uOffset this frame), for the
// accumulated live sky (accum.gd). Each texel follows the ray of its full-resolution pixel, with the web's
// dither for that pixel, so once every pixel has had its turn the picture is the full-resolution one exactly.
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/galaxy_common.gdshaderinc"

uniform vec3 uRight;
uniform vec3 uUp;
uniform vec3 uFwd;
uniform float uTanF = 0.4663;
uniform float uAspect = 1.0;
uniform vec2 uFull = vec2(1.0);   // the full picture, pixels
uniform int uN = 1;
uniform ivec2 uOffset;            // which pixel of each block, this frame

void fragment(){
	ivec2 m = ivec2(floor(FRAGCOORD.xy));
	vec2 f = vec2(m*uN + uOffset) + 0.5;    // the full-resolution pixel's centre, rows counted from the top
	if(f.x > uFull.x || f.y > uFull.y){
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec2 ndc = vec2(f.x/uFull.x*2.0 - 1.0, 1.0 - f.y/uFull.y*2.0);
		vec3 rd = normalize(uFwd + uRight*(ndc.x*uAspect*uTanF) + uUp*(ndc.y*uTanF));
		// the web's dither counts rows from the bottom
		COLOR = vec4(galaxies(rd, web_dither(vec2(f.x, uFull.y - f.y))).rgb, 1.0);
	}
}
