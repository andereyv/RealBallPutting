shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

// Generic PBR object shader with Quest 3 Mixed Reality Stereoscopic 3D Split-Screen Support
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy : hint_range(0.0, 16.0) = 0.0;

group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform float split_divider_width = 0.015;
uniform float split_blend_width = 0.35;
uniform bool show_split_laser = false;
uniform bool invert_split = false;
uniform vec3 split_divider_color : source_color = vec3(0.2, 0.9, 1.0);

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (enable_split_screen) {
		float dist = dot(v_world_pos - split_plane_point, split_plane_normal);
		if (invert_split) {
			dist = -dist;
		}

		if (show_split_laser && abs(dist) < split_divider_width) {
			ALBEDO = split_divider_color * 1.5;
			EMISSION = split_divider_color * 2.0;
			ROUGHNESS = 0.2;
			ALPHA = 1.0;
		} else {
			if (dist >= 0.0) {
				discard;
			}
			float blend_alpha = 1.0;
			if (dist > -split_blend_width) {
				blend_alpha = smoothstep(0.0, 1.0, clamp(-dist / max(split_blend_width, 0.01), 0.0, 1.0));
				if (blend_alpha <= 0.005) {
					discard;
				}
			}
			ALBEDO = albedo_color.rgb;
			ALPHA = albedo_color.a * blend_alpha;
			ROUGHNESS = roughness;
			METALLIC = metallic;
			EMISSION = emission_color * emission_energy;
		}
	} else {
		ALBEDO = albedo_color.rgb;
		ALPHA = albedo_color.a;
		ROUGHNESS = roughness;
		METALLIC = metallic;
		EMISSION = emission_color * emission_energy;
	}
}
