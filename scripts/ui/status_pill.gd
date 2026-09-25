extends Node3D
## Small status pill: "Place the ball", "Ready", "Ball not seen", the pin distance, short notices.
## One line of text (+ an optional second, smaller line) after a coloured dot. Transient messages fade out on their own.
##
## 2026-09-24: drawn directly in 3D instead of through a SubViewport texture. The pill sits 1.5-6 m away, where the
## old 960 px texture was shrunk ~3x on screen without mipmaps -> soft, shimmering text ("Ready" looked blurry).
## Now the text is Label3D with an MSDF font (sharp edges at any distance and any scale) and the glass background is
## a rounded rectangle computed per pixel in a shader (anti-aliased with fwidth).

const PX := 0.00058          # metres per "pixel" (was 0.00047: 25% larger so the text reads at 1.5-2 m)
const HEIGHT_1 := 118.0      # pill height with one line (px)
const HEIGHT_2 := 140.0      # with a second line
const PAD := 30.0
const DOT := 20.0
const GAP := 16.0
const BG := Color(0.07, 0.08, 0.09, 0.80)

static var _msdf_cache := {}

var _key := ""
var _hold := -1.0    # seconds left before fading; < 0 = stays
var _alpha := 0.0
var _target := 0.0
var _expired := false # the current transient message has already been shown and faded

var _root: Node3D     # turned towards the viewer
var _bg: MeshInstance3D
var _bg_mat: ShaderMaterial
var _title: Label3D
var _sub: Label3D
var _dot_color := Color.WHITE

const BG_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled;
uniform vec2 size_px = vec2(300.0, 118.0);
uniform vec4 bg : source_color = vec4(0.07, 0.08, 0.09, 0.8);
uniform vec4 dot_color : source_color = vec4(1.0);
uniform vec2 dot_center_px = vec2(40.0, 59.0);
uniform float dot_radius_px = 10.0;
uniform float alpha = 1.0;
float rbox(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
void fragment() {
	vec2 p = UV * size_px;
	float d = rbox(p - size_px * 0.5, size_px * 0.5, size_px.y * 0.5);
	float aa = max(fwidth(d), 0.0001);
	float fill = 1.0 - smoothstep(-aa, aa, d);
	float rim = (1.0 - smoothstep(0.0, aa * 1.5, abs(d + 1.5))) * 0.16;
	float dd = length(p - dot_center_px) - dot_radius_px;
	float daa = max(fwidth(dd), 0.0001);
	float dotm = 1.0 - smoothstep(-daa, daa, dd);
	vec3 col = mix(bg.rgb, vec3(1.0), rim);
	col = mix(col, dot_color.rgb, dotm);
	ALBEDO = col;
	ALPHA = max(fill * bg.a, dotm) * alpha;
}
"""

func _ready() -> void:
	top_level = true
	_root = Node3D.new()
	add_child(_root)
	_bg = MeshInstance3D.new()
	_bg.mesh = QuadMesh.new()
	_bg_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = BG_SHADER
	_bg_mat.shader = sh
	_bg_mat.render_priority = 118
	_bg.material_override = _bg_mat
	_bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(_bg)
	_title = _make_label("Inter-SemiBold", 40)
	_sub = _make_label("Inter-Medium", 27)
	_set_alpha(0.0)

static func msdf_font(name: String) -> Font:
	if not _msdf_cache.has(name):
		var f = load("res://fonts/" + name + ".ttf")
		if f is FontFile:
			var m: FontFile = f.duplicate()
			m.multichannel_signed_distance_field = true
			m.msdf_pixel_range = 14
			m.msdf_size = 64
			m.generate_mipmaps = false
			_msdf_cache[name] = m
		else:
			_msdf_cache[name] = ThemeDB.fallback_font
	return _msdf_cache[name]

func _make_label(face: String, size: int) -> Label3D:
	var l := Label3D.new()
	l.font = msdf_font(face)
	l.font_size = size
	l.pixel_size = PX
	l.outline_size = 0
	l.no_depth_test = true
	l.shaded = false
	l.double_sided = false
	l.render_priority = 119
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(l)
	return l

## Show a status. hold_s < 0 keeps it until something else is shown or hide() is called.
func show_status(title: String, sub: String, color: Color, hold_s: float = -1.0) -> void:
	var key := "%s|%s|%s" % [title, sub, color.to_html()]
	if key != _key:
		_key = key
		_layout(title, sub, color)
		_hold = hold_s
		_expired = false
	if not _expired:
		_target = 1.0

func _layout(title: String, sub: String, color: Color) -> void:
	var two := sub != ""
	_title.font_size = 36 if two else 42
	_title.text = title
	_sub.text = sub
	_sub.visible = two
	var tw := _title.font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, _title.font_size).x
	var sw := _sub.font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, _sub.font_size).x if two else 0.0
	var h := HEIGHT_2 if two else HEIGHT_1
	var w := PAD + DOT + GAP + maxf(tw, sw) + PAD + 6.0
	(_bg.mesh as QuadMesh).size = Vector2(w, h) * PX
	_bg_mat.set_shader_parameter("size_px", Vector2(w, h))
	_bg_mat.set_shader_parameter("bg", BG)
	_bg_mat.set_shader_parameter("dot_color", color)
	_bg_mat.set_shader_parameter("dot_center_px", Vector2(PAD + DOT * 0.5, h * 0.5))
	_bg_mat.set_shader_parameter("dot_radius_px", DOT * 0.5)
	# text starts after the dot; Label3D centres its text on its position (metres, +Y up)
	var x0 := (-w * 0.5 + PAD + DOT + GAP) * PX
	_title.position = Vector3(x0 + tw * 0.5 * PX, (13.0 if two else 1.0) * PX, 0.001)
	_sub.position = Vector3(x0 + sw * 0.5 * PX, -24.0 * PX, 0.001)

func hide_status() -> void:
	_target = 0.0
	_key = ""

func place(pos: Vector3, head: Vector3, up: Vector3 = Vector3.UP) -> void:
	global_position = pos
	var to := head - pos
	if to.length_squared() < 1e-6:
		return
	var u := up.normalized()
	if absf(to.normalized().dot(u)) > 0.995:
		u = Vector3.UP if absf(to.normalized().y) < 0.995 else Vector3.FORWARD
	_root.look_at(pos - to, u) # -Z away from the viewer -> the text (+Z) faces them

func _set_alpha(a: float) -> void:
	_bg_mat.set_shader_parameter("alpha", a)
	_title.modulate = Color(1, 1, 1, 0.96 * a)
	_sub.modulate = Color(1, 1, 1, 0.62 * a)
	_root.visible = a > 0.003

func _process(delta: float) -> void:
	if _hold > 0.0 and _target > 0.0:
		_hold -= delta
		if _hold <= 0.0:
			_target = 0.0
			_expired = true
	var a := move_toward(_alpha, _target, delta / 0.25)
	if a != _alpha:
		_alpha = a
		_set_alpha(_alpha)
