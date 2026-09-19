class_name GreenProfile
extends Resource

## Data model defining the shape, slope, physics, and difficulty of a putting green.
## Used by CourseManager and GreenGenerator to instantiate and swap championship greens.

@export_group("Identity")
@export var id: String = "championship_tiered"
@export var display_name: String = "Championship Tiered Green"
@export_multiline var description: String = "Tournament-caliber green with an authentic two-tier transition ridge and gentle cross-break."
@export_enum("Beginner", "Intermediate", "Championship", "Tournament") var difficulty: String = "Championship"

@export_group("Dimensions & Resolution")
@export var green_length: float = 14.0
@export var green_width: float = 9.0
@export var resolution_x: int = 140
@export var resolution_z: int = 220

@export_group("Slope & Undulation Profile")
@export var overall_grade_slope: float = 0.012 ## Back-to-front rise (~1.2%)
@export var cross_break_strength: float = 0.06 ## Left-to-right borrow
@export var tier_ridge_height: float = 0.12 ## Authentic 12cm step transition
@export var noise_amplitude: float = 0.035 ## Natural micro-swales
@export var noise_frequency: float = 0.25

@export_group("Fringe & Shape")
@export var fringe_width: float = 0.85
@export var organic_edge_variance: float = 0.45

@export_group("Hole Placement")
@export var cup_position_xz: Vector2 = Vector2(0.0, 0.0) ## Cup offset in local green coordinates
@export var cup_radius: float = 0.054 ## Regulation 4.25" cup (r = 54mm)
@export var cup_depth: float = 0.12

@export_group("Turf Physics")
@export var stimp_speed: float = 11.0 ## Stimp rating (feet of roll on level stimpmeter)
@export var rolling_friction_override: float = 0.0 ## If > 0, overrides stimp friction

## Factory: Flat Practice Green (Ideal for stroke calibration & beginner training)
static func create_flat_practice() -> GreenProfile:
	var p := GreenProfile.new()
	p.id = "practice_flat"
	p.display_name = "Practice Flat Green"
	p.description = "Dead-level putting green surface with minimal break. Perfect for dialling in pace and calibration."
	p.difficulty = "Beginner"
	p.overall_grade_slope = 0.002
	p.cross_break_strength = 0.005
	p.tier_ridge_height = 0.0
	p.noise_amplitude = 0.008
	p.stimp_speed = 14.5
	p.cup_position_xz = Vector2(0.0, 0.0)
	return p

## Factory: Championship Tiered Green (Default tournament layout)
static func create_championship_tiered() -> GreenProfile:
	var p := GreenProfile.new()
	p.id = "championship_tiered"
	p.display_name = "Championship Two-Tier Green"
	p.description = "Two-tier tournament layout with a 12 cm ridge between collection bowl and upper shelf."
	p.difficulty = "Championship"
	p.overall_grade_slope = 0.012
	p.cross_break_strength = 0.06
	p.tier_ridge_height = 0.12
	p.noise_amplitude = 0.035
	p.stimp_speed = 11.5
	p.cup_position_xz = Vector2(0.0, 0.0)
	return p

## Factory: Breaking Slope Challenge (Significant side-to-side borrow)
static func create_breaking_slope() -> GreenProfile:
	var p := GreenProfile.new()
	p.id = "breaking_slope"
	p.display_name = "Highlands Breaking Slope"
	p.description = "Severe left-to-right sweep requiring calculated aim points and high touch."
	p.difficulty = "Intermediate"
	p.overall_grade_slope = 0.018
	p.cross_break_strength = 0.14
	p.tier_ridge_height = 0.04
	p.noise_amplitude = 0.025
	p.stimp_speed = 10.8
	p.cup_position_xz = Vector2(0.35, -0.2)
	return p

## Factory: Augusta Lightning Fast (High stimp, undulating greens)
static func create_augusta_fast() -> GreenProfile:
	var p := GreenProfile.new()
	p.id = "augusta_fast"
	p.display_name = "Augusta Championship Speed"
	p.description = "Ultra-slick bentgrass greens running at 13.5 on the Stimp. Lightning-fast downhill rolls."
	p.difficulty = "Tournament"
	p.overall_grade_slope = 0.015
	p.cross_break_strength = 0.08
	p.tier_ridge_height = 0.09
	p.noise_amplitude = 0.04
	p.stimp_speed = 13.5
	p.cup_position_xz = Vector2(-0.25, 0.15)
	return p
