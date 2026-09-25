extends RefCounted
## Score keeping for a round (2026-09-23). Par 2 on every green; a hole ends when the ball drops, when it stops
## within gimme range (counted as one more putt), or after MAX_PUTTS (picked up).

const Catalog = preload("res://scripts/gameplay/course_catalog.gd")
const MAX_PUTTS := 5
const GIMME_M := 0.30

var course_id := "parkland"
var holes: Array = []      # this round's holes (from Catalog.holes)
var index := 0             # current hole (0-based)
var strokes := 0           # putts on the current hole so far
var scores: Array = []     # putts per finished hole
var first_putt_left: Array = [] # distance left after the first putt (m) on holes not one-putted
var gimmes := 0
var active := false

func start(course: String, n_holes: int) -> void:
	course_id = course
	var all: Array = Catalog.holes(course)
	holes = all.slice(0, clampi(n_holes, 1, all.size()))
	index = 0
	strokes = 0
	scores = []
	first_putt_left = []
	gimmes = 0
	active = true

func hole() -> Dictionary:
	return holes[index] if index < holes.size() else {}

func hole_count() -> int:
	return holes.size()

func is_last_hole() -> bool:
	return index >= holes.size() - 1

## A putt was struck and came to rest (or dropped). Returns "holed", "gimme", "picked_up" or "" (play on).
func putt_finished(was_holed: bool, dist_left: float) -> String:
	strokes += 1
	if was_holed:
		return "holed"
	if strokes == 1:
		first_putt_left.append(dist_left)
	if dist_left <= GIMME_M:
		strokes += 1
		gimmes += 1
		return "gimme"
	if strokes >= MAX_PUTTS:
		return "picked_up"
	return ""

## Close the current hole; returns its score.
func finish_hole() -> int:
	var s := strokes
	scores.append(s)
	strokes = 0
	return s

## Move on; false when the round is over.
func next_hole() -> bool:
	index += 1
	strokes = 0
	if index >= holes.size():
		active = false
		return false
	return true

func total_putts() -> int:
	var t := 0
	for s in scores:
		t += int(s)
	return t

func to_par() -> int:
	return total_putts() - Catalog.PAR * scores.size()

func count_scores(pred: Callable) -> int:
	var n := 0
	for s in scores:
		if pred.call(int(s)):
			n += 1
	return n

func avg_first_putt_left() -> float:
	if first_putt_left.is_empty():
		return -1.0
	var t := 0.0
	for d in first_putt_left:
		t += float(d)
	return t / float(first_putt_left.size())

static func fmt_to_par(v: int) -> String:
	if v == 0:
		return "E"
	return ("+%d" % v) if v > 0 else str(v)

static func score_name(putts: int, par: int = Catalog.PAR) -> String:
	match putts - par:
		-1: return "Birdie"
		0: return "Par"
		1: return "Bogey"
		2: return "Double bogey"
		3: return "Triple bogey"
	return "%d putts" % putts
