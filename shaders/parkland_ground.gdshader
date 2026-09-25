shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always;
// 2026-09-24: alpha-blended fade into the real room over a wide angle (mr_split_fade) instead of a 20 cm dithered
// edge, which from 0.2-0.5 m beside the head read as a hard line sliding over the room. Drawn after the sky dome and
// before the green (render_priority set in parkland.gd).
// Ground around the green (scripts/environment/parkland.gd): first cut with mowing stripes right around the green,
// then rough with clumpy colour variation, then haze. The MR split hides it on the room side.
// 2026-09-24: lit and hazed per vertex, one noise per vertex, no per-pixel noise (it was a big part of the frame).
#include "res://shaders/include/split_mr.gdshaderinc"

uniform vec3 cut_color : source_color = vec3(0.21, 0.36, 0.14);
uniform vec3 rough_color : source_color = vec3(0.17, 0.27, 0.10);
uniform vec3 dry_color : source_color = vec3(0.34, 0.38, 0.16);
uniform float stripe_width = 1.6;
uniform bool is_hills = false;

varying vec3 v_world_pos;
varying vec3 v_local;
varying vec3 v_light;
varying float v_haze;
varying float v_n1;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_local = VERTEX;
	v_light = mr_vertex_light((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_haze = mr_haze_amount(v_world_pos, CAMERA_POSITION_WORLD);
	v_n1 = vnoise(VERTEX.xz * 0.35);
}

void fragment() {
	float a = mr_split_fade(v_world_pos, CAMERA_POSITION_WORLD);
	if (a <= 0.0) {
		discard; // room side: no colour and no depth
	}
	// COLOR.r = distance outside the green (m) / 10, from parkland.gd
	float d_out = COLOR.r * 10.0;
	vec3 rough = mix(rough_color, dry_color, smoothstep(0.55, 0.95, v_n1) * 0.55);
	float stripes = step(0.5, fract(v_local.x / stripe_width)) * 0.06 - 0.03;
	vec3 cut = cut_color * (1.0 + stripes);
	float cut_mix = 1.0 - smoothstep(2.2, 3.4, d_out);
	vec3 c = is_hills ? mix(vec3(0.20, 0.30, 0.16), vec3(0.14, 0.22, 0.12), v_n1) : mix(rough, cut, cut_mix);
	ALBEDO = mix(c * v_light, haze_color, v_haze);
	ALPHA = a;
}
