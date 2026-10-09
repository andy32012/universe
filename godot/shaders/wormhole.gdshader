// Travel by wormhole (wormhole.gd): the picture is pulled into the throat with a twist, then the tunnel - light
// streaming past along its walls - and at the far end the new place opens out. While inside, the destination's
// panorama is baked with the whole GPU, so you arrive in full quality; the tunnel itself is cheap 2D work.
// Everything here is in linear light (HDR 2D), like the picture it is drawn over.
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float uMix = 0.0;      // 0: the picture, 1: the tunnel
uniform float uWarp = 0.0;     // how far the picture is pulled into the throat (0..1)
uniform float uTime = 0.0;
uniform float uAspect = 1.0;
uniform float uSpin = 1.0;     // +1 going in, -1 coming out

float h21(vec2 p){ p = fract(p*vec2(233.34, 851.73)); p += dot(p, p + 23.45); return fract(p.x*p.y); }
float vnoise(vec2 p){
	vec2 i = floor(p), f = fract(p); f = f*f*(3.0 - 2.0*f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
}

void fragment(){
	vec2 c = (SCREEN_UV - 0.5)*vec2(uAspect, 1.0);
	float r = length(c);
	float a = atan(c.y, c.x);

	// the picture, drawn in toward the centre and twisted: stronger near the middle
	float pull = uWarp*(1.0 - smoothstep(0.0, 1.1, r));
	float twist = uSpin*uWarp*3.2*(1.0 - smoothstep(0.0, 0.9, r));
	float rs = r*(1.0 + 2.5*pull);
	vec2 w = vec2(cos(a + twist), sin(a + twist))*rs;
	vec2 uv = w/vec2(uAspect, 1.0) + 0.5;
	vec3 scene = textureLod(SCREEN_TEXTURE, clamp(uv, vec2(0.0), vec2(1.0)), uWarp*3.0).rgb;
	scene *= 1.0 - 0.6*uWarp*smoothstep(0.15, 0.0, r);

	// the tunnel: depth along it is 1/r, so its walls rush past; light in long streaks along them
	float depth = 0.35/max(r, 0.015) + uTime*2.4;
	float ang = a/6.2831853 + 0.5;
	float streak = vnoise(vec2(ang*48.0 + 0.6*depth*uSpin, depth*0.8));
	streak = pow(streak, 6.0)*1.8 + pow(vnoise(vec2(ang*140.0 - 0.3*depth*uSpin, depth*2.6)), 18.0)*3.0;
	float bands = 0.5 + 0.5*sin(depth*3.0 + ang*6.2831853*2.0);
	vec3 wall = mix(vec3(0.10, 0.18, 0.55), vec3(0.55, 0.25, 0.85), bands);
	wall += vec3(0.75, 0.85, 1.0)*streak;
	// fading into the dark distance near the middle, bright where the walls are near
	wall *= smoothstep(0.0, 0.35, r)*(0.35 + 0.65*smoothstep(0.1, 0.9, r));
	// the far mouth: a soft white glow at the centre
	vec3 mouth = vec3(0.9, 0.95, 1.0)*exp(-r*r*55.0)*1.6;
	vec3 tunnel = wall + mouth;

	COLOR = vec4(mix(scene, tunnel, uMix), 1.0);
}
