// The finishing pass: finMat of the web version (glow, film-like tone curve, a little contrast, vignette, grain)
// and its HDR brightening. The web writes this curve's result straight to an sRGB screen; Godot draws 2D in
// linear light (HDR 2D) and encodes for the screen at the end, so the result is decoded from sRGB here and comes
// out on screen exactly as the web's does.
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D tWorld : filter_linear, repeat_disable;
uniform sampler2D tStars : filter_linear, repeat_disable;
uniform sampler2D tBloom : filter_linear, repeat_disable;
uniform float uExpo = 1.3;
uniform float uAspect = 1.0;
uniform vec2 uRes = vec2(1.0);
uniform float uTime = 0.0;
uniform float uHdr = 0.0;          // 1 while the screen shows HDR
uniform float uMaxLinear = 1.0;    // Window.get_output_max_linear_value()
uniform float uEncodedOut = 0.0;   // test screenshots only: write the sRGB values themselves

// HDR float targets, as on the iPad: BLOOM 0.55, OVER0 1.2, OVER1 5.0
const float BLOOM = 0.55;
const float OVER0 = 1.2;
const float OVER1 = 5.0;

float hh(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233)))*43758.5453); }

// sRGB decoding, continued past 1.0 the same way for the HDR range
vec3 srgb_to_linear(vec3 c){
	c = max(c, vec3(0.0));
	return mix(c/12.92, pow((c + 0.055)/1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment(){
	vec2 uv = UV;
	vec3 scene = texture(tWorld, uv).rgb + texture(tStars, uv).rgb;
	vec3 raw = (scene + texture(tBloom, uv).rgb*BLOOM)*uExpo;
	vec3 c = 1.0 - exp(-raw);                          // highlights roll off gently instead of clipping
	c = mix(c, c*c*(3.0 - 2.0*c), 0.18);               // a little contrast
	vec2 q = (vec2(uv.x, 1.0 - uv.y) - 0.5)*vec2(uAspect, 1.0); float vg = 1.0 - 0.30*smoothstep(0.35, 1.05, length(q)); c *= vg;
	c += (hh(uv*uRes + fract(uTime)*91.7) - 0.5)*0.014;
	// how far beyond white this pixel wanted to go: an HDR screen shows it that much brighter
	float over = max(raw.r, max(raw.g, raw.b));
	float boost = clamp((over - OVER0)/OVER1, 0.0, 1.0)*vg;
	vec3 lin;
	if(uHdr > 0.5){
		// web: c*(1 + 1.25 boost)/2.25 into an 8-bit canvas, shown x2.25 on an extended-range sRGB surface
		c = clamp(c, 0.0, 1.0)*(1.0 + boost*1.25);
		lin = min(srgb_to_linear(c), vec3(max(uMaxLinear, 1.0)));
	} else {
		lin = srgb_to_linear(clamp(c, 0.0, 1.0));
	}
	COLOR = uEncodedOut > 0.5 ? vec4(clamp(c, 0.0, 1.0), 1.0) : vec4(lin, 1.0);
}
