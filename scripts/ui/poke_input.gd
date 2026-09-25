extends Node3D
## Direct touch ("poke") for glass panels, shared by the main menu and the palm menu (2026-09-24).
##
## Why: the 2026-09-23 recording showed hand-ray + pinch pressing things by itself. A relaxed hand held its
## thumb and index tips 25-32 mm apart for seconds, right on the 30 mm pinch threshold, so tiny jitter "pinched"
## (Settings -> Ball spot 0.47 s later without a real pinch). Real pinches measured 6-11 mm. Hands now touch the
## glass everywhere; rays are left to the controllers.
##
## How a press works:
##   1. the fingertip must first be in front of the glass (>= ARM_M) - a hand coming from behind or the side never presses
##   2. within HOVER_M the item under the fingertip lights up and a ring shows where the finger will land
##   3. within LOCK_M the target is locked, so the small slide of a finger pushing forward can't change it
##   4. crossing PRESS_M presses once; the finger must come back out past ARM_M before the next press

const HOVER_M := 0.07
const LOCK_M := 0.025
const PRESS_M := 0.006   # the tip joint sits ~7 mm inside the finger pad: this is the pad touching the glass
const ARM_M := 0.02
const BEHIND_M := -0.08
const EDGE_PX := 12.0

var _armed := {}
var _lock := {}
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D

func _ready() -> void:
	top_level = true
	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.8
	tm.outer_radius = 1.0
	tm.rings = 32
	tm.ring_segments = 6
	_ring.mesh = tm
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.no_depth_test = true
	_ring_mat.render_priority = 127
	_ring_mat.albedo_color = Color(1, 1, 1, 0.9)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)

func hide_cursor() -> void:
	_ring.visible = false

## panel: GlassPanel. tips: [{"key", "pos": Vector3}]. hit: Callable(px: Vector2) -> String (item id or "").
## Returns {"hover": String, "pressed": String, "near": bool (a fingertip is close to the glass)}.
func process(panel: GlassPanel, tips: Array, hit: Callable) -> Dictionary:
	var out := {"hover": "", "pressed": "", "near": false}
	var best_depth := 1e9
	var inv := panel.global_transform.affine_inverse()
	var w := float(panel.size_px.x)
	var h := float(panel.size_px.y)
	for t in tips:
		var key: String = t["key"]
		var local: Vector3 = inv * (t["pos"] as Vector3)
		var depth := local.z # + in front of the glass (towards the viewer)
		var px := Vector2((local.x / panel.width_m + 0.5) * w, (0.5 - local.y / panel.height_m()) * h)
		var inside := px.x > -EDGE_PX and px.y > -EDGE_PX and px.x < w + EDGE_PX and px.y < h + EDGE_PX
		if not inside:
			_armed[key] = false # sliding in from the side is not a press
			_lock[key] = ""
		elif depth > ARM_M:
			_armed[key] = true
			_lock[key] = ""
		if not inside or depth > HOVER_M or depth < BEHIND_M:
			continue
		out["near"] = true
		var id: String = hit.call(px)
		var locked: String = _lock.get(key, "")
		if depth <= LOCK_M:
			if locked == "" and _armed.get(key, false):
				locked = id
				_lock[key] = id
			if locked != "":
				id = locked
		if depth < best_depth:
			best_depth = depth
			out["hover"] = id
			_show_ring(panel, local, depth, id != "")
		if depth <= PRESS_M and _armed.get(key, false) and locked != "":
			_armed[key] = false
			out["pressed"] = locked
	if best_depth > 1e8:
		_ring.visible = false
	return out

func _show_ring(panel: GlassPanel, local: Vector3, depth: float, on_item: bool) -> void:
	_ring.visible = true
	var k := clampf(depth / HOVER_M, 0.0, 1.0)
	var r := lerpf(0.004, 0.013, k) # shrinks onto the spot as the finger closes in
	var p: Vector3 = panel.global_transform * Vector3(local.x, local.y, 0.002)
	var b := panel.global_transform.basis.orthonormalized()
	# torus lies in its local XZ plane -> turn it so it lies flat on the glass (glass normal = basis.z)
	_ring.global_transform = Transform3D(Basis(b.x * r, b.z * (r * 0.25), -b.y * r), p)
	_ring_mat.albedo_color = Color(1, 1, 1, lerpf(0.95, 0.35, k)) if on_item else Color(1, 1, 1, lerpf(0.5, 0.15, k))
