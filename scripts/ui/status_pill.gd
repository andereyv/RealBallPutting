extends Node3D
## Small glass status pill near the tee: "Place the ball", "Ready", "Ball not seen", short notices.
## One line of text (+ an optional second, smaller line) after a coloured dot. Transient messages fade out on their own.

var pill: GlassPanel
var _key := ""
var _hold := -1.0    # seconds left before fading; < 0 = stays
var _alpha := 0.0
var _target := 0.0
var _expired := false # the current transient message has already been shown and faded

func _ready() -> void:
	top_level = true
	pill = GlassPanel.new(Vector2i(600, 140), 0.28)
	pill.corner_radius_px = 60
	pill.padding_px = 26
	add_child(pill)
	pill.set_alpha(0.0)

## Show a status. hold_s < 0 keeps it until something else is shown or hide() is called.
func show_status(title: String, sub: String, color: Color, hold_s: float = -1.0) -> void:
	var key := "%s|%s|%s" % [title, sub, color.to_html()]
	if key != _key:
		_key = key
		pill.clear_content()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.add_child(GlassPanel.make_dot(color, 20))
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", -2)
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		col.add_child(GlassPanel.make_label(title, "Inter-SemiBold", 42 if sub == "" else 36, Color(1, 1, 1, 0.96)))
		if sub != "":
			col.add_child(GlassPanel.make_label(sub, "Inter-Regular", 26, Color(1, 1, 1, 0.62)))
		row.add_child(col)
		pill.content.add_child(row)
		pill.refresh()
		pill.fit_width_to_content()
		_hold = hold_s
		_expired = false
	if not _expired:
		_target = 1.0

func hide_status() -> void:
	_target = 0.0
	_key = ""

func place(pos: Vector3, head: Vector3) -> void:
	global_position = pos
	pill.face(head)

func _process(delta: float) -> void:
	if _hold > 0.0 and _target > 0.0:
		_hold -= delta
		if _hold <= 0.0:
			_target = 0.0
			_expired = true
	_alpha = move_toward(_alpha, _target, delta / 0.25)
	pill.set_alpha(_alpha)
