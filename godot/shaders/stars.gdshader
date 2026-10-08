// Points of light: PT_VS / PT_FS of the web version. Each point is dimmed by the galaxies' gas and dust the way
// the web's composite dims everything behind its clouds (by the clouds' whole opacity along that line of sight),
// computed here once per point instead of once per pixel.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/galaxy_common.gdshaderinc"

uniform float uPR = 1.0;     // pixels per CSS pixel, as the web's point sizes are in CSS pixels
uniform float uSz = 1.0;
uniform float uGrow = 2.5;
uniform float uAlpha = 1.0;
uniform float uGain = 1.0;   // STARGAIN
uniform float uDim = 1.0;    // 1: dim by the galaxies in front

varying vec3 vC;
varying float vS;

void vertex(){
	vC = CUSTOM0.rgb;
	vec4 mv = MODELVIEW_MATRIX*vec4(VERTEX, 1.0);
	if(uDim > 0.5 && uCount > 0){
		vec3 dir = normalize((MODEL_MATRIX*vec4(VERTEX, 1.0)).xyz - CAMERA_POSITION_WORLD);
		vC *= 1.0 - galaxies(dir, 0.5).a;
	}
	float sz = CUSTOM0.a*uSz*clamp(0.4/max(-mv.z, 0.001), 1.0, uGrow);
	vS = sz;
	POINT_SIZE = sz*uPR*(sz > 4.0 ? 2.4 : 1.0);
}

void fragment(){
	vec2 c = POINT_COORD - 0.5; float big = step(4.0, vS); c *= mix(1.0, 2.4, big); float d = length(c);
	float a = 1.0 - smoothstep(0.0, 0.5, d); float core = a*a;
	// bright stars get a hot centre, a faint halo and four thin spikes, the way a telescope sees them
	float halo = big*0.10/(d*d*40.0 + 1.0)*(1.0 - smoothstep(0.7, 1.2, d));
	float sp = big*(exp(-abs(c.x)*70.0) + exp(-abs(c.y)*70.0))*exp(-d*4.5)*0.55*smoothstep(4.0, 9.0, vS);
	ALBEDO = vC*(core*(1.0 + 1.6*big) + halo*1.6 + sp*1.5)*uAlpha*uGain;
}
