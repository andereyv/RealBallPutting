class_name GlassPanel
extends Node3D
## A floating "glass" card in 3D, in the spirit of visionOS: Control nodes are laid out in a SubViewport and shown on a
## quad. Dark translucent material with rounded corners and a hairline edge; Inter typeface.
##
## Build the content under `content` (a VBoxContainer), call `refresh()` after changing it, then position the node.
## The quad faces +Z; call `face(target)` to turn it towards the viewer. Transparency: `set_alpha()`.

const FONT_DIR := "res://fonts/"
static var _font_cache := {}

@export var size_px := Vector2i(760, 420)
@export var width_m := 0.38
@export var corner_radius_px := 46
@export var padding_px := 36
@export var bg_color := Color(0.07, 0.08, 0.09, 0.78)

var viewport: SubViewport
var panel: PanelContainer
var content: VBoxContainer
var quad: MeshInstance3D
var _mat: StandardMaterial3D
var _style: StyleBoxFlat
var _redraw_frames := 0
var _alpha := 1.0

func _init(px: Vector2i = Vector2i(760, 420), width_meters: float = 0.38) -> void:
	size_px = px
	width_m = width_meters
	viewport = SubViewport.new()
	viewport.size = size_px
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)

	_style = StyleBoxFlat.new()
	_style.bg_color = bg_color
	_style.set_corner_radius_all(corner_radius_px)
	_style.corner_detail = 12
	_style.border_color = Color(1, 1, 1, 0.14)
	_style.set_border_width_all(2)
	_style.anti_aliasing = true
	_style.content_margin_left = padding_px
	_style.content_margin_right = padding_px
	_style.content_margin_top = padding_px - 6
	_style.content_margin_bottom = padding_px - 6

	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style)
	panel.position = Vector2.ZERO
	panel.size = Vector2(size_px)
	viewport.add_child(panel)

	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	panel.add_child(content)

	quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(width_m, width_m * float(size_px.y) / float(size_px.x))
	quad.mesh = qm
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.no_depth_test = true
	_mat.render_priority = 120
	_mat.cull_mode = BaseMaterial3D.CULL_BACK
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	quad.material_override = _mat
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(quad)

func _ready() -> void:
	_mat.albedo_texture = viewport.get_texture()
	refresh()

## Shrink the card's width to its content (pills). Keeps the scale (metres per pixel) of the original size.
func fit_width_to_content() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	var mpp := width_m / float(size_px.x)
	var w := clampi(int(ceil(panel.get_combined_minimum_size().x)) + 2, 120, size_px.x)
	viewport.size = Vector2i(w, size_px.y)
	panel.size = Vector2(w, size_px.y)
	(quad.mesh as QuadMesh).size = Vector2(w * mpp, size_px.y * mpp)
	refresh()

func height_m() -> float:
	return width_m * float(size_px.y) / float(size_px.x)

## Re-render the UI (layout settles over a couple of frames, so keep updating briefly).
func refresh() -> void:
	_redraw_frames = 3
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func set_background(c: Color) -> void:
	_style.bg_color = c
	refresh()

func set_alpha(a: float) -> void:
	_alpha = clampf(a, 0.0, 1.0)
	_mat.albedo_color = Color(1, 1, 1, _alpha)
	visible = _alpha > 0.003

## Turn the card towards a point (the viewer's head), staying upright.
func face(target: Vector3) -> void:
	var p := global_position
	var away := p + (p - target) # face the viewer squarely (also when seen from above), text stays upright
	if away.distance_squared_to(p) > 1e-6 and absf((target - p).normalized().y) < 0.995:
		look_at(away, Vector3.UP)

func _process(_delta: float) -> void:
	if _redraw_frames > 0:
		_redraw_frames -= 1
		if _redraw_frames == 0:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

func clear_content() -> void:
	for c in content.get_children():
		content.remove_child(c)
		c.queue_free()

# ------------------------------------------------------------------ text helpers
static func font(name: String) -> Font:
	if not _font_cache.has(name):
		var f = load(FONT_DIR + name + ".ttf")
		_font_cache[name] = f if f != null else ThemeDB.fallback_font
	return _font_cache[name]

## A label with an Inter face ("Inter-Regular", "Inter-Medium", "Inter-SemiBold", "InterDisplay-SemiBold").
static func make_label(text: String, face_name: String, size: int, color: Color = Color(1, 1, 1, 0.96)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(face_name))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

static func make_dot(color: Color, d: int = 18) -> Panel:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(d / 2)
	sb.anti_aliasing = true
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(d, d)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p

static func make_rule(alpha: float = 0.12) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, alpha)
	r.custom_minimum_size = Vector2(0, 2)
	return r
