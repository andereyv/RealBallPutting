extends RefCounted
## Courses and their holes (2026-09-23).
##
## A course = scenery + a list of holes. A hole = which green (GreenProfile id) and where on it the ball and the cup
## are (green-local XZ, metres). The real ball spot never moves: the green is turned and shifted so the hole's ball
## position lands on the ball spot with the cup straight down the aimed line (test_green_controller.align_to_tee_box).
##
## Holes are generated from a fixed seed, so a course always has the same 18 holes. Every hole is par 2.

const PAR := 2

const COURSES := [
	{"id": "parkland", "name": "Parkland", "available": true, "scenery": "parkland",
		"blurb": "Tree-lined greens in the late afternoon sun"},
	{"id": "beach", "name": "Beach", "available": false, "scenery": "", "blurb": "Coming soon"},
	{"id": "mountains", "name": "Mountains", "available": false, "scenery": "", "blurb": "Coming soon"},
]

## Putt lengths of holes 1-18 (m). The first three make a quick 3-hole round with a mix of short, medium, long.
const HOLE_LENGTHS := [2.4, 4.2, 1.8, 5.5, 3.0, 2.2, 6.0, 3.6, 1.5, 3.2, 4.8, 2.0, 5.0, 2.8, 3.8, 1.6, 4.4, 6.5]
## Greens in blocks of three holes (a new green means rebuilding the mesh, so it changes only every third hole).
const HOLE_GREENS := ["championship_tiered", "breaking_slope", "lightning_fast"]

## Safe putting surface of the stock 14 x 9 m green: an ellipse well inside the fringe (the organic edge starts at
## about 2.8 x 4.7 m from the centre).
const SAFE_RX := 2.55
const SAFE_RZ := 4.45

## Cup spots (2026-09-24): the cup must sit on a gentle part of the green. Hole 2 of the parkland round had its cup on
## the face of the tier (~10 %): a missed putt could not stop near it and rolled back down, so putts of 0.8 m/s
## "went nowhere". Real pin positions are kept under ~3 %; the rings around the cup allow a little more.
const CUP_MAX_SLOPE := 0.035
const CUP_AREA_MAX_SLOPE := 0.045
static var _slope_cache := {}

static func cup_spot_ok(green: String, cup: Vector2) -> bool:
	var key := "%s|%.3f|%.3f" % [green, cup.x, cup.y]
	if not _slope_cache.has(key):
		var prof := GreenProfile.by_id(green)
		var at_cup := GreenGenerator.profile_max_slope(prof, cup, 0.0)
		var around := GreenGenerator.profile_max_slope(prof, cup, 0.5)
		_slope_cache[key] = at_cup <= CUP_MAX_SLOPE and around <= CUP_AREA_MAX_SLOPE
	return _slope_cache[key]

static func available_courses() -> Array:
	var out := []
	for c in COURSES:
		if c["available"]:
			out.append(c)
	return out

static func get_course(id: String) -> Dictionary:
	for c in COURSES:
		if c["id"] == id:
			return c
	return COURSES[0]

static func is_on_safe_green(p: Vector2, margin: float = 0.0) -> bool:
	var rx := SAFE_RX - margin
	var rz := SAFE_RZ - margin
	return (p.x * p.x) / (rx * rx) + (p.y * p.y) / (rz * rz) <= 1.0

## Pull a point back onto the safe surface (towards the cup) if a ball finished off it.
static func clamp_to_green(p: Vector2, towards: Vector2) -> Vector2:
	var q := p
	for i in 60:
		if is_on_safe_green(q):
			return q
		q = q.lerp(towards, 0.05)
	return towards

## The 18 holes of a course: [{"n", "green", "ball": Vector2, "cup": Vector2, "length", "par"}]
static func holes(course_id: String) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(course_id + "-holes-v2")
	var out := []
	for i in HOLE_LENGTHS.size():
		var length: float = HOLE_LENGTHS[i]
		var green: String = HOLE_GREENS[(i / 3) % HOLE_GREENS.size()]
		var hole := {}
		var tries := 0
		while hole.is_empty():
			tries += 1
			if tries > 2000:
				hole = {"n": i + 1, "green": green, "ball": Vector2(0.0, minf(length, 4.0)), "cup": Vector2.ZERO, "length": minf(length, 4.0), "par": PAR}
				break
			var l := length if tries < 200 else length * 0.8
			var cup := Vector2(rng.randf_range(-1.6, 1.6), rng.randf_range(-3.2, 2.6))
			if not is_on_safe_green(cup, 0.5):
				continue
			if tries < 1500 and not cup_spot_ok(green, cup):
				continue
			# mostly up or down the green (across the tier and the grade), sometimes across the slope
			var ang := rng.randf_range(-0.9, 0.9) + (PI if rng.randf() < 0.5 else 0.0)
			var ball := cup + Vector2(sin(ang), cos(ang)) * l
			if not is_on_safe_green(ball, 0.15):
				continue
			hole = {"n": i + 1, "green": green, "ball": ball, "cup": cup, "length": l, "par": PAR}
		out.append(hole)
	return out
