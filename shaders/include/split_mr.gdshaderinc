// Shared by the scenery shaders: Mixed-reality split (real room on one side of a plane, virtual course on the other)
// and distance haze. xr_controller.gd drives the split_* uniforms of every material whose shader mentions
// "enable_split_screen" (see _register_material).
group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform float split_divider_width = 0.015;
uniform float split_blend_width = 0.35;
uniform bool show_split_laser = false;
uniform bool invert_split = false;
uniform vec3 split_divider_color : source_color = vec3(0.2, 0.9, 1.0);
// Room edge (2026-09-24): the scenery fades in over this angle (sine of it) past the split, as seen from the viewer.
// The split plane runs ~0.2-0.5 m beside the head, so its far part is a line "at infinity" that slides over the
// nearby real room whenever the head moves. A wide fade has no line to follow. 0 = only split_blend_width (metres).
uniform float split_fade_angular = 0.0;
group_uniforms Haze;
uniform vec3 haze_color : source_color = vec3(0.70, 0.74, 0.70);
uniform float haze_start = 30.0;
uniform float haze_end = 260.0;
uniform float haze_max : hint_range(0.0, 1.0) = 0.8;
group_uniforms CheapLight;
// Scenery is lit per vertex (unshaded shaders, 2026-09-24): per-pixel lighting + shadows on the ground, hills and
// trees cost ~20-40 fps on Quest 3. test_green_controller._aim_sun() keeps sun_dir in step with the sun.
uniform vec3 sun_dir = vec3(0.3, 0.45, 0.84);          // towards the sun (world)
uniform vec3 sun_col : source_color = vec3(1.0, 0.89, 0.74);
uniform vec3 ambient_col : source_color = vec3(0.70, 0.74, 0.70);
group_uniforms;

vec3 mr_vertex_light(vec3 n_world) {
	return ambient_col + sun_col * max(dot(normalize(n_world), normalize(sun_dir)), 0.0);
}

float mr_haze_amount(vec3 wp, vec3 cam) {
	return smoothstep(haze_start, haze_end, distance(wp, cam)) * haze_max;
}

// 1 = fully virtual, 0 = real room (discard). Opaque objects dither the soft edge instead of blending.
float mr_split_alpha(vec3 wp) {
	if (!enable_split_screen) {
		return 1.0;
	}
	float dist = dot(wp - split_plane_point, split_plane_normal);
	if (invert_split) {
		dist = -dist;
	}
	if (dist >= 0.0) {
		return 0.0;
	}
	return smoothstep(0.0, 1.0, clamp(-dist / max(split_blend_width, 0.01), 0.0, 1.0));
}

// Like mr_split_alpha, but the soft edge is at least split_fade_angular * distance from the viewer wide, so it looks
// equally soft near the feet and at the horizon (matches the sky dome's sky_blend_angular at the horizon).
float mr_split_fade(vec3 wp, vec3 cam) {
	if (!enable_split_screen) {
		return 1.0;
	}
	float dist = dot(wp - split_plane_point, split_plane_normal);
	if (invert_split) {
		dist = -dist;
	}
	if (dist >= 0.0) {
		return 0.0;
	}
	float w = max(split_blend_width, split_fade_angular * distance(wp, cam));
	float t = clamp(-dist / max(w, 0.01), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

bool mr_dither_discard(float a, vec2 frag) {
	if (a >= 0.999) {
		return false;
	}
	float n = fract(sin(dot(floor(frag), vec2(12.9898, 78.233))) * 43758.5453);
	return a <= n;
}

vec3 mr_haze(vec3 c, vec3 wp, vec3 cam) {
	float h = smoothstep(haze_start, haze_end, distance(wp, cam)) * haze_max;
	return mix(c, haze_color, h);
}
