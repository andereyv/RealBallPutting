class_name GameMenu
extends Node3D

## 3D Spatial Game Menu for RealBallPutting Mixed Reality.
## Provides the startup experience: Game Info, Play, and Stance Selection.
## Usable with controllers or Meta Quest optical hand tracking pinches.

signal play_pressed()
signal handedness_selected(handedness: String)
signal menu_closed()
signal green_speed_selected(mode: String)
signal record_session_toggled(enabled: bool)

@onready var page_main: Node3D = $PageMain
@onready var page_stance: Node3D = $PageStance
@onready var play_btn_bg: MeshInstance3D = $PageMain/PlayButton/BtnBg
@onready var play_btn_label: Label3D = $PageMain/PlayButton/BtnLabel
@onready var card_right_bg: MeshInstance3D = $PageStance/CardRight/CardBg
@onready var card_left_bg: MeshInstance3D = $PageStance/CardLeft/CardBg

var hovered_target: String = "NONE"
var is_menu_active: bool = true

# Green speed selector (row of buttons on the stance page), built in code
const SPEED_BTN_X := [-0.30, -0.15, 0.0, 0.15, 0.30]
const SPEED_BTN_Y := -0.235
const SPEED_BTN_W := 0.14
const SPEED_BTN_H := 0.05
var _speed_modes: Array = []   # [{"id","label","stimp"}] from CourseManager presets
var _speed_btns: Array = []    # [{"bg": MeshInstance3D, "label": Label3D}]
var _selected_speed: String = "mat"

# RECORD SESSION toggle (stance page, above the stance cards)
const REC_BTN_Y := 0.068
const REC_BTN_W := 0.34
const REC_BTN_H := 0.05
var _rec_btn_bg: MeshInstance3D = null
var _rec_btn_label: Label3D = null
var record_session_enabled := false
var _rec_toggle_latched := false # one toggle per pinch/trigger press

func _ready() -> void:
	show_main_page()

## Builds (once) the green speed buttons. presets: Array of {"id","label","stimp"} with the speed already resolved
## (stimp < 0 = mat, kept for older callers).
func setup_green_speed_selector(presets: Array, selected: String, mat_stimp: float) -> void:
	if page_stance == null:
		return
	_speed_modes = presets
	_selected_speed = selected
	_ensure_record_toggle()
	if _speed_btns.is_empty():
		var title := Label3D.new()
		title.text = "GREEN SPEED  (thumbstick click changes it during play)"
		title.pixel_size = 0.001
		title.font_size = 12
		title.outline_size = 4
		title.modulate = Color(0.6, 0.9, 0.8, 1)
		title.position = Vector3(0.0, -0.2, 0.006)
		page_stance.add_child(title)
		for i in mini(presets.size(), SPEED_BTN_X.size()):
			var root := Node3D.new()
			root.position = Vector3(SPEED_BTN_X[i], SPEED_BTN_Y, 0.006)
			page_stance.add_child(root)
			var bg := MeshInstance3D.new()
			var q := QuadMesh.new()
			q.size = Vector2(SPEED_BTN_W, SPEED_BTN_H)
			bg.mesh = q
			var m := StandardMaterial3D.new()
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			bg.material_override = m
			root.add_child(bg)
			var lbl := Label3D.new()
			lbl.pixel_size = 0.001
			lbl.font_size = 13
			lbl.outline_size = 4
			lbl.position = Vector3(0, 0, 0.002)
			root.add_child(lbl)
			_speed_btns.append({"bg": bg, "label": lbl})
	for i in mini(presets.size(), _speed_btns.size()):
		var st: float = float(presets[i]["stimp"])
		if st < 0.0:
			st = mat_stimp
		_speed_btns[i]["label"].text = "%s\nspeed %.1f" % [presets[i]["label"], st]
	_update_visual_states()

func _ensure_record_toggle() -> void:
	if _rec_btn_bg != null or page_stance == null:
		return
	var root := Node3D.new()
	root.position = Vector3(0.0, REC_BTN_Y, 0.006)
	page_stance.add_child(root)
	_rec_btn_bg = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(REC_BTN_W, REC_BTN_H)
	_rec_btn_bg.mesh = q
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rec_btn_bg.material_override = m
	root.add_child(_rec_btn_bg)
	_rec_btn_label = Label3D.new()
	_rec_btn_label.pixel_size = 0.001
	_rec_btn_label.font_size = 14
	_rec_btn_label.outline_size = 4
	_rec_btn_label.position = Vector3(0, 0, 0.002)
	root.add_child(_rec_btn_label)
	_update_visual_states()

func set_record_session_enabled(on: bool) -> void:
	record_session_enabled = on
	_update_visual_states()

func set_selected_green_speed(mode: String) -> void:
	_selected_speed = mode
	_update_visual_states()

## Displays Page 1: Main Menu
func show_main_page() -> void:
	is_menu_active = true
	visible = true
	if page_main != null: page_main.visible = true
	if page_stance != null: page_stance.visible = false
	hovered_target = "NONE"
	_update_visual_states()
	print("[GameMenu] Displaying Main Menu (Stage 1)")

## Displays Page 2: Handedness / Stance Selection
func show_stance_page() -> void:
	is_menu_active = true
	visible = true
	if page_main != null: page_main.visible = false
	if page_stance != null: page_stance.visible = true
	hovered_target = "NONE"
	_update_visual_states()
	print("[GameMenu] Displaying Stance Selection (Stage 2)")

## Hides the entire menu
func hide_menu() -> void:
	is_menu_active = false
	visible = false
	menu_closed.emit()
	print("[GameMenu] Menu closed.")

## Dynamically positions the 3D menu panel 1.15m in front of the headset
func position_in_front_of(cam_pos: Vector3, cam_forward: Vector3) -> void:
	var fwd_flat := Vector3(cam_forward.x, 0.0, cam_forward.z).normalized()
	if fwd_flat == Vector3.ZERO:
		fwd_flat = Vector3.FORWARD
	
	global_position = cam_pos + fwd_flat * 1.15
	global_position.y = max(0.95, cam_pos.y - 0.08) # Slightly below eye level for comfortable ergonomic viewing
	look_at(cam_pos, Vector3.UP)
	rotate_object_local(Vector3.UP, PI) # Flip front face to look directly towards player

## Processes pointer rays from hands or controllers
## Returns a Dictionary with {"hovered": String, "laser_to": Vector3, "hit": bool}
func process_pointer_ray(ray_origin: Vector3, ray_dir: Vector3, is_trigger: bool) -> Dictionary:
	var res := {
		"hovered": "NONE",
		"laser_to": Vector3.ZERO,
		"hit": false
	}
	if not is_menu_active or not visible:
		return res
	
	var panel_norm := global_transform.basis.z # Panel outward normal facing the player
	var denom := panel_norm.dot(ray_dir)
	if denom >= -0.01:
		return res # Facing away or parallel
		
	var t := panel_norm.dot(global_position - ray_origin) / denom
	if t <= 0.08 or t >= 4.0:
		return res # Out of distance range
		
	var hit_world := ray_origin + ray_dir * t
	var hit_local := global_transform.affine_inverse() * hit_world
	
	# Slate bounds check: 0.86m wide x 0.56m tall
	if abs(hit_local.x) > 0.44 or abs(hit_local.y) > 0.29:
		return res
		
	res["hit"] = true
	res["laser_to"] = hit_world
	
	var cur_hover := "NONE"
	if page_main != null and page_main.visible:
		# Test [ PLAY ] button: x in [-0.17, 0.17], y in [-0.22, -0.11]
		if abs(hit_local.x) <= 0.17 and hit_local.y >= -0.22 and hit_local.y <= -0.11:
			cur_hover = "PLAY_BTN"
			if is_trigger:
				play_pressed.emit()
				show_stance_page()
				return res
	elif page_stance != null and page_stance.visible:
		# RECORD SESSION toggle
		if _rec_btn_bg != null and absf(hit_local.x) <= REC_BTN_W * 0.5 and absf(hit_local.y - REC_BTN_Y) <= REC_BTN_H * 0.5:
			cur_hover = "REC_TOGGLE"
			if is_trigger and not _rec_toggle_latched:
				_rec_toggle_latched = true
				record_session_enabled = not record_session_enabled
				record_session_toggled.emit(record_session_enabled)
			elif not is_trigger:
				_rec_toggle_latched = false
			hovered_target = cur_hover
			res["hovered"] = cur_hover
			_update_visual_states()
			return res
		_rec_toggle_latched = false
		# Green speed buttons row
		for i in mini(_speed_modes.size(), _speed_btns.size()):
			if absf(hit_local.x - SPEED_BTN_X[i]) <= SPEED_BTN_W * 0.5 and absf(hit_local.y - SPEED_BTN_Y) <= SPEED_BTN_H * 0.5:
				cur_hover = "SPEED_" + str(_speed_modes[i]["id"])
				if is_trigger and _selected_speed != str(_speed_modes[i]["id"]):
					_selected_speed = str(_speed_modes[i]["id"])
					green_speed_selected.emit(_selected_speed)
				hovered_target = cur_hover
				res["hovered"] = cur_hover
				_update_visual_states()
				return res
		# Test Card Right: x in [0.03, 0.38], y in [-0.19, 0.01]
		if hit_local.x >= 0.03 and hit_local.x <= 0.38 and hit_local.y >= -0.19 and hit_local.y <= 0.01:
			cur_hover = "STANCE_RIGHT"
			if is_trigger:
				handedness_selected.emit("right")
				hide_menu()
				return res
		# Test Card Left: x in [-0.38, -0.03], y in [-0.19, 0.01]
		elif hit_local.x >= -0.38 and hit_local.x <= -0.03 and hit_local.y >= -0.19 and hit_local.y <= 0.01:
			cur_hover = "STANCE_LEFT"
			if is_trigger:
				handedness_selected.emit("left")
				hide_menu()
				return res

	hovered_target = cur_hover
	res["hovered"] = cur_hover
	_update_visual_states()
	return res

func _update_visual_states() -> void:
	if _rec_btn_bg != null:
		var rm: StandardMaterial3D = _rec_btn_bg.material_override
		if record_session_enabled:
			rm.albedo_color = Color(0.85, 0.1, 0.1, 0.95)
			_rec_btn_label.text = "● RECORD SESSION: ON"
		elif hovered_target == "REC_TOGGLE":
			rm.albedo_color = Color(0.45, 0.12, 0.12, 0.95)
			_rec_btn_label.text = "● RECORD SESSION: OFF"
		else:
			rm.albedo_color = Color(0.25, 0.07, 0.07, 0.90)
			_rec_btn_label.text = "● RECORD SESSION: OFF"
	# Green speed buttons
	for i in mini(_speed_modes.size(), _speed_btns.size()):
		var sid := str(_speed_modes[i]["id"])
		var m: StandardMaterial3D = _speed_btns[i]["bg"].material_override
		if sid == _selected_speed:
			m.albedo_color = Color(0.08, 0.82, 0.40, 0.95)
		elif hovered_target == "SPEED_" + sid:
			m.albedo_color = Color(0.1, 0.35, 0.28, 0.95)
		else:
			m.albedo_color = Color(0.05, 0.16, 0.12, 0.90)
	# Update Play Button Highlight
	if play_btn_bg != null and play_btn_bg.material_override is StandardMaterial3D:
		var mat: StandardMaterial3D = play_btn_bg.material_override
		if hovered_target == "PLAY_BTN":
			mat.albedo_color = Color(0.12, 1.0, 0.55, 0.98) # Bright emerald
			play_btn_bg.get_parent().scale = Vector3(1.05, 1.05, 1.0)
		else:
			mat.albedo_color = Color(0.08, 0.82, 0.40, 0.90) # Standard emerald
			play_btn_bg.get_parent().scale = Vector3(1.0, 1.0, 1.0)
			
	# Update Right Card Highlight
	if card_right_bg != null and card_right_bg.material_override is StandardMaterial3D:
		var r_mat: StandardMaterial3D = card_right_bg.material_override
		if hovered_target == "STANCE_RIGHT":
			r_mat.albedo_color = Color(0.1, 0.35, 0.28, 0.95)
			card_right_bg.get_parent().scale = Vector3(1.04, 1.04, 1.0)
		else:
			r_mat.albedo_color = Color(0.05, 0.16, 0.12, 0.90)
			card_right_bg.get_parent().scale = Vector3(1.0, 1.0, 1.0)

	# Update Left Card Highlight
	if card_left_bg != null and card_left_bg.material_override is StandardMaterial3D:
		var l_mat: StandardMaterial3D = card_left_bg.material_override
		if hovered_target == "STANCE_LEFT":
			l_mat.albedo_color = Color(0.1, 0.35, 0.28, 0.95)
			card_left_bg.get_parent().scale = Vector3(1.04, 1.04, 1.0)
		else:
			l_mat.albedo_color = Color(0.05, 0.16, 0.12, 0.90)
			card_left_bg.get_parent().scale = Vector3(1.0, 1.0, 1.0)
