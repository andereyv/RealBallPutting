shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Championship Tournament Golf Flag Fabric Shader
// Features: Multi-harmonic wind wave displacement, canvas pole header,
// double-stitched hem, micro nylon weave, velvet rim sheen, and translucent backlighting.

uniform vec4 flag_color : source_color = vec4(0.85, 0.06, 0.10, 1.0); // Rich PGA tournament crimson red
uniform vec4 header_color : source_color = vec4(0.92, 0.91, 0.88, 1.0); // Reinforced canvas sleeve
uniform float wind_speed : hint_range(1.0, 15.0) = 5.2;
uniform float wind_strength : hint_range(0.01, 0.3) = 0.08;
uniform float fabric_roughness : hint_range(0.2, 1.0) = 0.60;
uniform float velvet_sheen : hint_range(0.0, 1.5) = 0.65;
uniform float translucency : hint_range(0.0, 1.0) = 0.50;

group_uniforms SplitScreenMR;
uniform bool enable_split_screen = true;
uniform vec3 split_plane_point = vec3(0.2, 0.0, 0.0);
uniform vec3 split_plane_normal = vec3(1.0, 0.0, 0.0);
uniform bool invert_split = false;

varying vec3 v_world_pos;

void vertex() {
	// UV.x = 0 at pole clamp, UV.x = 1 at free fly tip
	// Header sleeve is rigidly held (first ~4% of flag)
	float pin = smoothstep(0.03, 0.18, UV.x);
	float dist = UV.x;
	
	// Non-linear amplitude expansion towards the free edge
	float amp = pow(dist, 1.25) * wind_strength;
	
	// Primary traveling billow wave
	float wave1 = sin(dist * 8.0 - TIME * wind_speed) * amp;
	// Secondary cross-flutter harmonic (varies across vertical height)
	float wave2 = cos(dist * 15.0 + UV.y * 5.0 - TIME * (wind_speed * 1.45)) * (amp * 0.4);
	// High-frequency ripple on trailing edge
	float ripple = sin(dist * 28.0 - TIME * (wind_speed * 2.1) + sin(UV.y * 8.0)) * (amp * 0.18);
	
	float total_z = (wave1 + wave2 + ripple) * pin;
	VERTEX.z += total_z;
	
	// Organic gravity drape and flutter along Y
	float sag = -pow(dist, 1.5) * 0.025; // Gentle downward gravity sag
	float y_flutter = sin(dist * 5.0 - TIME * (wind_speed * 0.9)) * (amp * 0.25) * pin;
	VERTEX.y += sag + y_flutter;
	
	// Longitudinal contraction (flag draws slightly inward as folds form)
	VERTEX.x -= (total_z * total_z * 0.85);
	
	// Analytical normal slope for dynamic specular & shadow fold highlights
	float dW_dx = (8.0 * cos(dist * 8.0 - TIME * wind_speed) * amp +
	               15.0 * -sin(dist * 15.0 + UV.y * 5.0 - TIME * (wind_speed * 1.45)) * (amp * 0.4)) * pin;
	float dW_dy = (-5.0 * sin(dist * 15.0 + UV.y * 5.0 - TIME * (wind_speed * 1.45)) * (amp * 0.4)) * pin;
	
	vec3 tangent = normalize(vec3(1.0, 0.0, dW_dx));
	vec3 bitangent = normalize(vec3(0.0, 1.0, dW_dy));
	NORMAL = normalize(cross(tangent, bitangent));
	
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (enable_split_screen) {
		float dist = dot(v_world_pos - split_plane_point, split_plane_normal);
		bool is_passthrough_side = (dist > 0.0);
		if (invert_split) {
			is_passthrough_side = !is_passthrough_side;
		}
		if (is_passthrough_side) {
			discard;
		}
	}

	// Two-sided normal consistency so both sides receive proper lighting
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	
	// Canvas header tube at the pole edge (UV.x < 0.045)
	float header_mask = 1.0 - smoothstep(0.04, 0.048, UV.x);
	
	// Stitched reinforced perimeter hem on top, bottom, and fly edges
	float dist_to_edge_y = min(UV.y, 1.0 - UV.y);
	float dist_to_edge_x = 1.0 - UV.x;
	float hem_mask = smoothstep(0.032, 0.022, min(dist_to_edge_y, dist_to_edge_x));
	// Double stitching dashed line detail
	float stitch_line = step(abs(min(dist_to_edge_y, dist_to_edge_x) - 0.026), 0.002);
	float stitch_dash = step(sin((UV.x + UV.y) * 450.0), 0.1);
	float stitch = stitch_line * stitch_dash * 0.35;
	
	// Micro nylon weave texture pattern
	vec2 weave_uv = UV * vec2(120.0, 84.0);
	float weave = (sin(weave_uv.x * 3.14159) * sin(weave_uv.y * 3.14159)) * 0.035;
	
	// Base cloth tone blending
	vec3 cloth_color = flag_color.rgb + weave;
	// Hem fold darkening (shadow inside folded fabric edge)
	cloth_color = mix(cloth_color, cloth_color * 0.76 + vec3(stitch), hem_mask);
	
	// Blend with reinforced white canvas header sleeve
	vec3 final_albedo = mix(cloth_color, header_color.rgb + (weave * 0.5), header_mask);
	
	// Fabric rim sheen (Fresnel grazing reflection simulating velvety nylon fibers)
	float NdotV = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - NdotV, 3.2) * velvet_sheen * (1.0 - header_mask * 0.5);
	final_albedo += vec3(0.35, 0.10, 0.10) * rim;
	
	ALBEDO = final_albedo;
	ROUGHNESS = mix(fabric_roughness, 0.88, max(hem_mask, header_mask));
	SPECULAR = 0.22;
	
	// Backlight / Translucency (warm sunlight passing through thin flag fabric)
	// Canvas header is thicker/opaque, crimson cloth is translucent
	BACKLIGHT = flag_color.rgb * (translucency * (1.0 - header_mask * 0.85));
}
