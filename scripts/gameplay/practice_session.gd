extends Node3D
## Practice session: result card after every putt, a marker where the ball finished, and running session stats.
##
## xr_controller calls on_putt_started() when the virtual ball is struck and on_putt_finished() when it stops or drops.
## The node is top_level, so every position here is a world position.
##
## Result card (2026-09-23): a glass card (scripts/ui/glass_panel.gd) with one clear headline ("27 cm past"), the
## side miss underneath, then speed / start line / session average in three columns. It floats between the player and
## the finish spot at a comfortable reading distance, slightly below eye level, fades in, holds ~4 s, fades out.
## The finish marker stays until the next putt.

const BALL_R := 0.02135
const CARD_IN_S := 0.25
const CARD_HOLD_S := 4.0
const CARD_OUT_S := 0.6
const GOOD_LAG_PAST_M := 0.45 # coaches' lag target: stop 0-45 cm past the hole

const COL_HOLED := Color(0.36, 0.86, 0.47)   # green
const COL_GOOD := Color(0.35, 0.72, 1.0)     # blue
const COL_SHORT := Color(1.0, 0.66, 0.26)    # amber
const COL_LONG := Color(1.0, 0.80, 0.30)     # yellow
const TXT := Color(1, 1, 1, 0.96)
const TXT2 := Color(1, 1, 1, 0.62)
const TXT3 := Color(1, 1, 1, 0.45)

var putts := 0
var holed := 0
var streak := 0
var best_streak := 0
var _left_sum := 0.0 # summed distance left (m) over putts that were not holed
var _left_n := 0

var head_provider: Callable # returns the viewer's head position (world); set by xr_controller
var card: GlassPanel
var _marker: Node3D
var _ring_mat: StandardMaterial3D
var _card_t := -1.0 # time since shown; < 0 = hidden
var last_text := ""

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	card = GlassPanel.new(Vector2i(760, 400), 0.42)
	card.name = "ResultCard"
	add_child(card)
	card.set_alpha(0.0)
	_build_marker()

func reset_session() -> void:
	putts = 0
	holed = 0
	streak = 0
	best_streak = 0
	_left_sum = 0.0
	_left_n = 0
	_hide_card()
	_marker.visible = false

## Called when the virtual ball is struck: the previous result goes away.
func on_putt_started() -> void:
	_marker.visible = false
	_hide_card()

## final_pos: ball centre where it stopped (world). tee/cup: world positions. Returns a one-line summary (for logs).
func on_putt_finished(final_pos: Vector3, was_holed: bool, tee: Vector3, cup: Vector3, speed: float, angle_deg: float) -> String:
	putts += 1
	var line := Vector2(cup.x - tee.x, cup.z - tee.z)
	var putt_len := line.length()
	var dir := line.normalized() if putt_len > 0.01 else Vector2(0, -1)
	var right := Vector2(-dir.y, dir.x) # golfer looking from tee to cup (Godot: -Z forward, +X right)
	var off := Vector2(final_pos.x - cup.x, final_pos.z - cup.z)
	var along := off.dot(dir) # > 0: past the hole
	var side := off.dot(right) # > 0: right of the hole
	var left_m := off.length()

	var tag := ""
	var accent := COL_GOOD
	var headline := ""
	var subline := ""
	if was_holed:
		holed += 1
		streak += 1
		best_streak = maxi(best_streak, streak)
		tag = "HOLED"
		accent = COL_HOLED
		headline = "In the hole"
		subline = "%s putt" % _fmt_dist(putt_len)
		if streak >= 2:
			subline += " · %d in a row" % streak
	else:
		streak = 0
		_left_sum += left_m
		_left_n += 1
		headline = "%s %s" % [_fmt_dist(absf(along)), "past" if along >= 0.0 else "short"]
		if absf(side) >= 0.03:
			subline = "%s %s of the hole" % [_fmt_dist(absf(side)), "right" if side > 0.0 else "left"]
		else:
			subline = "Right on line"
		if along < 0.0:
			tag = "SHORT"
			accent = COL_SHORT
		elif along <= GOOD_LAG_PAST_M:
			tag = "GOOD PACE"
			accent = COL_GOOD
		else:
			tag = "TOO FIRM"
			accent = COL_LONG

	var start_txt := "On line" if absf(angle_deg) < 0.5 else "%.1f° %s" % [absf(angle_deg), "R" if angle_deg > 0.0 else "L"]
	var avg_txt := _fmt_dist(_left_sum / float(_left_n)) if _left_n > 0 else "–"
	var footer := "%d of %d holed" % [holed, putts]
	if best_streak >= 2:
		footer += " · best streak %d" % best_streak
	_build_card(tag, accent, "Putt %d" % putts, headline, subline,
		[["%.2f" % speed, "m/s"], [start_txt, ""], [avg_txt, ""]], ["Speed", "Start line", "Avg. left"], footer)

	_place_card(final_pos, tee)
	_card_t = 0.0

	_marker.global_position = Vector3(final_pos.x, final_pos.y - BALL_R + 0.002, final_pos.z)
	_ring_mat.albedo_color = Color(accent.r, accent.g, accent.b, 0.9)
	_marker.visible = not was_holed # a holed ball is in the cup; no marker on the green
	last_text = "%s | %s | %s | %.2f m/s · start %s | %s" % [tag, headline, subline, speed, start_txt, footer]
	return last_text

func _process(delta: float) -> void:
	if _card_t < 0.0:
		return
	_card_t += delta
	var a := 1.0
	var s := 1.0
	if _card_t < CARD_IN_S:
		var k := _card_t / CARD_IN_S
		a = k
		s = 0.94 + 0.06 * (1.0 - pow(1.0 - k, 3.0))
	elif _card_t > CARD_IN_S + CARD_HOLD_S:
		a = 1.0 - (_card_t - CARD_IN_S - CARD_HOLD_S) / CARD_OUT_S
	if a <= 0.0 and _card_t > CARD_IN_S:
		_hide_card()
		return
	card.set_alpha(a)
	card.scale = Vector3.ONE * s
	if head_provider.is_valid():
		card.face(head_provider.call())

func _hide_card() -> void:
	_card_t = -1.0
	if card != null:
		card.set_alpha(0.0)

## Between the viewer and the finish spot (a little to the right of that line), 0.9-1.5 m away, ~30 cm below the eyes.
func _place_card(final_pos: Vector3, tee: Vector3) -> void:
	var head := tee + Vector3(0.0, 1.6, 0.4)
	if head_provider.is_valid():
		head = head_provider.call()
	var to := Vector3(final_pos.x - head.x, 0.0, final_pos.z - head.z)
	var d := to.length()
	var dir := to / d if d > 0.01 else Vector3(0, 0, -1)
	# 22 deg to the side of the line to the ball, so the card never covers the hole or the flag
	var side := dir.rotated(Vector3.UP, deg_to_rad(-22.0))
	var dist := clampf(d * 0.6, 0.9, 1.5)
	card.global_position = Vector3(head.x, head.y - 0.30, head.z) + side * dist
	card.face(head)

func _build_card(tag: String, accent: Color, putt_no: String, headline: String, subline: String,
		values: Array, captions: Array, footer: String) -> void:
	card.clear_content()
	var c := card.content
	c.add_theme_constant_override("separation", 6)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	top.add_child(GlassPanel.make_dot(accent, 16))
	top.add_child(GlassPanel.make_label(tag, "Inter-SemiBold", 24, accent))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	top.add_child(GlassPanel.make_label(putt_no, "Inter-Medium", 24, TXT3))
	c.add_child(top)

	c.add_child(GlassPanel.make_label(headline, "InterDisplay-SemiBold", 76, TXT))
	c.add_child(GlassPanel.make_label(subline, "Inter-Regular", 32, TXT2))

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	c.add_child(gap)
	c.add_child(GlassPanel.make_rule(0.12))

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 0)
	for i in values.size():
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 0)
		var vrow := HBoxContainer.new()
		vrow.add_theme_constant_override("separation", 6)
		vrow.add_child(GlassPanel.make_label(str(values[i][0]), "Inter-SemiBold", 38, TXT))
		if str(values[i][1]) != "":
			var unit := GlassPanel.make_label(str(values[i][1]), "Inter-Medium", 24, TXT2)
			unit.size_flags_vertical = Control.SIZE_SHRINK_END
			vrow.add_child(unit)
		col.add_child(vrow)
		col.add_child(GlassPanel.make_label(str(captions[i]), "Inter-Regular", 22, TXT3))
		cols.add_child(col)
	c.add_child(cols)
	c.add_child(GlassPanel.make_label(footer, "Inter-Regular", 22, TXT3))
	card.refresh()

static func _fmt_dist(m: float) -> String:
	if m < 1.0:
		return "%d cm" % int(round(m * 100.0))
	return "%.1f m" % m

func _build_marker() -> void:
	_marker = Node3D.new()
	_marker.name = "FinishMarker"
	_marker.visible = false
	add_child(_marker)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.042
	tm.outer_radius = 0.048
	tm.rings = 48
	tm.ring_segments = 8
	ring.mesh = tm
	ring.scale = Vector3(1.0, 0.15, 1.0) # flat on the turf
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(COL_GOOD.r, COL_GOOD.g, COL_GOOD.b, 0.9)
	ring.material_override = _ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.add_child(ring)
	# ghost of the ball where it stopped (the real virtual ball is reset to the tee for the next putt)
	var ghost := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = BALL_R
	sm.height = BALL_R * 2.0
	ghost.mesh = sm
	ghost.position = Vector3(0.0, BALL_R - 0.002, 0.0)
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color = Color(1, 1, 1, 0.55)
	gm.roughness = 0.4
	ghost.material_override = gm
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.add_child(ghost)
