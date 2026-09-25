extends Node3D
## Palm-up hand menu (2026-09-23), replacing the floor buttons behind the tee that got pressed by accident while
## putting. Turn the menu hand's palm up towards your face and hold it for a moment: a glass panel appears above the
## hand. Touch a row with the index fingertip of the other hand to press it. Both hands on the putter never trigger it
## (palms face each other / down), and nothing lives on the floor any more.
##
## The host (xr_controller) provides:
##   menu_items() -> Array of {"id", "title", "value"}  or  {"id": "pin", "title", "value", "stepper": true}
##   menu_action(id: String)   ("pin_minus" / "pin_plus" for the stepper)

signal opened()
signal closed()

const OPEN_HOLD_S := 0.30
const CLOSE_HOLD_S := 0.45
const PRESS_DEPTH_M := 0.010   # fingertip within 1 cm of (or through) the glass = press
const HOVER_DEPTH_M := 0.07
const REARM_DEPTH_M := 0.025   # finger must come back this far before the next press
const PRESS_COOLDOWN_S := 0.30
const ROW_H := 84
const ACCENT := Color(0.35, 0.72, 1.0)

var host: Object
var menu_hand_is_left := true
var panel: GlassPanel
var is_open := false

var _pose_t := 0.0
var _away_t := 0.0
var _alpha := 0.0
var _sig := ""
var _hits := []            # [{"id", "ctrl": Control, "style": StyleBoxFlat}]
var _hover_id := ""
var _flash_id := ""
var _flash_t := 0.0
var _armed := true
var _cooldown := 0.0
var _debug_force_open := false # tests / desktop preview
var _pinned := false  # opened with the menu button: floats in front of the player instead of above the hand
var _pinned_idle := 0.0
var _poke # scripts/ui/poke_input.gd (same touch behaviour as the main menu)
var _hold_still := false # a fingertip is at the glass: the panel stops following the palm
const PINNED_IDLE_CLOSE_S := 8.0

func _ready() -> void:
	top_level = true
	# 0.26 m wide -> rows ~3.6 cm tall: a comfortable fingertip target (was 0.20 m / 2.2 cm rows, 2026-09-24)
	panel = GlassPanel.new(Vector2i(600, 780), 0.26)
	panel.name = "HandMenuPanel"
	add_child(panel)
	panel.set_alpha(0.0)
	_poke = preload("res://scripts/ui/poke_input.gd").new()
	add_child(_poke)

## Call every frame. menu_hand / poke_hand: xr_hand_visualizer nodes (may be null). head: viewer position.
func update(delta: float, menu_hand, poke_hand, head: Vector3, allowed: bool) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	var palm_ok := false
	var palm := Vector3.ZERO
	if allowed and menu_hand != null and menu_hand.is_hand_tracked and menu_hand.joint_ok(0):
		palm = menu_hand.joint(0)
		var n: Vector3 = menu_hand.palm_normal()
		var to_head := (head - palm).normalized()
		# palm facing the eyes (the natural "look at your hand" gesture, same as Meta's own menu gesture)
		# or palm up; the hand must be below the eyes
		palm_ok = (n.dot(to_head) > 0.55 or (n.y > 0.55 and n.dot(to_head) > 0.20)) and palm.y < head.y - 0.10
		# both hands together on the putter grip is never a menu gesture
		if palm_ok and poke_hand != null and poke_hand.is_hand_tracked and poke_hand.joint_ok(0):
			if poke_hand.joint(0).distance_to(palm) < 0.09:
				palm_ok = false
	if _debug_force_open or _pinned:
		palm_ok = true

	var finger_near := false
	var tip := Vector3.ZERO
	if poke_hand != null and poke_hand.is_hand_tracked and poke_hand.joint_ok(10):
		tip = poke_hand.joint(10) # JOINT_INDEX_TIP
		finger_near = is_open and panel.global_position.distance_to(tip) < 0.25

	if palm_ok:
		_pose_t += delta
		_away_t = 0.0
	else:
		_pose_t = 0.0
		if not finger_near:
			_away_t += delta

	if _pinned:
		_pinned_idle = 0.0 if finger_near else _pinned_idle + delta
		if _pinned_idle >= PINNED_IDLE_CLOSE_S:
			_pinned = false
			palm_ok = false
			_away_t = CLOSE_HOLD_S
	if not is_open and _pose_t >= OPEN_HOLD_S:
		is_open = true
		_sig = ""
		opened.emit()
	elif is_open and _away_t >= CLOSE_HOLD_S:
		is_open = false
		_pinned = false
		_hover_id = ""
		closed.emit()

	_alpha = move_toward(_alpha, 1.0 if is_open else 0.0, delta / 0.18)
	panel.set_alpha(_alpha)
	if _alpha <= 0.0:
		_poke.hide_cursor()
		return

	# follow the palm (only while the palm is still up; otherwise hold still so the finger can reach it).
	# Shifted towards the other hand, so it doesn't sit on Meta's own menu icon at the pinch point.
	if palm_ok and not _debug_force_open and not _pinned and not _hold_still:
		var right := (head - palm).cross(Vector3.UP).normalized() * (-1.0 if menu_hand_is_left else 1.0)
		var target := palm + Vector3.UP * (0.07 + panel.height_m() * 0.5) + right * 0.09
		panel.global_position = panel.global_position.lerp(target, clampf(delta * 14.0, 0.0, 1.0)) if _alpha > 0.05 else target
	if not _hold_still:
		panel.face(head)

	_rebuild_if_needed()
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash_id = ""
			_restyle()

	var new_hover := ""
	_hold_still = false
	if is_open and poke_hand != null and poke_hand.is_hand_tracked and poke_hand.joint_ok(10):
		var res: Dictionary = _poke.process(panel, [{"key": "poke", "pos": poke_hand.joint(10)}], _hit)
		_hold_still = res["near"]
		new_hover = res["hover"]
		var hit_id: String = res["pressed"]
		if hit_id != "" and _cooldown <= 0.0:
			_cooldown = PRESS_COOLDOWN_S
			_flash_id = hit_id
			_flash_t = 0.25
			if host != null and host.has_method("menu_action"):
				host.call("menu_action", hit_id)
			_sig = "" # values change -> rebuild
	else:
		_poke.hide_cursor()
	if new_hover != _hover_id:
		_hover_id = new_hover
		_restyle()

## Menu button (controller, or Meta's own menu gesture on the hand): open in front of the player / close again.
func toggle_pinned(head: Vector3, forward: Vector3) -> void:
	if is_open:
		_pinned = false
		_pose_t = 0.0
		_away_t = CLOSE_HOLD_S
		return
	var f := Vector3(forward.x, 0.0, forward.z)
	f = f.normalized() if f.length() > 0.01 else Vector3(0, 0, -1)
	panel.global_position = head + f * 0.42 + Vector3.UP * -0.28
	_pinned = true
	_pinned_idle = 0.0
	_pose_t = OPEN_HOLD_S

## Build the rows once, invisible, so fonts and the panel are ready before the first real open.
func prewarm() -> void:
	_rebuild_if_needed()
	panel.refresh()

## Force a rebuild (after an action changed a value outside the menu).
func invalidate() -> void:
	_sig = ""

func _hit(px: Vector2) -> String:
	for h in _hits:
		var c: Control = h["ctrl"]
		if is_instance_valid(c) and c.get_global_rect().has_point(px):
			return h["id"]
	return ""

func _rebuild_if_needed() -> void:
	var items: Array = host.call("menu_items") if host != null and host.has_method("menu_items") else []
	var sig := JSON.stringify(items) + (str(host.call("menu_title")) if host != null and host.has_method("menu_title") else "")
	if sig == _sig:
		return
	_sig = sig
	panel.clear_content()
	_hits.clear()
	var c := panel.content
	c.add_theme_constant_override("separation", 10)
	var title: String = host.call("menu_title") if host != null and host.has_method("menu_title") else "Practice"
	c.add_child(GlassPanel.make_label(title, "Inter-SemiBold", 30, Color(1, 1, 1, 0.55)))
	for it in items:
		if it.get("stepper", false):
			c.add_child(_stepper_row(it))
		else:
			c.add_child(_row(it))
	_restyle()
	panel.fit_height_to_content(200, 1200)

func _row_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.07)
	sb.set_corner_radius_all(24)
	sb.anti_aliasing = true
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	return sb

func _row(it: Dictionary) -> Control:
	var pc := PanelContainer.new()
	var sb := _row_style()
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(0, ROW_H)
	var hb := HBoxContainer.new()
	hb.add_child(GlassPanel.make_label(str(it["title"]), "Inter-Medium", 32, Color(1, 1, 1, 0.96)))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(sp)
	if str(it.get("value", "")) != "":
		hb.add_child(GlassPanel.make_label(str(it["value"]), "Inter-Regular", 28, Color(1, 1, 1, 0.55)))
	for l in hb.get_children():
		if l is Label:
			l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pc.add_child(hb)
	_hits.append({"id": str(it["id"]), "ctrl": pc, "style": sb})
	return pc

func _stepper_row(it: Dictionary) -> Control:
	var hb := HBoxContainer.new()
	hb.custom_minimum_size = Vector2(0, ROW_H)
	hb.add_theme_constant_override("separation", 10)
	var id := str(it["id"])
	for part in ["minus", "value", "plus"]:
		var pc := PanelContainer.new()
		var sb := _row_style()
		sb.content_margin_left = 0
		sb.content_margin_right = 0
		pc.add_theme_stylebox_override("panel", sb)
		var lbl: Label
		if part == "value":
			pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sb.bg_color = Color(1, 1, 1, 0.0)
			var vb := VBoxContainer.new()
			vb.alignment = BoxContainer.ALIGNMENT_CENTER
			vb.add_theme_constant_override("separation", -4)
			var t := GlassPanel.make_label(str(it["title"]), "Inter-Regular", 22, Color(1, 1, 1, 0.55))
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl = GlassPanel.make_label(str(it["value"]), "Inter-SemiBold", 34, Color(1, 1, 1, 0.96))
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			vb.add_child(t)
			vb.add_child(lbl)
			pc.add_child(vb)
		else:
			pc.custom_minimum_size = Vector2(ROW_H + 30, ROW_H)
			lbl = GlassPanel.make_label("−" if part == "minus" else "+", "Inter-Medium", 44, Color(1, 1, 1, 0.96))
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			pc.add_child(lbl)
			_hits.append({"id": "%s_%s" % [id, part], "ctrl": pc, "style": sb})
		hb.add_child(pc)
	return hb

func _restyle() -> void:
	for h in _hits:
		var sb: StyleBoxFlat = h["style"]
		if h["id"] == _flash_id:
			sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.55)
		elif h["id"] == _hover_id:
			sb.bg_color = Color(1, 1, 1, 0.18)
		else:
			sb.bg_color = Color(1, 1, 1, 0.07)
	panel.refresh()
