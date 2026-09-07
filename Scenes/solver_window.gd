## The window that watches a puzzle being ground out.
##
## Solving a time lock is the only thing this app does that takes hours or days
## rather than seconds. Reported as a line of text on the panel that started it,
## the reader had to leave that panel open and sit in front of it to know
## anything was happening at all — and a line that says "42%" for twenty minutes
## is indistinguishable from a hang.
##
## So it gets a window of its own: one this app owns, beside it rather than on
## top of it, which can be pushed aside and left running while the keeper gets
## on with something else.
##
## It has no cancel, deliberately. The host has no way to stop a solve once it
## has started, so a button offering to would be a lie. Closing this window
## leaves the work running and the answer still arrives in the app; closing the
## app is what loses the climb, and the window says so while it runs.

class_name SolverWindow
extends Window

var display: PuzzleDisplay

var _button: Button
var _finished := false


## Opens the window beside the app. `expected` is the duration the keeper was
## quoted when they sealed it.
static func open_beside(host: Node, covenant_title: String, expected: String) -> SolverWindow:
	var window := SolverWindow.new()
	window.title = "Solving '%s'" % covenant_title
	# Carried over explicitly rather than left to propagation: a progress bar
	# drawn in a proportional font does not line up.
	if host is Control and (host as Control).theme != null:
		window.theme = (host as Control).theme
	window._build(covenant_title, expected)

	host.add_child(window)

	# A window the desktop knows about rather than one drawn inside the app's,
	# so it can be moved aside, or behind, like any other. Godot embeds child
	# windows by default; this asks for a real one, and stays embedded,
	# silently, on a display server that has no such thing.
	if DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS):
		host.get_tree().root.gui_embed_subwindows = false

	window.show()
	# Centred on the next idle frame rather than now: a window still in the
	# middle of being added has no screen to be centred on yet.
	window.call_deferred("move_to_center")
	return window


func _build(covenant_title: String, expected: String) -> void:
	# Not exclusive and not transient: this must not sit on top of the app, or
	# it is just a modal dialog with extra steps.
	exclusive = false
	transient = false
	unresizable = false
	size = Vector2i(660, 520)
	min_size = Vector2i(560, 460)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	add_child(panel)

	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	margin.add_child(box)

	box.add_child(
		TempleTheme.line(
			"— THE PUZZLE OF '%s' —" % covenant_title.to_upper(),
			TempleTheme.YELLOW,
			TempleTheme.SIZE_BODY
		)
	)

	display = PuzzleDisplay.new()
	box.add_child(display)
	display.begin(
		expected,
		"This window can be pushed aside, or closed — the climb carries on either "
		+ "way, and the word appears in Burning Bush when it opens. Closing "
		+ "BURNING BUSH is what loses it, and starts it over from nothing."
	)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	_button = TempleTheme.button("LEAVE IT RUNNING", _dismiss)
	row.add_child(_button)

	box.add_child(
		TempleTheme.line(Scripture.puzzle_verse(), TempleTheme.RED, TempleTheme.SIZE_SMALL)
	)

	# Closing by the titlebar means the same as the button: get out of the way,
	# keep climbing.
	close_requested.connect(_dismiss)


## The host's latest reading.
func report(percent: float) -> void:
	if not _finished:
		display.report(percent)


## Solved. The word itself belongs in the app, where the covenant was opened,
## so there is nothing left for this window to say.
func solved() -> void:
	_finished = true
	queue_free()


## The climb ended without a key. Says why and waits to be dismissed, because
## an error that closes itself is an error nobody read.
func failed(reason: String) -> void:
	if _finished:
		return
	_finished = true
	display.finish("STOPPED", reason, TempleTheme.BRIGHT_RED)
	_button.text = "CLOSE"
	title = "Stopped"


func _dismiss() -> void:
	# On a finished window this is the only way out; on a running one it hides
	# the watching, not the work.
	if _finished:
		queue_free()
		return
	hide()
