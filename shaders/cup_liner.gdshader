shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Golf cup liner (scripts/environment/cup_liner.gd). The mesh normals point INTO the hole.
// A cup must only ever be seen from the inside. Instead of trusting triangle winding + back-face
// culling, each fragment checks whether the camera is on the inner side of its surface and is
// dropped otherwise. So the outside of the wall can never show, whatever the green around it does.

uniform float roughness : hint_range(0.0, 1.0) = 0.62;
uniform float specular : hint_range(0.0, 1.0) = 0.35;

varying vec3 v_local;
varying vec3 v_normal_local;
varying vec3 v_cam_local;

void vertex() {
	v_local = VERTEX;
	v_normal_local = NORMAL;
	v_cam_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

void fragment() {
	if (dot(v_cam_local - v_local, v_normal_local) <= 0.0) {
		discard;
	}
	// Vertex colours are already linear (converted in cup_liner.gd).
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	// Explicit inward normal: correct lighting no matter which way the triangle happens to face.
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(v_normal_local, 0.0)).xyz);
}
