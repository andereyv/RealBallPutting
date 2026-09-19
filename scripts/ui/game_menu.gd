class_name GameMenu
extends Node3D

## 3D Spatial Game Menu for RealBallPutting Mixed Reality.
## Provides the startup experience: Game Info, Play, and Stance Selection.
## Usable with controllers or Meta Quest optical hand tracking pinches.

signal play_pressed()
signal handedness_selected(handedness: String)
signal menu_closed()

@onready var page_main: Node3D = $PageMain
@onready var page_stance: Node3D = $PageStance
@onready var play_btn_bg: MeshInstance3D = $PageMain/PlayButton/BtnBg
@onready var play_btn_label: Label3D = $PageMain/PlayButton/BtnLabel
@onready var card_right_bg: MeshInstance3D = $PageStance/CardRight/CardBg
@onready var card_left_bg: MeshInstance3D = $PageStance/CardLeft/CardBg

var hovered_target: String = "NONE"
var is_menu_active: bool = true

func _ready() -> void:
	show_main_page()

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
