shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx; // lambert: cheaper on Quest (2026-09-24)

// === AUTHENTIC CHAMPIONSHIP GOLF GREEN SHADER ===
// With green-reading flow lines, elevation contours & Soft MR Boundary Blend

group_uniforms PuttingTurf;
uniform vec3 bentgrass_color : source_color = vec3(0.20, 0.33, 0.16); // Deep, elegant championship bentgrass
uniform float grain_contrast : hint_range(0.01, 0.20) = 0.055; // Subtle 5% grain shimmer (not zebra stripes)
uniform float mower_width : hint_range(0.3, 1.0) = 0.53; // ~21 inch regulation walk-behind greens mower
uniform float turf_roughness : hint_range(0.5, 1.0) = 0.78;
uniform float velvet_sheen : hint_range(0.0, 1.0) = 0.35;

group_uniforms CollarFringe;
uniform vec3 collar_color : source_color = vec3(0.14, 0.24, 0.11); // Darker, denser fringe collar
uniform float collar_roughness : hint_range(0.6, 1.0) = 0.88;

group_uniforms MicroDetail;
uniform float micro_grain_scale : hint_range(40.0, 250.0) = 120.0;

group_uniforms Cup;
uniform bool cut_cup_hole = true;
uniform vec2 cup_center_local = vec2(0.0); // mesh-local XZ, set by GreenGenerator
uniform float cup_radius = 0.054;
uniform float cup_blade_jitter = 0.0012; // blades overhang the cut edge by up to this much (inward only)
uniform float cup_edge_shade : hint_range(0.0, 1.0) = 0.22; // turf darkens right at the cut edge
uniform float cup_visualizer_clear = 0.14; // grid / contour overlay fades out this close to the cup

group_uniforms ContourVisualizer;
uniform bool show_contour_grid = true;
uniform bool show_elevation_contours = true;
uniform float grid_cell_size : hint_range(0.2, 2.0) = 0.50; // 0.5m grid
uniform float bead_speed : hint_range(0.5, 5.0) = 1.8;
uniform float grid_intensity : hint_range(0.0, 1.0) = 0.65;
// Flow lines (replaced the square grid 2026-09-22): short streaks that drift DOWNHILL across the green, like water
// running off it. Colour = steepness (ice blue < 1.5 %, gold ~2-3 %, orange > 3.5 %); longer, brighter tails on
// steeper ground; nothing on flat ground. All streaks move at the same speed (a speed that depends on the local slope
// tears the streaks apart as TIME grows).
uniform bool show_flow_lines = true;
uniform float flow_cell_size : hint_range(0.1, 0.6) = 0.30; // spacing between streaks (m)
uniform float flow_speed : hint_range(0.05, 1.5) = 0.45;    // streak lifetimes per second
uniform float flow_width : hint_range(0.003, 0.03) = 0.008; // streak width at the head (m)
uniform float flow_intensity : hint_range(0.0, 1.5) = 0.8;

group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform float split_divider_width = 0.015;
uniform float split_blend_width = 0.35; // 35 cm soft feathering / blur transition zone
uniform bool show_split_laser = false; // Soft organic blend without harsh laser line by default
uniform float split_fade_angular = 0.0; // room edge (xr_controller ROOM_EDGES): far parts of the edge fade wider, half as wide as the scenery
uniform bool invert_split = false;
uniform vec3 split_divider_color : source_color = vec3(0.2, 0.9, 1.0);

varying vec3 v_world_pos;
varying vec3 v_local_pos;
varying vec3 v_world_normal;
varying float v_fringe; // 0.0 = pure putting surface, 1.0 = collar/fringe

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_local_pos = VERTEX;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// COLOR.r carries the organic collar mask from GreenGenerator
	v_fringe = clamp(COLOR.r, 0.0, 1.0);
}

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

void fragment() {
	// Pre-compute coordinate derivatives unconditionally at the top of fragment()
	// to avoid divergent derivative calculations on mobile GPUs (Adreno / Quest 3).
	vec2 flow_coord = v_world_pos.xz / flow_cell_size;
	float flow_aa = max(length(fwidth(flow_coord)), 1e-4); // one pixel, in flow cells
	float iso_y = v_world_pos.y / 0.025;
	float iso_deriv = fwidth(iso_y);
	float major_y = v_world_pos.y / 0.10;
	float major_deriv = fwidth(major_y);

	// 0. Stereoscopic 3D Mixed Reality Split-Screen Partitioning (Soft Blend)
	bool on_split_divider = false;
	float mr_blend_factor = 1.0;
	if (enable_split_screen) {
		float dist = dot(v_world_pos - split_plane_point, split_plane_normal);
		if (invert_split) {
			dist = -dist;
		}
		
		if (show_split_laser && abs(dist) < split_divider_width) {
			on_split_divider = true;
		}
		
		// dist >= 0.0: Passthrough side (real room / putting mat)
		// dist <= -split_blend_width: 100% Virtual Golf Green
		// In between: Soft organic feathering zone
		if (dist >= 0.0) {
			discard; // Completely in physical room
		} else if (dist > -max(split_blend_width, split_fade_angular * 0.5 * distance(v_world_pos, CAMERA_POSITION_WORLD))) {
			float bw = max(split_blend_width, split_fade_angular * 0.5 * distance(v_world_pos, CAMERA_POSITION_WORLD));
			float t = clamp(-dist / max(bw, 0.01), 0.0, 1.0);
			// Organic micro-turf edge blade noise for soft realistic dissipation
			float edge_noise = (hash21(v_world_pos.xz * 65.0) - 0.5) * 0.14;
			mr_blend_factor = smoothstep(0.0, 1.0, clamp(t + edge_noise, 0.0, 1.0));
			if (mr_blend_factor <= 0.005) {
				discard;
			}
		}
	}

	// 0b. The cup: a crisp round cut in the turf, independent of the 6 cm mesh grid.
	vec2 cup_dv = v_local_pos.xz - cup_center_local;
	float d_cup = length(cup_dv);
	float cup_edge = 0.0;
	float cup_clear = 1.0;
	if (cut_cup_hole) {
		// Slightly uneven rim: smooth noise along the edge (a stepped hash gave square notches).
		// Only ever inward, so the turf never leaves a gap in front of the cup's earth wall.
		float rim_a = (atan(cup_dv.y, cup_dv.x) + 3.14159265) * 60.0;
		float rim_i = floor(rim_a);
		float rim_f = fract(rim_a);
		rim_f = rim_f * rim_f * (3.0 - 2.0 * rim_f);
		float blade = mix(hash21(vec2(rim_i, 7.0)), hash21(vec2(mod(rim_i + 1.0, 377.0), 7.0)), rim_f) * cup_blade_jitter;
		if (d_cup < cup_radius - blade) {
			discard;
		}
		cup_edge = 1.0 - smoothstep(cup_radius, cup_radius + 0.007, d_cup);
		cup_clear = smoothstep(cup_radius + 0.02, cup_radius + cup_visualizer_clear, d_cup);
	}

	// 1. Double-Cut Tournament Diamond Mower Grain (crosscut at 40° and 130°)
	float angle1 = radians(40.0);
	float angle2 = radians(130.0);
	vec2 dir1 = vec2(cos(angle1), sin(angle1));
	vec2 dir2 = vec2(cos(angle2), sin(angle2));
	
	float proj1 = dot(v_world_pos.xz, dir1) / mower_width;
	float proj2 = dot(v_world_pos.xz, dir2) / mower_width;
	
	// Soft triangular wave for natural roller overlap
	float wave1 = abs(fract(proj1 * 0.5) - 0.5) * 2.0 - 0.5;
	float wave2 = abs(fract(proj2 * 0.5) - 0.5) * 2.0 - 0.5;
	float diamond_grain = (wave1 + wave2) * 0.5;

	// View-dependent grain sheen
	vec2 view_2d = normalize(VIEW.xz);
	float view_shimmer = dot(view_2d, dir1) * wave1 * 0.02;

	// 2. Base Putting Surface Albedo (very subtle grain variation)
	float grain_mod = (diamond_grain * grain_contrast + view_shimmer) * (1.0 - v_fringe);
	vec3 green_albedo = bentgrass_color * (1.0 + grain_mod);

	// 3. High-Frequency Micro-Blade Noise (gives dense 3mm turf look up close)
	float micro_noise = (hash21(v_world_pos.xz * micro_grain_scale) - 0.5) * 0.035;
	green_albedo = clamp(green_albedo + micro_noise, vec3(0.02), vec3(0.95));

	// 4. Distinct Collar / Fringe Boundary Framing
	vec3 final_albedo = mix(green_albedo, collar_color, smoothstep(0.15, 0.85, v_fringe));

	// 5. Authentic Bentgrass Velvet Sheen (grazing angle backscatter)
	float NdotV = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float grazing_fresnel = pow(1.0 - NdotV, 3.5) * velvet_sheen * (1.0 - v_fringe * 0.5);
	final_albedo += vec3(0.12, 0.16, 0.09) * grazing_fresnel;

	// Cut edge: the turf wall and its shadow read darker right at the lip.
	final_albedo *= 1.0 - cup_edge_shade * cup_edge;

	ALBEDO = final_albedo;

	// 6. Physical Micro-Roughness
	float base_rough = mix(turf_roughness, collar_roughness, v_fringe);
	ROUGHNESS = clamp(base_rough - grazing_fresnel * 0.1, 0.68, 0.92);
	SPECULAR = mix(0.22, 0.12, v_fringe);

	// 7. Green-reading visualizer: flow lines (downhill streaks) + elevation contour lines
	if (show_contour_grid && v_fringe < 0.85) {
		float putter_mask = (1.0 - smoothstep(0.2, 0.85, v_fringe)) * cup_clear; // keep the cup itself clean

		// The surface normal leans towards downhill: its horizontal part is the fall line.
		vec3 nrm = normalize(v_world_normal);
		vec2 down = nrm.xz;
		float down_len = length(down);
		float slope = down_len / max(nrm.y, 0.2); // rise over run: 0.02 = 2 %
		vec2 fdir = down_len > 1e-6 ? down / down_len : vec2(0.0, 1.0);
		vec2 fperp = vec2(-fdir.y, fdir.x);

		// Heatmap colour by steepness: flat ice blue -> gold -> flame orange
		float t_slope = clamp(slope * 26.0, 0.0, 1.0);
		vec3 slope_color = mix(vec3(0.30, 0.82, 1.0), vec3(0.96, 0.84, 0.22), smoothstep(0.05, 0.50, t_slope));
		slope_color = mix(slope_color, vec3(1.0, 0.32, 0.12), smoothstep(0.50, 1.0, t_slope));

		float flow = 0.0;
		if (show_flow_lines && flow_aa < 0.14) { // far away the streaks are faded out anyway: skip them
			vec2 base = floor(flow_coord);
			float tail = mix(0.5, 1.0, smoothstep(0.004, 0.035, slope)); // tail length (cells)
			float half_w = 0.5 * flow_width / flow_cell_size;               // half width at the head (cells)
			// 2026-09-24: two streak cells per pixel (its own + the one upstream, where tails come from) instead of 3 x 3.
			// Measured on Quest 3: the 3 x 3 loop cost ~30 fps. Streaks are kept short enough to stay in those cells.
			vec2 up_step = abs(fdir.x) > abs(fdir.y) ? vec2(-sign(fdir.x), 0.0) : vec2(0.0, -sign(fdir.y));
			for (int k = 0; k < 2; k++) {
				vec2 cell = base + (k == 0 ? vec2(0.0) : up_step);
				float h1 = hash21(cell + vec2(0.37, 1.91));
				float h2 = fract(h1 * 43.758 + 0.31);
				vec2 c = cell + 0.5 + (vec2(h1, h2) - 0.5) * 0.4;          // jittered start point
				float ph = fract(TIME * flow_speed + h1 * 7.31);          // this streak's life, 0..1
				vec2 head = c + fdir * (ph - 0.5) * 0.9;                  // drifts 0.9 cells downhill per life
				vec2 d = flow_coord - head;
				float behind = -dot(d, fdir);                             // > 0 = in the tail
				float across = abs(dot(d, fperp));
				float taper = 1.0 - clamp(behind / tail, 0.0, 1.0);
				float w = half_w * (0.35 + 0.65 * taper);
				float line = 1.0 - smoothstep(w - flow_aa, w + flow_aa, across);
				float head_cap = smoothstep(-w - flow_aa, 0.0, behind);   // rounded-ish, crisp head
				float life = sin(3.14159 * ph);                           // fade in, fade out
				flow = max(flow, line * head_cap * taper * taper * life);
			}
			flow *= smoothstep(0.003, 0.010, slope);         // flat ground: no streaks
			flow *= mix(0.55, 1.0, t_slope) * flow_intensity; // steeper = brighter
			flow *= 1.0 - smoothstep(0.05, 0.14, flow_aa);  // far away streaks turn to pixel noise: fade them
		}
		float flow_alpha = clamp(flow, 0.0, 1.0) * putter_mask;

		// Topographic elevation contour lines (every 2.5 cm, stronger every 10 cm)
		float iso_alpha = 0.0;
		if (show_elevation_contours) {
			float iso_fract = abs(fract(iso_y - 0.5) - 0.5);
			float iso_minor = smoothstep(iso_deriv * 1.5, 0.0, iso_fract);
			float major_fract = abs(fract(major_y - 0.5) - 0.5);
			float iso_major = smoothstep(major_deriv * 1.8, 0.0, major_fract);
			iso_alpha = (iso_minor * 0.25 + iso_major * 0.45) * putter_mask * grid_intensity;
		}

		// Composite visualizer onto grass
		vec3 iso_color = vec3(0.94, 0.97, 1.0);
		ALBEDO = mix(ALBEDO, iso_color, iso_alpha * 0.65);
		ALBEDO = mix(ALBEDO, slope_color, flow_alpha * 0.85);
		EMISSION = slope_color * (flow_alpha * 0.55) + iso_color * (iso_alpha * 0.25);
	}

	if (on_split_divider) {
		ALBEDO = split_divider_color * 1.5;
		EMISSION = split_divider_color * 2.0;
		ROUGHNESS = 0.2;
	}

	// Soft feathering alpha into Quest Mixed Reality Passthrough
	ALPHA = mr_blend_factor;
	// Subtle contact shade where virtual turf meets real floor to naturally ground the green
	if (mr_blend_factor < 0.99) {
		ALBEDO = mix(ALBEDO * 0.72, ALBEDO, smoothstep(0.0, 0.35, mr_blend_factor));
	}
}
