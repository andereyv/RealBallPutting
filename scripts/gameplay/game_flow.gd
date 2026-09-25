extends Node
## Game flow (2026-09-23): main menu -> practice or a round -> summary.
##
##   First launch: Welcome -> Which way do you putt? -> set up the ball spot -> Home
##   Home: Continue (resume the round / carry on practising), Practice, Play a round, Settings
##   Start: the saved ball spot is reused (no alignment step); set it up only if there is none yet
##   Round: hole intro -> putt -> the green slides so the ball's new spot sits on the ball spot -> ... -> hole card
##          -> next hole ... -> round summary (scorecard)
##
## The host is xr_controller.gd. It forwards ball results (on_putt_finished), the ball-spot confirmation
## (on_spot_confirmed) and the palm-menu rows/actions (palm_items / palm_action), and provides
## flow_enter_menu() / flow_start_play() / flow_realign().

const MenuScreen = preload("res://scripts/ui/menu_screen.gd")
const Catalog = preload("res://scripts/gameplay/course_catalog.gd")
const Round = preload("res://scripts/gameplay/round_session.gd")
const CFG_PATH := "user://game_flow.cfg"

const COL_GREEN := Color(0.36, 0.86, 0.47)
const COL_BLUE := Color(0.35, 0.72, 1.0)
const COL_AMBER := Color(1.0, 0.66, 0.26)
const TXT := Color(1, 1, 1, 0.96)
const TXT2 := Color(1, 1, 1, 0.62)
const TXT3 := Color(1, 1, 1, 0.45)
const SPEED_OPTIONS := [
	{"id": "green", "label": "Course"}, {"id": "mat", "label": "My mat"}, {"id": "slow", "label": "Slow"},
	{"id": "normal", "label": "Normal"}, {"id": "fast", "label": "Fast"},
]
const PRACTICE_GREEN := "championship_tiered"
const CARD_HOLD_S := 3.2
const HOLE_CARD_S := 3.4

var host: Node
var menu: Node3D
var card: GlassPanel
var mode := ""            # "" (nothing started this session), "practice", "round"
var rnd = null          # scripts/gameplay/round_session.gd while a round is on
var page := ""
var first_launch := false

# preferences (saved)
var practice_course := "parkland"
var round_course := "parkland"
var round_holes := 9
var round_speed := "green"
var practiced_before := false

var _round_ball := Vector2.ZERO # where the ball is on the current hole (green-local)
var _pending := ""        # what to do once the ball spot is confirmed: "home", "practice", "round", "resume"
var _seq := 0             # bumps on every mode / hole change; stale timers check it
var _card_t := -1.0
var _card_hold := CARD_HOLD_S
var _trig_down := {}

func _ready() -> void:
	menu = MenuScreen.new()
	menu.name = "MenuScreen"
	menu.host = self
	add_child(menu)
	card = GlassPanel.new(Vector2i(760, 360), 0.42)
	card.name = "HoleCard"
	card.top_level = true
	add_child(card)
	card.set_alpha(0.0)
	_load_prefs()

# ================================================================== entry points (from the host)
func boot() -> void:
	first_launch = not bool(host.get("has_completed_welcome"))
	if first_launch:
		_show("welcome")
	else:
		_show("home")

## xr_controller: confirm_tee_placement() finished (ball spot set / re-aligned).
func on_spot_confirmed() -> void:
	var p := _pending
	_pending = ""
	match p:
		"practice", "round":
			_enter_play(p, true)
		"home":
			_show("home")
		_:
			# "resume", or a re-align started some other way (controller button): back to what was being played
			if mode != "":
				_enter_play(mode, false)
			else:
				_show("home")

## Every frame (host's _update_ui_layer).
func update(delta: float) -> void:
	var head: Vector3 = host.call("flow_head")
	var fwd: Vector3 = host.call("flow_forward")
	menu.update(delta, head, fwd, _pointers(), _tips())
	_update_card(delta, head)

## A putt came to rest (or dropped). Returns true when the flow shows its own card (the practice card is skipped).
func on_putt_finished(final_pos: Vector3, was_holed: bool, cup_world: Vector3) -> bool:
	if mode != "round" or rnd == null or not rnd.active:
		return false
	var left := Vector2(final_pos.x - cup_world.x, final_pos.z - cup_world.z).length()
	var outcome: String = rnd.putt_finished(was_holed, left)
	var h: Dictionary = rnd.hole()
	_log("ROUND: hole %d putt %d -> %s (%.2f m left)" % [h.get("n", 0), rnd.strokes, outcome if outcome != "" else "play on", left])
	if outcome == "":
		# play on from where it stopped: after a moment the green slides so that spot sits on the ball spot
		_set_practice_footer("Hole %d · putt %d" % [h["n"], rnd.strokes], _round_status())
		var s := _seq
		get_tree().create_timer(1.3).timeout.connect(func():
			if s == _seq and mode == "round":
				_replay_from(final_pos))
		return false
	_finish_hole(outcome)
	return true

# ================================================================== palm menu (while playing)
func palm_title() -> String:
	if mode == "round" and rnd != null and rnd.active:
		return "Hole %d of %d" % [rnd.index + 1, rnd.hole_count()]
	return "Practice"

func palm_items() -> Array:
	var items := []
	if mode == "round":
		items.append({"id": "restart_hole", "title": "Restart hole", "value": ""})
		items.append({"id": "skip_hole", "title": "Skip hole", "value": "counts %d" % Round.MAX_PUTTS})
	else:
		items.append({"id": "pin", "title": "Pin distance", "value": "%.1f m" % float(host.get("pin_distance_m")), "stepper": true})
		items.append({"id": "speed", "title": "Green speed", "value": host.call("_speed_label")})
		items.append({"id": "strength", "title": "Putt distance", "value": host.call("putt_distance_label"), "stepper": true})
	items.append({"id": "scenery", "title": "Scenery", "value": host.call("scenery_label")})
	items.append({"id": "room_edge", "title": "Room edge", "value": host.call("room_edge_label")})
	items.append({"id": "realign", "title": "Re-align ball spot", "value": ""})
	items.append({"id": "main_menu", "title": "Main menu", "value": ""})
	if bool(host.get("developer_mode")):
		items.append({"id": "simulate", "title": "Simulate putt", "value": ""})
	return items

## Returns true if handled here (otherwise the host handles it).
func palm_action(id: String) -> bool:
	match id:
		"main_menu":
			_log("MENU: main menu")
			_show("home")
			return true
		"realign", "adjust_tee":
			_pending = "resume"
			_seq += 1
			_hide_card()
			host.call("flow_realign")
			return true
		"restart_hole":
			if mode == "round" and rnd != null:
				rnd.strokes = 0
				_begin_hole(false)
			return true
		"skip_hole":
			if mode == "round" and rnd != null:
				rnd.strokes = Round.MAX_PUTTS
				_finish_hole("skipped")
			return true
	return false

# ================================================================== menu pages
func menu_screen_action(id: String) -> void:
	_log("MENU: %s (%s)" % [id, page])
	if host.has_method("_play_menu_click"):
		host.call("_play_menu_click")
	var parts := id.split(":")
	match parts[0]:
		"back":
			_show("settings" if (page == "hand" and not first_launch) or page == "perf" else "home")
		"get_started":
			_show("hand")
		"hand_right", "hand_left":
			var h := "right" if parts[0] == "hand_right" else "left"
			host.call("set_golfer_handedness", h)
			if first_launch:
				first_launch = false
				host.set("has_completed_welcome", true)
				host.call("_save_tee_box_settings")
				if not bool(host.get("is_tee_confirmed")):
					_pending = "home"
					menu.hide_menu()
					host.call("flow_realign")
					return
				_show("home")
			else:
				_show("settings")
		"continue":
			if mode == "round" and rnd != null and rnd.active:
				_start("resume")
			else:
				_start("practice")
		"practice":
			_show("practice")
		"round":
			_show("round")
		"settings":
			_show("settings")
		"perf":
			_show("perf")
		"course":
			_show(page) # one course for now; the row lists what is coming
		"speed":
			if page == "round":
				round_speed = parts[1]
			else:
				host.call("_apply_green_speed", parts[1], false)
				host.call("_save_tee_box_settings")
			_save_prefs()
			_show(page, false)
		"holes":
			round_holes = int(parts[1])
			_save_prefs()
			_show(page, false)
		"start_practice":
			_start("practice_new")
		"start_round", "play_again":
			rnd = Round.new()
			rnd.start(round_course, round_holes)
			_start("round")
		"set_hand":
			_show("hand")
		"set_spot":
			_pending = "home"
			menu.hide_menu()
			host.call("flow_realign")
		"set_scenery":
			host.call("cycle_scenery")
			_show(page, false)
		"set_edge":
			host.call("cycle_room_edge")
			_show(page, false)
		"set_distance":
			host.call("cycle_putt_distance")
			_show(page, false)
		"set_record":
			host.set("auto_record_sessions", not bool(host.get("auto_record_sessions")))
			host.call("_save_tee_box_settings")
			_show(page, false)
		"set_hz":
			host.call("cycle_refresh_rate")
			_show(page, false)
		"set_shadows", "set_flow", "set_fov", "set_res":
			match parts[0]:
				"set_res":
					var steps := [1.0, 0.9, 0.8, 0.7]
					var cur := float(host.get("render_scale"))
					var k := 0
					for i in steps.size():
						if absf(steps[i] - cur) < 0.01:
							k = i
					host.set("render_scale", steps[(k + 1) % steps.size()])
				"set_shadows": host.set("shadows_on", not bool(host.get("shadows_on")))
				"set_flow": host.set("flow_lines_on", not bool(host.get("flow_lines_on")))
				"set_fov": host.set("foveation_level", (int(host.get("foveation_level")) + 1) % 4)
			host.call("apply_performance_settings")
			host.call("_save_tee_box_settings")
			_show(page, false)
		"set_fps":
			host.set("show_fps", not bool(host.get("show_fps")))
			host.call("_save_tee_box_settings")
			_show(page, false)
		"set_dev":
			host.set("developer_mode", not bool(host.get("developer_mode")))
			host.call("_save_tee_box_settings")
			_show(page, false)
		"home":
			_show("home")

func _show(p: String, reposition: bool = true) -> void:
	if page != p:
		reposition = true
	page = p
	host.call("flow_enter_menu")
	_hide_card()
	menu.show_page(p, _model(p), host.call("flow_head"), host.call("flow_forward"), reposition)

func _model(p: String) -> Dictionary:
	match p:
		"welcome":
			return {"title": "Welcome", "subtitle": "Putt a real ball onto a virtual green.", "items": [
				{"type": "text", "text": "You need your putter, a ball, and a spot on the floor you putt from. We'll mark that spot in a moment."},
				{"type": "button", "id": "get_started", "title": "Get started"}]}
		"hand":
			return {"title": "How do you putt?", "subtitle": "You can change this later in Settings.", "back": not first_launch, "items": [
				{"type": "cards", "items": [
					{"id": "hand_left", "title": "Left-handed", "subtitle": "Target on your right"},
					{"id": "hand_right", "title": "Right-handed", "subtitle": "Target on your left"}]}]}
		"home":
			var items := [_continue_item(),
				{"type": "row", "id": "practice", "title": "Practice", "value": ""},
				{"type": "row", "id": "round", "title": "Play a round", "value": "Par 2 greens"},
				{"type": "row", "id": "settings", "title": "Settings", "value": ""}]
			return {"title": "Real Ball Putting", "subtitle": Catalog.get_course(practice_course)["name"], "items": items}
		"practice":
			return {"title": "Practice", "subtitle": "Same putt again and again. Pin and speed are in your palm menu.", "back": true, "items": [
				_course_row(practice_course),
				{"type": "seg", "id": "speed", "title": "Green speed", "options": SPEED_OPTIONS, "selected": str(host.get("green_speed_mode"))},
				{"type": "button", "id": "start_practice", "title": "Start practice"}]}
		"round":
			return {"title": "Play a round", "subtitle": "Par 2 on every green. Putts within 30 cm are given.", "back": true, "items": [
				_course_row(round_course),
				{"type": "seg", "id": "holes", "title": "Holes", "options": [
					{"id": "3", "label": "3"}, {"id": "9", "label": "9"}, {"id": "18", "label": "18"}], "selected": str(round_holes)},
				{"type": "seg", "id": "speed", "title": "Green speed", "options": SPEED_OPTIONS, "selected": round_speed},
				{"type": "button", "id": "start_round", "title": "Start round"}]}
		"settings":
			return {"title": "Settings", "back": true, "items": [
				{"type": "row", "id": "set_hand", "title": "Putting hand", "value": "Right" if str(host.get("golfer_handedness")) == "right" else "Left"},
				{"type": "row", "id": "set_spot", "title": "Ball spot", "value": "Set up again" if bool(host.get("is_tee_confirmed")) else "Not set"},
				{"type": "row", "id": "set_scenery", "title": "Scenery", "value": host.call("scenery_label")},
				{"type": "row", "id": "set_edge", "title": "Room edge", "value": host.call("room_edge_label")},
				{"type": "row", "id": "set_distance", "title": "Putt distance", "value": host.call("putt_distance_label")},
				{"type": "row", "id": "set_record", "title": "Record sessions", "value": "On" if bool(host.get("auto_record_sessions")) else "Off"},
				{"type": "row", "id": "perf", "title": "Performance", "value": "%d Hz" % int(float(host.get("display_hz")))},
				{"type": "row", "id": "set_dev", "title": "Developer view", "value": "On" if bool(host.get("developer_mode")) else "Off"}]}
		"perf":
			return {"title": "Performance", "subtitle": "Watch the FPS counter while you switch these. Resolution may need an app restart.", "back": true, "items": [
				{"type": "row", "id": "set_hz", "title": "Refresh rate", "value": "%d Hz" % int(float(host.get("display_hz")))},
				{"type": "row", "id": "set_fps", "title": "FPS counter", "value": "On" if bool(host.get("show_fps")) else "Off"},
				{"type": "row", "id": "set_scenery", "title": "Scenery", "value": host.call("scenery_label")},
				{"type": "row", "id": "set_shadows", "title": "Shadows", "value": "On" if bool(host.get("shadows_on")) else "Off"},
				{"type": "row", "id": "set_flow", "title": "Flow lines", "value": "On" if bool(host.get("flow_lines_on")) else "Off"},
				{"type": "row", "id": "set_fov", "title": "Foveation", "value": ["Off", "Low", "Medium", "High"][clampi(int(host.get("foveation_level")), 0, 3)]},
				{"type": "row", "id": "set_res", "title": "Resolution", "value": "%d %%" % int(round(float(host.get("render_scale")) * 100.0))}]}
		"summary":
			return _summary_model()
	return {"title": p}

func _continue_item() -> Dictionary:
	if mode == "round" and rnd != null and rnd.active:
		var sub := "Hole %d of %d" % [rnd.index + 1, rnd.hole_count()]
		if rnd.scores.size() > 0:
			sub += " · %s thru %d" % [Round.fmt_to_par(rnd.to_par()), rnd.scores.size()]
		return {"type": "hero", "id": "continue", "title": "Continue round", "subtitle": sub}
	var st: String = host.call("_speed_label")
	var sub2 := "%s · pin %.1f m · %s" % [Catalog.get_course(practice_course)["name"], float(host.get("pin_distance_m")), st.split(" · ")[0]]
	return {"type": "hero", "id": "continue", "title": "Continue practice" if (mode == "practice" or practiced_before) else "Start practising", "subtitle": sub2}

func _course_row(course_id: String) -> Dictionary:
	var more := Catalog.COURSES.size() > Catalog.available_courses().size()
	return {"type": "row", "id": "course", "title": "Course", "value": Catalog.get_course(course_id)["name"] + (" · more coming" if more else "")}

func _summary_model() -> Dictionary:
	if rnd == null:
		return {"title": "Round complete"}
	var tp: int = rnd.to_par()
	var one: int = rnd.count_scores(func(s): return s <= 1)
	var three: int = rnd.count_scores(func(s): return s >= 3)
	var avg: float = rnd.avg_first_putt_left()
	var avg_txt := "–" if avg < 0.0 else _fmt_dist(avg)
	var n: int = rnd.scores.size()
	return {"title": "Round complete", "subtitle": "%s · %d holes · %d putts" % [Catalog.get_course(rnd.course_id)["name"], n, rnd.total_putts()], "items": [
		{"type": "stats", "values": [[Round.fmt_to_par(tp), "To par"], [str(one), "One-putts"], [str(three), "Three-putts"], [avg_txt, "Avg. first-putt miss"]]},
		{"type": "scorecard", "scores": rnd.scores, "par": Catalog.PAR},
		{"type": "button", "id": "play_again", "title": "Play again"},
		{"type": "button", "id": "home", "title": "Main menu", "style": "plain"}]}

# ================================================================== starting / playing
## activity: "practice" (carry on), "practice_new" (fresh stats), "round" (new round set up), "resume"
func _start(activity: String) -> void:
	var what := activity
	if activity == "resume":
		what = mode if mode != "" else "practice"
	menu.hide_menu()
	if activity == "practice_new" and host.get("_practice") != null:
		host.get("_practice").call("reset_session")
	if what == "practice_new":
		what = "practice"
	if not bool(host.get("is_tee_confirmed")):
		_pending = what
		mode = what
		host.call("flow_realign")
		return
	_enter_play(what, activity != "resume")

func _enter_play(what: String, fresh: bool) -> void:
	_seq += 1
	var from_mode := mode
	mode = what
	var tgc = host.get("test_green_controller")
	var prac = host.get("_practice")
	if what == "practice":
		practiced_before = true
		_save_prefs()
		_set_practice_footer("", "")
		if from_mode == "round" and prac != null:
			prac.call("reset_session")
		_load_green(PRACTICE_GREEN)
		host.call("_apply_green_speed", str(host.get("green_speed_mode")), false)
		if tgc != null:
			tgc.call("clear_hole_layout")
			tgc.call("set_flag_number", 0)
		host.call("flow_start_play")
		_log("FLOW: practice")
	else:
		if rnd == null or not rnd.active:
			rnd = Round.new()
			rnd.start(round_course, round_holes)
		if prac != null:
			prac.call("reset_session")
		_speed_for_round()
		if fresh:
			_begin_hole(true)
		else:
			_resume_hole()

func _speed_for_round() -> void:
	# the round's speed is its own choice; the practice speed stays saved for practice
	var cm = host.call("_get_course_manager")
	if cm != null:
		cm.call("set_green_speed", round_speed, float(host.get("physical_mat_stimp")))

## Set up the current hole from its start. intro: show the hole card.
func _begin_hole(intro: bool = true) -> void:
	_seq += 1
	var h: Dictionary = rnd.hole()
	if h.is_empty():
		return
	rnd.strokes = 0
	_round_ball = h["ball"]
	_load_green(str(h["green"]))
	_speed_for_round()
	var tgc = host.get("test_green_controller")
	if tgc != null:
		tgc.call("set_hole_layout", h["ball"], h["cup"], false)
		tgc.call("set_flag_number", int(h["n"]))
	host.call("flow_start_play")
	var prac = host.get("_practice")
	if prac != null:
		prac.call("hide_marker")
	_set_practice_footer("Hole %d · putt 1" % h["n"], _round_status())
	_log("ROUND: hole %d of %d (%s, %.1f m)" % [h["n"], rnd.hole_count(), h["green"], float(h["length"])])
	if intro:
		_show_intro_card()

## Back to the hole where it was left (the green may have been swapped for practice in between).
func _resume_hole() -> void:
	_seq += 1
	var h: Dictionary = rnd.hole()
	_load_green(str(h["green"]))
	_speed_for_round()
	var tgc = host.get("test_green_controller")
	if tgc != null:
		tgc.call("set_hole_layout", _round_ball, h["cup"], false)
		tgc.call("set_flag_number", int(h["n"]))
	host.call("flow_start_play")
	_set_practice_footer("Hole %d · putt %d" % [h["n"], rnd.strokes + 1], _round_status())
	_show_intro_card()

## After a missed putt: the ball's resting spot becomes the new ball position (green slides under the ball spot).
func _replay_from(final_pos: Vector3) -> void:
	var tgc = host.get("test_green_controller")
	if tgc == null:
		return
	var gg: Node3D = tgc.get("green_generator")
	var lp: Vector3 = gg.to_local(final_pos)
	var h: Dictionary = rnd.hole()
	var cup: Vector2 = h["cup"]
	var ball := Catalog.clamp_to_green(Vector2(lp.x, lp.z), cup)
	var prac = host.get("_practice")
	if prac != null:
		prac.call("hide_marker")
	_round_ball = ball
	tgc.call("set_hole_layout", ball, cup, true)
	_set_practice_footer("Hole %d · putt %d" % [h["n"], rnd.strokes + 1], _round_status())
	var d := ball.distance_to(cup)
	_log("ROUND: next putt from %.2f m" % d)

func _finish_hole(outcome: String) -> void:
	_seq += 1
	var h: Dictionary = rnd.hole()
	var score: int = rnd.finish_hole()
	var name := Round.score_name(score)
	var accent := COL_GREEN if score < Catalog.PAR else (COL_BLUE if score == Catalog.PAR else COL_AMBER)
	var sub := "%d putt%s" % [score, "" if score == 1 else "s"]
	match outcome:
		"gimme": sub += " · last one given"
		"picked_up": sub = "Picked up · counts %d" % score
		"skipped": sub = "Skipped · counts %d" % score
	var tag := "HOLE %d" % int(h["n"])
	var foot := "%s thru %d" % [Round.fmt_to_par(rnd.to_par()), rnd.scores.size()]
	if rnd.is_last_hole():
		foot += " · last hole"
	_build_card(tag, accent, "Par %d" % Catalog.PAR, name, sub, foot)
	_log("HOLE %d: %s (%d) %s" % [h["n"], name, score, foot])
	if host.has_method("_play_lock_chime") and outcome != "holed":
		host.call("_play_lock_chime")
	var s := _seq
	get_tree().create_timer(HOLE_CARD_S).timeout.connect(func():
		if s != _seq or mode != "round":
			return
		if rnd.next_hole():
			_begin_hole(true)
		else:
			_log("ROUND COMPLETE: %s, %d putts" % [Round.fmt_to_par(rnd.to_par()), rnd.total_putts()])
			_show("summary"))

func _show_intro_card() -> void:
	var h: Dictionary = rnd.hole()
	var tgc = host.get("test_green_controller")
	var lay: Array = tgc.call("current_layout") if tgc != null else [h["ball"], h["cup"]]
	var ball: Vector2 = lay[0]
	var cup: Vector2 = lay[1]
	var d := ball.distance_to(cup)
	var slope := "level"
	if tgc != null:
		var gg = tgc.get("green_generator")
		var rise: float = float(gg.call("get_surface_height", cup.x, cup.y)) - float(gg.call("get_surface_height", ball.x, ball.y))
		if absf(rise) >= 0.01:
			slope = "%d cm %s" % [int(round(absf(rise) * 100.0)), "uphill" if rise > 0.0 else "downhill"]
	var foot := "First hole" if rnd.scores.is_empty() else "%s thru %d" % [Round.fmt_to_par(rnd.to_par()), rnd.scores.size()]
	if rnd.strokes > 0:
		foot = "Putt %d" % (rnd.strokes + 1)
	_build_card("HOLE %d OF %d" % [int(h["n"]), rnd.hole_count()], COL_BLUE, "Par %d" % Catalog.PAR, _fmt_dist(d), slope[0].to_upper() + slope.substr(1), foot)

func _load_green(profile_id: String) -> void:
	var cm = host.call("_get_course_manager")
	if cm == null:
		return
	var cur = cm.call("get_current_profile")
	if cur != null and str(cur.get("id")) == profile_id:
		return
	var profiles: Array = cm.call("get_available_profiles")
	for i in profiles.size():
		if str(profiles[i].get("id")) == profile_id:
			cm.call("load_green_by_index", i)
			return

func _round_status() -> String:
	if rnd == null or rnd.scores.is_empty():
		return "Par %d" % Catalog.PAR
	return "%s thru %d" % [Round.fmt_to_par(rnd.to_par()), rnd.scores.size()]

func _set_practice_footer(title: String, footer: String) -> void:
	var prac = host.get("_practice")
	if prac != null:
		prac.set("title_override", title)
		prac.set("footer_override", footer)

# ================================================================== hole card
func _build_card(tag: String, accent: Color, right: String, headline: String, subline: String, footer: String) -> void:
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
	top.add_child(GlassPanel.make_label(right, "Inter-Medium", 24, TXT3))
	c.add_child(top)
	c.add_child(GlassPanel.make_label(headline, "InterDisplay-SemiBold", 80, TXT))
	c.add_child(GlassPanel.make_label(subline, "Inter-Regular", 32, TXT2))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	c.add_child(gap)
	c.add_child(GlassPanel.make_rule(0.12))
	c.add_child(GlassPanel.make_label(footer, "Inter-Regular", 26, TXT3))
	card.refresh()
	_place_card()
	_card_t = 0.0
	var prac = host.get("_practice")
	if prac != null:
		prac.call("_hide_card")

func _place_card() -> void:
	var head: Vector3 = host.call("flow_head")
	var tgc = host.get("test_green_controller")
	var cup: Vector3 = tgc.call("cup_world") if tgc != null else head + Vector3(0, -1.5, -2.0)
	var to := Vector3(cup.x - head.x, 0.0, cup.z - head.z)
	var dir := to.normalized() if to.length() > 0.05 else Vector3(0, 0, -1)
	var side := dir.rotated(Vector3.UP, deg_to_rad(-22.0))
	card.global_position = Vector3(head.x, head.y - 0.28, head.z) + side * 1.1
	card.face(head)

func _update_card(delta: float, head: Vector3) -> void:
	if _card_t < 0.0:
		return
	_card_t += delta
	if _card_t < 0.35:
		_place_card() # follows the head while it fades in (the hole may start while you look elsewhere)
	var a := 1.0
	if _card_t < 0.25:
		a = _card_t / 0.25
	elif _card_t > 0.25 + _card_hold:
		a = 1.0 - (_card_t - 0.25 - _card_hold) / 0.6
	if a <= 0.0 and _card_t > 0.25:
		_hide_card()
		return
	card.set_alpha(a)
	card.face(head)

func prewarm() -> void:
	_build_card("HOLE 1 OF 9", COL_BLUE, "Par 2", "Birdie 4.2 m", "11 cm downhill · 2 putts", "+1 thru 3 · last hole")
	_hide_card()

func card_visible() -> bool:
	return _card_t >= 0.0

func _hide_card() -> void:
	_card_t = -1.0
	card.set_alpha(0.0)

# ================================================================== input for the menu
## Controller rays only: hands touch the glass directly (a hand ray + pinch pressed things by itself, 2026-09-23)
func _pointers() -> Array:
	var out := []
	for side in ["right", "left"]:
		var hv = host.get("right_hand_vis" if side == "right" else "left_hand_vis")
		var ctrl = host.get("right_controller" if side == "right" else "left_controller")
		if hv != null and bool(hv.get("is_hand_tracked")):
			continue
		if ctrl != null and ctrl.call("get_is_active"):
			var t: Transform3D = ctrl.get("global_transform")
			var trig := float(ctrl.call("get_float", "trigger"))
			var key: String = side + "_ctrl"
			var was: bool = _trig_down.get(key, false)
			var down := trig >= 0.6 or (was and trig > 0.35)
			_trig_down[key] = down
			out.append({"key": key, "pos": t.origin, "dir": -t.basis.z, "pressed": down})
	return out

func _tips() -> Array:
	var out := []
	for side in ["right", "left"]:
		var hv = host.get("right_hand_vis" if side == "right" else "left_hand_vis")
		if hv != null and bool(hv.get("is_hand_tracked")) and hv.has_method("joint_ok") and hv.call("joint_ok", 10):
			out.append({"key": side, "pos": hv.call("joint", 10)})
	return out

# ================================================================== misc
func _log(t: String) -> void:
	print("[GameFlow] ", t)
	if host != null and host.has_method("_record_event"):
		host.call("_record_event", t)

static func _fmt_dist(m: float) -> String:
	if m < 1.0:
		return "%d cm" % int(round(m * 100.0))
	return "%.1f m" % m

func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	practice_course = str(cfg.get_value("flow", "practice_course", practice_course))
	round_course = str(cfg.get_value("flow", "round_course", round_course))
	round_holes = int(cfg.get_value("flow", "round_holes", round_holes))
	round_speed = str(cfg.get_value("flow", "round_speed", round_speed))
	practiced_before = bool(cfg.get_value("flow", "practiced_before", practiced_before))

func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("flow", "practice_course", practice_course)
	cfg.set_value("flow", "round_course", round_course)
	cfg.set_value("flow", "round_holes", round_holes)
	cfg.set_value("flow", "round_speed", round_speed)
	cfg.set_value("flow", "practiced_before", practiced_before)
	cfg.save(CFG_PATH)
