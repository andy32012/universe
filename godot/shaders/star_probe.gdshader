// How much of each star's light the galaxies' gas and dust hide (the web's probes, PROBE in index.html): one texel
// a star, the whole opacity along the line from you to it, as the web's composite dims everything behind its
// clouds. It depends only on where you are, so it is drawn again only when you move (main.gd); the stars read it.
shader_type canvas_item;
render_mode blend_disabled;

#include "res://shaders/galaxy_common.gdshaderinc"

uniform sampler2D uStarPos : filter_nearest, repeat_disable;   // each star's position, light-years
uniform vec3 uP;                 // where you are, light-years
uniform int uStarCount = 0;

void fragment(){
	ivec2 xy = ivec2(floor(FRAGCOORD.xy));
	int w = textureSize(uStarPos, 0).x;
	int i = xy.y*w + xy.x;
	if(i >= uStarCount){
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec3 dir = normalize(texelFetch(uStarPos, xy, 0).xyz - uP);
		float a = galaxies(dir, 0.5).a;
		COLOR = vec4(a, a, a, 1.0);
	}
}
