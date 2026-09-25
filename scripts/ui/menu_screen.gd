extends Node3D
## Floating glass menu for the main menu, setup pages, settings and the round summary (2026-09-23).
##
## The page is described by a Dictionary (built by scripts/gameplay/game_flow.gd):
##   {"title": String, "subtitle": String, "back": bool, "items": [item, ...]}
## Item types:
##   {"type": "hero",   "id", "title", "subtitle"}                      big accent card (Continue)
##   {"type": "row",    "id", "title", "value", "disabled"}             list row with a value and a chevron
##   {"type": "seg",    "id", "title", "options": [{"id","label"}], "selected"}   segmented control -> "id:option"
##   {"type": "cards",  "items": [{"id","title","subtitle"}]}            two big side-by-side choices
##   {"type": "button", "id", "title", "style": "primary"|"plain"}
##   {"type": "text",   "text"}
##   {"type": "stats",  "values": [[value, caption], ...]}
##   {"type": "scorecard", "scores": [int...], "par": int}
##
## Input: touch the glass with an index fingertip (it sits within reach; scripts/ui/poke_input.gd). Controllers point
## and pull the trigger. Pressing calls host.menu_screen_action(id).

const W_PX := 860
const W_M := 0.40
const DIST_M := 0.42 # within easy reach of a fingertip (recording: hands work ~0.35-0.45 m from the eyes)
const DROP_M := 0.24
const ACCENT := Color(0.35, 0.72, 1.0)
const PRIMARY := Color(0.05, 0.45, 0.95, 0.95) # filled button (white text stays readable)
const TXT := Color(1, 1, 1, 0.96)
const TXT2 := Color(1, 1, 1, 0.62)
const TXT3 := Color(1, 1, 1, 0.42)
const ROW_H := 92
const PRESS_DEPTH_M := 0.012
const HOVER_DEPTH_M := 0.08
const REARM_DEPTH_M := 0.03
const COOLDOWN_S := 0.35

var host: Object
var panel: GlassPanel
var is_shown := false
var page_id := ""

var _model := {}
var _sig := ""
var _hits := [] # [{"id", "ctrl": Control, "style": StyleBoxFlat, "base": Color}]
var _hover := ""
var _flash := ""
var _flash_t := 0.0
var _alpha := 0.0
var _cooldown := 0.0
var _poke_armed := {}
var _ray_down := {}
var _follow := false
var _ray: MeshInstance3D
var _ray_mat: StandardMaterial3D
var _cursor: MeshInstance3D
var _poke # scripts/ui/poke_input.gd
var _finger_near := false

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	panel = GlassPanel.new(Vector2i(W_PX, 900), W_M)
	panel.name = "MenuPanel"
	add_child(panel)
	panel.set_alpha(0.0)
	_ray = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0012
	cyl.bottom_radius = 0.0022
	cyl.height = 1.0
	cyl.radial_segments = 8
	_ray.mesh = cyl
	_ray_mat = StandardMaterial3D.new()
	_ray_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ray_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ray_mat.albedo_color = Color(1, 1, 1, 0.45)
	_ray.material_override = _ray_mat
	_ray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ray.visible = false
	add_child(_ray)
	_cursor = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.006
	sm.height = 0.012
	_cursor.mesh = sm
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.albedo_color = Color(1, 1, 1, 0.95)
	cm.no_depth_test = true
	cm.render_priority = 127
	_cursor.material_override = cm
	_cursor.visible = false
	add_child(_cursor)
	_poke = preload("res://scripts/ui/poke_input.gd").new()
	add_child(_poke)

## Show a page. reposition: place it in front of the viewer (otherwise it stays where it is).
func show_page(id: String, model: Dictionary, head: Vector3, forward: Vector3, reposition: bool = true) -> void:
	page_id = id
	_model = model
	_sig = ""
	_hover = ""
	if reposition or not is_shown:
		_place(head, forward)
	is_shown = true
	_rebuild_if_needed()

func hide_menu() -> void:
	is_shown = false
	_hover = ""
	_ray.visible = false
	_cursor.visible = false

## Re-render the current page with a changed model (a value changed), keeping the position.
func update_model(model: Dictionary) -> void:
	_model = model
	_rebuild_if_needed()

## pointers: [{"key", "pos", "dir", "pressed"}]  (hand pinch rays / controller rays)
## tips: [{"key", "pos"}]  (index fingertips)
func update(delta: float, head: Vector3, forward: Vector3, pointers: Array, tips: Array) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	_alpha = move_toward(_alpha, 1.0 if is_shown else 0.0, delta / 0.2)
	panel.set_alpha(_alpha)
	panel.scale = Vector3.ONE * (0.96 + 0.04 * _alpha)
	if _alpha <= 0.0 or not is_shown:
		_ray.visible = false
		_cursor.visible = false
		_poke.hide_cursor()
	if _alpha <= 0.0:
		return
	_keep_in_view(delta, head, forward)
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash = ""
			_restyle()
	if not is_shown:
		return

	var new_hover := ""
	var pressed_id := ""
	var ray_shown := false
	# 1) hands: direct touch (scripts/ui/poke_input.gd)
	var poke: Dictionary = _poke.process(panel, tips, _hit)
	_finger_near = poke["near"]
	new_hover = poke["hover"]
	pressed_id = poke["pressed"] if _cooldown <= 0.0 else ""
	# 2) controllers: ray + trigger
	if not poke["near"]:
		for p in pointers:
			var o: Vector3 = p["pos"]
			var d: Vector3 = (p["dir"] as Vector3).normalized()
			var inv := panel.global_transform.affine_inverse()
			var lo: Vector3 = inv * o
			var ld: Vector3 = inv.basis * d
			var key: String = p["key"]
			var down: bool = p["pressed"]
			var was_down: bool = _ray_down.get(key, false)
			_ray_down[key] = down
			if ld.z >= -0.0001 or lo.z <= 0.02:
				continue
			var t := -lo.z / ld.z
			if t < 0.05 or t > 3.0:
				continue
			var hit_l := lo + ld * t
			var px := _to_px(hit_l)
			if px.x < 0 or px.y < 0 or px.x > panel.size_px.x or px.y > panel.size_px.y:
				continue
			var hit_w: Vector3 = panel.global_transform * hit_l
			_show_ray(o, hit_w)
			ray_shown = true
			var id := _hit(px)
			new_hover = id
			if id != "" and down and not was_down and _cooldown <= 0.0:
				pressed_id = id
			break
	if not ray_shown:
		_ray.visible = false
		_cursor.visible = false
	if new_hover != _hover:
		_hover = new_hover
		_restyle()
	if pressed_id != "":
		_cooldown = COOLDOWN_S
		_flash = pressed_id
		_flash_t = 0.22
		_restyle()
		if host != null and host.has_method("menu_screen_action"):
			host.call("menu_screen_action", pressed_id)

## Tests / desktop: press an item by id as if it was poked.
func debug_press(id: String) -> void:
	if host != null and host.has_method("menu_screen_action"):
		host.call("menu_screen_action", id)

func hit_ids() -> Array:
	var out := []
	for h in _hits:
		out.append(h["id"])
	return out

## World position of an item's centre on the glass (tests).
func item_world_pos(id: String, depth: float = 0.0) -> Vector3:
	for h in _hits:
		if h["id"] == id:
			var c: Vector2 = (h["ctrl"] as Control).get_global_rect().get_center()
			var local := Vector3((c.x / panel.size_px.x - 0.5) * panel.width_m, (0.5 - c.y / panel.size_px.y) * panel.height_m(), depth)
			return panel.global_transform * local
	return Vector3.ZERO

# ------------------------------------------------------------------ placement
func _place(head: Vector3, forward: Vector3) -> void:
	var f := Vector3(forward.x, 0.0, forward.z)
	f = f.normalized() if f.length() > 0.05 else Vector3(0, 0, -1)
	panel.global_position = head + f * DIST_M + Vector3.UP * -DROP_M
	panel.face(head)
	_follow = false

## If the menu drifts out of view (turned away, walked off), it glides back in front of the head.
func _keep_in_view(delta: float, head: Vector3, forward: Vector3) -> void:
	var f := Vector3(forward.x, 0.0, forward.z)
	if f.length() < 0.05:
		return
	f = f.normalized()
	var to := panel.global_position - head
	to.y = 0.0
	var dist := to.length()
	var ang := rad_to_deg(f.angle_to(to.normalized())) if dist > 0.05 else 180.0
	# never while a finger is at the glass (leaning in to touch must not push the menu away)
	if (ang > 45.0 or dist > 1.1) and not _finger_near:
		_follow = true
	if _follow:
		var target := head + f * DIST_M + Vector3.UP * -DROP_M
		panel.global_position = panel.global_position.lerp(target, clampf(delta * 4.0, 0.0, 1.0))
		panel.face(head)
		if panel.global_position.distance_to(target) < 0.02:
			_follow = false

func _to_px(local: Vector3) -> Vector2:
	return Vector2((local.x / panel.width_m + 0.5) * panel.size_px.x, (0.5 - local.y / panel.height_m()) * panel.size_px.y)

func _hit(px: Vector2) -> String:
	for h in _hits:
		var c: Control = h["ctrl"]
		if is_instance_valid(c) and c.is_visible_in_tree() and c.get_global_rect().has_point(px):
			return h["id"]
	return ""

func _show_ray(from: Vector3, to: Vector3) -> void:
	var d := from.distance_to(to)
	_cursor.visible = true
	_cursor.global_position = to
	if d < 0.03:
		_ray.visible = false
		return
	_ray.visible = true
	_ray.global_position = (from + to) * 0.5
	_ray.scale = Vector3(1.0, d, 1.0)
	var up := Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.FORWARD
	_ray.look_at(to, up)
	_ray.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))

# ------------------------------------------------------------------ building
func _rebuild_if_needed() -> void:
	var sig := JSON.stringify(_model)
	if sig == _sig:
		return
	_sig = sig
	panel.clear_content()
	_hits.clear()
	var c := panel.content
	c.add_theme_constant_override("separation", 14)
	if _model.get("back", false):
		var back := _plain_button("back", "‹  Back", 26, HORIZONTAL_ALIGNMENT_LEFT)
		back.custom_minimum_size = Vector2(170, 56)
		back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		c.add_child(back)
	var title := GlassPanel.make_label(str(_model.get("title", "")), "InterDisplay-SemiBold", 56, TXT)
	c.add_child(title)
	if str(_model.get("subtitle", "")) != "":
		var sub := GlassPanel.make_label(str(_model["subtitle"]), "Inter-Regular", 28, TXT2)
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.custom_minimum_size = Vector2(W_PX - 80, 0)
		c.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	c.add_child(gap)
	for it in _model.get("items", []):
		match str(it.get("type", "row")):
			"hero": c.add_child(_hero(it))
			"row": c.add_child(_row(it))
			"seg": c.add_child(_seg(it))
			"cards": c.add_child(_cards(it))
			"button": c.add_child(_button(it))
			"text": c.add_child(_text(it))
			"stats": c.add_child(_stats(it))
			"scorecard": c.add_child(_scorecard(it))
	_restyle()
	panel.fit_height_to_content(240, 1400)

func _box(radius: int = 26) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.07)
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb

func _register(id: String, ctrl: Control, sb: StyleBoxFlat, base: Color) -> void:
	sb.bg_color = base
	_hits.append({"id": id, "ctrl": ctrl, "style": sb, "base": base})

func _hero(it: Dictionary) -> Control:
	var pc := PanelContainer.new()
	var sb := _box(32)
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	pc.add_theme_stylebox_override("panel", sb)
	var hb := HBoxContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(GlassPanel.make_label(str(it.get("title", "")), "Inter-SemiBold", 40, TXT))
	if str(it.get("subtitle", "")) != "":
		vb.add_child(GlassPanel.make_label(str(it["subtitle"]), "Inter-Regular", 26, Color(1, 1, 1, 0.72)))
	hb.add_child(vb)
	var play := GlassPanel.make_label("▶", "Inter-Medium", 40, TXT)
	play.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(play)
	pc.add_child(hb)
	_register(str(it["id"]), pc, sb, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.32))
	return pc

func _row(it: Dictionary) -> Control:
	var pc := PanelContainer.new()
	var sb := _box()
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(0, ROW_H)
	var dis: bool = it.get("disabled", false)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	hb.add_child(GlassPanel.make_label(str(it.get("title", "")), "Inter-Medium", 32, TXT3 if dis else TXT))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(sp)
	if str(it.get("value", "")) != "":
		hb.add_child(GlassPanel.make_label(str(it["value"]), "Inter-Regular", 28, TXT3 if dis else TXT2))
	if not dis:
		hb.add_child(GlassPanel.make_label("›", "Inter-Medium", 34, TXT3))
	for l in hb.get_children():
		if l is Label:
			l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pc.add_child(hb)
	if dis:
		sb.bg_color = Color(1, 1, 1, 0.03)
	else:
		_register(str(it["id"]), pc, sb, Color(1, 1, 1, 0.07))
	return pc

func _seg(it: Dictionary) -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	if str(it.get("title", "")) != "":
		var t := GlassPanel.make_label(str(it["title"]), "Inter-Medium", 24, TXT3)
		vb.add_child(t)
	var track := PanelContainer.new()
	var tsb := _box(28)
	tsb.content_margin_left = 6
	tsb.content_margin_right = 6
	tsb.content_margin_top = 6
	tsb.content_margin_bottom = 6
	tsb.bg_color = Color(1, 1, 1, 0.06)
	track.add_theme_stylebox_override("panel", tsb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	for o in it.get("options", []):
		var pc := PanelContainer.new()
		var sb := _box(22)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		pc.add_theme_stylebox_override("panel", sb)
		pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pc.custom_minimum_size = Vector2(0, 72)
		var sel: bool = str(o["id"]) == str(it.get("selected", ""))
		var l := GlassPanel.make_label(str(o["label"]), "Inter-SemiBold" if sel else "Inter-Medium", 27, TXT if sel else TXT2)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pc.add_child(l)
		hb.add_child(pc)
		_register("%s:%s" % [it["id"], o["id"]], pc, sb, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.55) if sel else Color(1, 1, 1, 0.0))
	track.add_child(hb)
	vb.add_child(track)
	return vb

func _cards(it: Dictionary) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	for card in it.get("items", []):
		var pc := PanelContainer.new()
		var sb := _box(32)
		pc.add_theme_stylebox_override("panel", sb)
		pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pc.custom_minimum_size = Vector2(0, 230)
		var vb := VBoxContainer.new()
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_theme_constant_override("separation", 6)
		var t := GlassPanel.make_label(str(card.get("title", "")), "Inter-SemiBold", 36, TXT)
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(t)
		if str(card.get("subtitle", "")) != "":
			var s := GlassPanel.make_label(str(card["subtitle"]), "Inter-Regular", 24, TXT2)
			s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			vb.add_child(s)
		pc.add_child(vb)
		hb.add_child(pc)
		_register(str(card["id"]), pc, sb, Color(1, 1, 1, 0.08))
	return hb

func _button(it: Dictionary) -> Control:
	var primary: bool = str(it.get("style", "primary")) == "primary"
	var pc := PanelContainer.new()
	var sb := _box(30)
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(0, 96)
	var l := GlassPanel.make_label(str(it.get("title", "")), "Inter-SemiBold", 34, TXT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pc.add_child(l)
	_register(str(it["id"]), pc, sb, PRIMARY if primary else Color(1, 1, 1, 0.10))
	return pc

func _plain_button(id: String, text: String, size: int, align: int) -> Control:
	var pc := PanelContainer.new()
	var sb := _box(24)
	sb.content_margin_left = 18
	pc.add_theme_stylebox_override("panel", sb)
	var l := GlassPanel.make_label(text, "Inter-Medium", size, ACCENT)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pc.add_child(l)
	_register(id, pc, sb, Color(1, 1, 1, 0.0))
	return pc

func _text(it: Dictionary) -> Control:
	var l := GlassPanel.make_label(str(it.get("text", "")), "Inter-Regular", 28, TXT2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(W_PX - 80, 0)
	return l

func _stats(it: Dictionary) -> Control:
	var hb := HBoxContainer.new()
	for v in it.get("values", []):
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 0)
		col.add_child(GlassPanel.make_label(str(v[0]), "InterDisplay-SemiBold", 52, TXT))
		col.add_child(GlassPanel.make_label(str(v[1]), "Inter-Regular", 22, TXT3))
		hb.add_child(col)
	return hb

## Holes in rows of 9: hole numbers, then the score per hole (coloured against par).
func _scorecard(it: Dictionary) -> Control:
	var scores: Array = it.get("scores", [])
	var par: int = int(it.get("par", 2))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	var i := 0
	while i < scores.size():
		var grid := GridContainer.new()
		grid.columns = 10
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 2)
		var n := mini(9, scores.size() - i)
		grid.add_child(GlassPanel.make_label("Hole", "Inter-Regular", 20, TXT3))
		for k in 9:
			var l := GlassPanel.make_label(str(i + k + 1) if k < n else "", "Inter-Regular", 20, TXT3)
			l.custom_minimum_size = Vector2(64, 0)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			grid.add_child(l)
		grid.add_child(GlassPanel.make_label("Putts", "Inter-Medium", 24, TXT2))
		for k in 9:
			var txt := ""
			var col := TXT
			if k < n:
				var s: int = int(scores[i + k])
				txt = str(s) if s > 0 else "–"
				if s > 0 and s < par:
					col = Color(0.36, 0.86, 0.47)
				elif s > par:
					col = Color(1.0, 0.66, 0.26)
			var l := GlassPanel.make_label(txt, "Inter-SemiBold", 30, col)
			l.custom_minimum_size = Vector2(64, 0)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			grid.add_child(l)
		vb.add_child(grid)
		i += 9
	return vb

func _restyle() -> void:
	for h in _hits:
		var sb: StyleBoxFlat = h["style"]
		var base: Color = h["base"]
		if h["id"] == _flash:
			sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9)
		elif h["id"] == _hover:
			sb.bg_color = Color(minf(base.r + 0.1, 1.0), minf(base.g + 0.1, 1.0), minf(base.b + 0.1, 1.0), clampf(base.a + 0.12, 0.16, 1.0))
		else:
			sb.bg_color = base
	panel.refresh()
