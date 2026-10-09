// The full-resolution live sky from this frame's 1/N² of the pixels (galaxy_march) and the last full picture
// (accum.gd). A pixel computed this frame is taken as is. Any other is looked up where its direction was in the
// last picture (the galaxies are far enough away that a turn of the view moves them as a whole); while you fly,
// that value is held within the range of this frame's nearby samples, so nothing smears. Standing still, every
// pixel is recomputed once every N² frames and the picture becomes the full-resolution one exactly.
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D tCur : filter_nearest, repeat_disable;
uniform sampler2D tHist : filter_linear, repeat_disable;
uniform vec2 uFull = vec2(1.0);
uniform vec2 uLow = vec2(1.0);
uniform int uN = 1;
uniform ivec2 uOffset;
uniform vec3 uRight;
uniform vec3 uUp;
uniform vec3 uFwd;
uniform float uTanF = 0.4663;
uniform float uAspect = 1.0;
uniform vec3 uPRight;             // the last picture's view
uniform vec3 uPUp;
uniform vec3 uPFwd;
uniform float uPTanF = 0.4663;
uniform float uHistOk = 0.0;      // 0 right after a reset: there is no last picture yet
uniform float uClamp = 0.0;       // 1 while you move through space or the galaxies' fade changes

vec3 cur_at(ivec2 m){
	return texelFetch(tCur, clamp(m, ivec2(0), ivec2(uLow) - 1), 0).rgb;
}

void fragment(){
	ivec2 p = ivec2(floor(FRAGCOORD.xy));
	ivec2 b = p - (p/uN)*uN;
	if(b == uOffset){
		COLOR = vec4(cur_at(p/uN), 1.0);
	} else {
		vec2 f = vec2(p) + 0.5;
		// this frame's samples round the pixel (sample m stands at full-resolution pixel m*N + offset)
		vec2 q = (f - (vec2(uOffset) + 0.5))/float(uN);
		ivec2 q0 = ivec2(floor(q));
		vec2 w = q - vec2(q0);
		vec3 c00 = cur_at(q0), c10 = cur_at(q0 + ivec2(1, 0)), c01 = cur_at(q0 + ivec2(0, 1)), c11 = cur_at(q0 + ivec2(1, 1));
		vec3 col = mix(mix(c00, c10, w.x), mix(c01, c11, w.x), w.y);
		if(uHistOk > 0.5){
			vec2 ndc = vec2(f.x/uFull.x*2.0 - 1.0, 1.0 - f.y/uFull.y*2.0);
			vec3 rd = normalize(uFwd + uRight*(ndc.x*uAspect*uTanF) + uUp*(ndc.y*uTanF));
			float z = dot(rd, uPFwd);
			if(z > 0.0){
				vec2 pn = vec2(dot(rd, uPRight)/(z*uAspect*uPTanF), dot(rd, uPUp)/(z*uPTanF));
				vec2 uv = vec2(pn.x*0.5 + 0.5, 0.5 - pn.y*0.5);
				if(uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0){
					vec3 h = texture(tHist, uv).rgb;
					if(uClamp > 0.5){
						h = clamp(h, min(min(c00, c10), min(c01, c11)), max(max(c00, c10), max(c01, c11)));
					}
					col = h;
				}
			}
		}
		COLOR = vec4(col, 1.0);
	}
}
