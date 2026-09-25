shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never;

// SkyDome with Mixed Reality Stereoscopic 3D Split-Screen Support
// On the VR side, displays championship sky gradient.
// On the Passthrough side, discards pixels so Quest 3 color passthrough is visible.

uniform vec4 sky_top_color : source_color = vec4(0.32, 0.55, 0.90, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.70, 0.82, 0.92, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.22, 0.32, 0.20, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.55, 0.68, 0.60, 1.0);
uniform vec3 sun_direction = vec3(-0.55, 0.40, -0.73); // towards the sun (world)
uniform vec3 sun_color : source_color = vec3(1.0, 0.86, 0.62);
uniform float sun_glow = 0.35;

group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform bool invert_split = false;
uniform vec3 divider_color : source_color = vec3(0.2, 0.9, 1.0);
uniform float divider_angular_width = 0.0; // 0 = no cyan divider line
uniform float sky_blend_angular = 0.04; // soft fade into the real room across the split (radians-ish)

varying vec3 v_normal;
varying vec3 v_world_pos;

void vertex() {
	v_normal = NORMAL;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(v_world_pos - split_plane_point);
	float dist = dot(dir, split_plane_normal);
	// room side: alpha 0 instead of discard, so the GPU can still skip sky pixels hidden behind the scenery
	bool room = enable_split_screen && ((dist > 0.0) != invert_split);

	// Gradient sky on the virtual half, with a soft sun glow (golden hour)
	float y = v_normal.y;
	vec3 col;
	if (y > 0.0) {
		vec3 vd = normalize(v_world_pos - CAMERA_POSITION_WORLD);
		float sd = max(dot(vd, normalize(sun_direction)), 0.0);
		vec3 sky = mix(sky_horizon_color.rgb, sky_top_color.rgb, pow(clamp(y * 1.3, 0.0, 1.0), 0.7));
		float sd2 = sd * sd;
		float sd8 = sd2 * sd2 * sd2 * sd2;
		sky += sun_color * (sd2 * sd2 * sd2 * sun_glow + pow(sd, 90.0) * 0.6 + pow(sd8, 200.0) * 2.0);
		col = sky;
	} else {
		col = mix(ground_horizon_color.rgb, ground_bottom_color.rgb, clamp(-y * 2.5, 0.0, 1.0));
	}
	if (enable_split_screen && divider_angular_width > 0.0 && abs(dist) < divider_angular_width) {
		col = divider_color * 1.5;
		room = false;
	}
	float a = 1.0;
	if (enable_split_screen && sky_blend_angular > 0.0) {
		float sdd = invert_split ? dist : -dist;
		a = smoothstep(0.0, sky_blend_angular, sdd);
	}
	ALBEDO = col;
	ALPHA = room ? 0.0 : a;
}
