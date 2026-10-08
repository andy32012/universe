// One step down the glow chain: downMat of the web version. The first step reads the scene (the galaxies'
// picture and the stars' picture, which the web had already combined) and keeps only what is bright.
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D tSrc : filter_linear, repeat_disable;
uniform sampler2D tSrc2 : filter_linear, repeat_disable;
uniform float uTwo = 0.0;
uniform vec2 uPx;
uniform float uThr = 0.0;

vec3 tap(vec2 uv){
	vec3 c = texture(tSrc, uv).rgb;
	if(uTwo > 0.5) c += texture(tSrc2, uv).rgb;
	return c;
}

void fragment(){
	vec3 c = tap(UV + uPx*vec2(1.0, 1.0)) + tap(UV + uPx*vec2(-1.0, 1.0)) + tap(UV + uPx*vec2(1.0, -1.0)) + tap(UV + uPx*vec2(-1.0, -1.0));
	c *= 0.25;
	if(uThr > 0.0){ float b = max(c.r, max(c.g, c.b)); c *= smoothstep(uThr, uThr + 0.7, b); }
	COLOR = vec4(c, 1.0);
}
