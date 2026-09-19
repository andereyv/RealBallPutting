class_name CourseManager
extends Node

## Master Course & Green Catalog Coordinator for RealBallPutting.
## Manages loading, switching, and generating different championship putting greens,
## syncing terrain geometry, hole placement, and turf friction to the game environment.

signal green_loaded(profile: GreenProfile)
signal green_catalog_updated()

@export_group("Target Nodes")
@export var green_generator: GreenGenerator
@export var test_green_controller: TestGreenController
@export var golf_ball: GolfBallPhysics
@export var match_physical_mat: bool = true ## When true, matches physical synthetic putting mat felt (Stimp 14.5)

var _catalog: Array[GreenProfile] = []
var _current_profile: GreenProfile = null
var _current_index: int = 0

func _ready() -> void:
	_init_catalog()
	# Apply default championship profile if not set
	if _catalog.size() > 0:
		_current_profile = _catalog[1] # Championship Two-Tier as standard default

func _init_catalog() -> void:
	_catalog.clear()
	_catalog.append(GreenProfile.create_flat_practice())
	_catalog.append(GreenProfile.create_championship_tiered())
	_catalog.append(GreenProfile.create_breaking_slope())
	_catalog.append(GreenProfile.create_augusta_fast())
	green_catalog_updated.emit()
	print("[CourseManager] Catalog initialized with %d green profiles." % _catalog.size())

## Returns the full list of available greens
func get_available_profiles() -> Array[GreenProfile]:
	return _catalog

## Returns the active green profile
func get_current_profile() -> GreenProfile:
	return _current_profile

## Registers an additional custom GreenProfile into the catalog
func register_profile(profile: GreenProfile) -> void:
	if profile != null and not _catalog.has(profile):
		_catalog.append(profile)
		green_catalog_updated.emit()

## Loads a green by index in the catalog
func load_green_by_index(idx: int) -> bool:
	if idx >= 0 and idx < _catalog.size():
		_current_index = idx
		return load_green(_catalog[idx])
	return false

## Cycles to the next green in the catalog
func cycle_next_green() -> GreenProfile:
	if _catalog.is_empty():
		return null
	_current_index = (_current_index + 1) % _catalog.size()
	load_green(_catalog[_current_index])
	return _catalog[_current_index]

## Applies a GreenProfile to the active scene, regenerating geometry & updating physics
func load_green(profile: GreenProfile) -> bool:
	if profile == null:
		return false
	
	_current_profile = profile
	print("[CourseManager] Loading green: '%s' (%s, Stimp: %.1f)" % [profile.display_name, profile.difficulty, profile.stimp_speed])
	
	# 1. Update GreenGenerator parameters (single batch apply)
	if green_generator != null:
		green_generator.apply_profile(profile)
	
	# 2. Update Ball Physics Stimp Rating
	if golf_ball != null:
		if match_physical_mat:
			golf_ball.stimp_rating = 14.5
			print("[CourseManager] Turf Stimp calibrated to 14.5 (matching physical putting mat)")
		else:
			golf_ball.stimp_rating = profile.stimp_speed
		if green_generator != null:
			golf_ball.init_with_green(green_generator)
	
	# 3. Synchronize Course Alignment with TestGreenController
	if test_green_controller != null:
		test_green_controller._align_scene_elements()
	
	green_loaded.emit(profile)
	return true
