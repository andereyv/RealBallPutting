shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, unshaded;

uniform vec4 outline_color : source_color = vec4(0.35, 0.85, 1.0, 0.95);
uniform vec4 fill_color : source_color = vec4(0.04, 0.10, 0.18, 0.22);
uniform float rim_power : hint_range(0.5, 6.0) = 2.4;
uniform float rim_boost : hint_range(0.5, 4.0) = 1.8;
uniform float pinch_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec4 pinch_color : source_color = vec4(0.1, 1.0, 0.5, 1.0);

void fragment() {
	float n_dot_v = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - n_dot_v, rim_power) * rim_boost;
	
	vec4 base_rim = mix(outline_color, pinch_color, pinch_intensity);
	vec3 col = mix(fill_color.rgb, base_rim.rgb, clamp(rim, 0.0, 1.0));
	float alpha = mix(fill_color.a, base_rim.a, clamp(rim * 1.2, 0.0, 1.0));
	
	ALBEDO = col;
	ALPHA = alpha;
}
