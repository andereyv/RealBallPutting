shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never;

// SkyDome with Mixed Reality Stereoscopic 3D Split-Screen Support
// On the VR side, displays championship sky gradient.
// On the Passthrough side, discards pixels so Quest 3 color passthrough is visible.

uniform vec4 sky_top_color : source_color = vec4(0.32, 0.55, 0.90, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.70, 0.82, 0.92, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.22, 0.32, 0.20, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.55, 0.68, 0.60, 1.0);

group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform bool invert_split = false;
uniform vec3 divider_color : source_color = vec3(0.2, 0.9, 1.0);
uniform float divider_angular_width = 0.005;

varying vec3 v_normal;
varying vec3 v_world_pos;

void vertex() {
	v_normal = NORMAL;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(v_world_pos - split_plane_point);
	float dist = dot(dir, split_plane_normal);

	if (enable_split_screen && abs(dist) < divider_angular_width) {
		ALBEDO = divider_color * 1.5;
		ALPHA = 1.0;
	} else {
		if (enable_split_screen) {
			bool is_passthrough_side = (dist > 0.0);
			if (invert_split) {
				is_passthrough_side = !is_passthrough_side;
			}
			if (is_passthrough_side) {
				discard; // Transparent: Quest compositor renders real room passthrough
			}
		}
		
		// Gradient sky on the VR half
		float y = v_normal.y;
		if (y > 0.0) {
			ALBEDO = mix(sky_horizon_color.rgb, sky_top_color.rgb, clamp(y * 1.6, 0.0, 1.0));
		} else {
			ALBEDO = mix(ground_horizon_color.rgb, ground_bottom_color.rgb, clamp(-y * 2.5, 0.0, 1.0));
		}
		ALPHA = 1.0;
	}
}
