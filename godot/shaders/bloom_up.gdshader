// One step up the glow chain: upMat of the web version.
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D tA : filter_linear, repeat_disable;
uniform sampler2D tB : filter_linear, repeat_disable;
uniform vec2 uPx;

void fragment(){
	vec3 b = texture(tB, UV + uPx*vec2(0.5, 0.5)).rgb + texture(tB, UV + uPx*vec2(-0.5, 0.5)).rgb
		+ texture(tB, UV + uPx*vec2(0.5, -0.5)).rgb + texture(tB, UV + uPx*vec2(-0.5, -0.5)).rgb;
	COLOR = vec4(texture(tA, UV).rgb + b*0.25, 1.0);
}
