shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

// === AUTHENTIC CHAMPIONSHIP GOLF GREEN SHADER ===
// With Golf+ Style Interactive Contour Visualizer, Flowing Slope Beads & Soft MR Boundary Blend

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

group_uniforms ContourVisualizer;
uniform bool show_contour_grid = true;
uniform bool show_elevation_contours = true;
uniform float grid_cell_size : hint_range(0.2, 2.0) = 0.50; // 0.5m grid
uniform float bead_speed : hint_range(0.5, 5.0) = 1.8;
uniform float grid_intensity : hint_range(0.0, 1.0) = 0.65;

group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform float split_divider_width = 0.015;
uniform float split_blend_width = 0.35; // 35 cm soft feathering / blur transition zone (Golf+ style)
uniform bool show_split_laser = false; // Soft organic blend without harsh laser line by default
uniform bool invert_split = false;
uniform vec3 split_divider_color : source_color = vec3(0.2, 0.9, 1.0);

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying float v_fringe; // 0.0 = pure putting surface, 1.0 = collar/fringe

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
	vec2 grid_coord = v_world_pos.xz / grid_cell_size;
	vec2 grid_deriv = fwidth(grid_coord);
	float iso_y = v_world_pos.y / 0.025;
	float iso_deriv = fwidth(iso_y);
	float major_y = v_world_pos.y / 0.10;
	float major_deriv = fwidth(major_y);

	// 0. Stereoscopic 3D Mixed Reality Split-Screen Partitioning (Golf+ Style Soft Blend)
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
		} else if (dist > -split_blend_width) {
			float t = clamp(-dist / max(split_blend_width, 0.01), 0.0, 1.0);
			// Organic micro-turf edge blade noise for soft realistic dissipation
			float edge_noise = (hash21(v_world_pos.xz * 65.0) - 0.5) * 0.14;
			mr_blend_factor = smoothstep(0.0, 1.0, clamp(t + edge_noise, 0.0, 1.0));
			if (mr_blend_factor <= 0.005) {
				discard;
			}
		}
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

	ALBEDO = final_albedo;

	// 6. Physical Micro-Roughness
	float base_rough = mix(turf_roughness, collar_roughness, v_fringe);
	ROUGHNESS = clamp(base_rough - grazing_fresnel * 0.1, 0.68, 0.92);
	SPECULAR = mix(0.22, 0.12, v_fringe);

	// 7. Authentic Golf+ Style Contour Visualizer & Physical Flow Beads
	if (show_contour_grid && v_fringe < 0.85) {
		float putter_mask = 1.0 - smoothstep(0.2, 0.85, v_fringe);

		// Grid lines along X and Z (using precomputed grid_coord and grid_deriv)
		vec2 grid_fract = abs(fract(grid_coord - 0.5) - 0.5);
		vec2 grid_lines = smoothstep(grid_deriv * 1.4, vec2(0.0), grid_fract);
		float line_x = grid_lines.y; // Horizontal line running along X
		float line_z = grid_lines.x; // Vertical line running along Z
		float line_base = clamp(line_x + line_z, 0.0, 1.0);

		// Surface downhill normal components
		// v_world_normal.x is downhill along X, v_world_normal.z is downhill along Z
		float slope_x = v_world_normal.x;
		float slope_z = v_world_normal.z;
		float slope_steepness = length(v_world_normal.xz);

		// Heatmap color based on slope severity (Golf+ style)
		// Flat (<1.5%): Cyan/Ice Blue -> Moderate (1.5-3.5%): Lime/Gold -> Steep Ridge (>3.5%): Orange/Flame
		float t_slope = clamp(slope_steepness * 26.0, 0.0, 1.0);
		vec3 slope_color = mix(vec3(0.30, 0.82, 1.0), vec3(0.96, 0.84, 0.22), smoothstep(0.05, 0.50, t_slope));
		slope_color = mix(slope_color, vec3(1.0, 0.32, 0.12), smoothstep(0.50, 1.0, t_slope));

		// Flowing slope beads traveling strictly along grid axes toward low ground
		// Beads on X-lines roll along X in direction of slope_x
		float bead_flow_x = fract(v_world_pos.x * 2.2 * sign(slope_x) - TIME * bead_speed * (0.6 + abs(slope_x) * 22.0));
		float bead_x = smoothstep(0.18, 0.0, abs(bead_flow_x - 0.5)) * line_x * step(0.006, abs(slope_x));

		// Beads on Z-lines roll along Z in direction of slope_z
		float bead_flow_z = fract(v_world_pos.z * 2.2 * sign(slope_z) - TIME * bead_speed * (0.6 + abs(slope_z) * 22.0));
		float bead_z = smoothstep(0.18, 0.0, abs(bead_flow_z - 0.5)) * line_z * step(0.006, abs(slope_z));

		float total_beads = max(bead_x, bead_z);
		float grid_pattern = max(line_base * 0.35, total_beads * 1.6);
		float final_grid_alpha = grid_pattern * grid_intensity * putter_mask;

		// 8. Topographic Elevation Contour Isolines (every 2.5cm / 1-inch elevation)
		float iso_alpha = 0.0;
		if (show_elevation_contours) {
			// Minor contour lines every 2.5cm (1 inch) using precomputed iso_y and iso_deriv
			float iso_fract = abs(fract(iso_y - 0.5) - 0.5);
			float iso_minor = smoothstep(iso_deriv * 1.5, 0.0, iso_fract);

			// Major contour lines every 10cm (4 inches) using precomputed major_y and major_deriv
			float major_fract = abs(fract(major_y - 0.5) - 0.5);
			float iso_major = smoothstep(major_deriv * 1.8, 0.0, major_fract);

			iso_alpha = (iso_minor * 0.25 + iso_major * 0.45) * putter_mask * grid_intensity;
		}

		// Composite visualizer onto grass
		vec3 iso_color = vec3(0.94, 0.97, 1.0);
		ALBEDO = mix(ALBEDO, slope_color, final_grid_alpha * 0.72);
		ALBEDO = mix(ALBEDO, iso_color, iso_alpha * 0.65);
		EMISSION = slope_color * (final_grid_alpha * 0.45) + iso_color * (iso_alpha * 0.25);
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
