shader_type spatial;
render_mode unshaded, cull_disabled; // lit per vertex (2026-09-24, Quest budget)
// Parkland trees (scripts/environment/parkland.gd): procedural low-poly canopies with vertex colours, a gentle wind
// sway that grows with height, soft back-light on the leaves, distance haze and the MR split.
#include "res://shaders/include/split_mr.gdshaderinc"

uniform float wind_strength = 0.06;
uniform float wind_speed = 1.1;
uniform vec3 backlight_color : source_color = vec3(1.0, 0.86, 0.55);
uniform float backlight = 0.35;
uniform bool is_foliage = true;

varying vec3 v_world_pos;
varying float v_height;
varying vec3 v_light;
varying float v_haze;

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_height = VERTEX.y;
	if (is_foliage) {
		float ph = origin.x * 0.37 + origin.z * 0.23;
		float k = clamp(VERTEX.y / 12.0, 0.0, 1.0);
		VERTEX.x += sin(TIME * wind_speed + ph + VERTEX.y * 0.3) * wind_strength * k * 2.0;
		VERTEX.z += cos(TIME * wind_speed * 0.8 + ph) * wind_strength * k * 1.4;
	}
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	v_light = mr_vertex_light(n);
	if (is_foliage) {
		// a little light through the leaves on the shaded side
		v_light += vec3(0.10, 0.14, 0.04) * max(-dot(normalize(n), normalize(sun_dir)), 0.0);
	}
	v_haze = mr_haze_amount(v_world_pos, CAMERA_POSITION_WORLD);
}

void fragment() {
	// no split test here: parkland.gd hides trees on the room side per instance (no discard -> early depth test works)
	ALBEDO = mix(COLOR.rgb * v_light, haze_color, v_haze);
}
