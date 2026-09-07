## What a puzzle being ground out looks like.
##
## Kept apart from the window that holds it because they answer different
## questions: [SolverWindow] is about where the thing sits on the desktop and
## what closing it means, and this is about what it says. The formatting below
## is the part worth testing, and it is testable because it lives here.
##
## The number is enormous on purpose. A covenant's state is meant to be readable
## across the room — that is why the bush is drawn the size it is — and a climb
## somebody is going to glance at over four days deserves the same. The clock
## under it is the load-bearing part: the host reports whole percentages, so on
## a day-long puzzle a single reading stands unchanged for a quarter of an hour,
## and a number that has not moved in fifteen minutes is indistinguishable from
## a hang. Seconds ticking are the proof that something is still happening.

class_name PuzzleDisplay
extends VBoxContainer

## Width of the bar, in characters. Drawn in text like everything else here: a
## themed ProgressBar would be the one rounded, anti-aliased thing in the app.
const BAR_CELLS := 44
const BAR_FULL := "#"
const BAR_EMPTY := "."

## The one number this window exists to show. Larger than any other type in the
## app, because everything else here is a footnote to it.
const SIZE_PERCENT := 64

## An estimate needs a rate, and a rate needs both some progress to divide by
## and some time to have divided. Under either it says nothing, rather than
## promising four days and then eleven minutes.
const ESTIMATE_AFTER_PERCENT := 1.0
const ESTIMATE_AFTER_SECONDS := 10

var _percent_label: Label
var _bar_label: Label
var _elapsed_label: Label
var _left_label: Label
var _readings: HBoxContainer
var _note_label: Label

var _started_msec := 0
var _percent := 0.0
var _running := false
## The second the clock last showed. Redrawing every frame would rebuild the
## same strings sixty times a second for a display that changes once.
var _shown_second := -1


## Builds the display and starts its clock. `expected` is the duration the
## keeper was quoted when they sealed it, which was measured on their machine
## and is labelled as such. `note` is what closing this particular window means,
## which differs between the two things that show one.
func begin(expected: String, note: String) -> void:
	add_theme_constant_override("separation", 6)

	_percent_label = TempleTheme.line("0%", TempleTheme.CYAN, SIZE_PERCENT)
	add_child(_percent_label)

	_bar_label = TempleTheme.line(progress_bar(0.0), TempleTheme.YELLOW, TempleTheme.SIZE_BODY)
	_bar_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	add_child(_bar_label)

	# Two readings, side by side and labelled, rather than one sentence: this is
	# a thing to glance at, and a glance does not read prose.
	_readings = HBoxContainer.new()
	_readings.alignment = BoxContainer.ALIGNMENT_CENTER
	_readings.add_theme_constant_override("separation", 40)
	add_child(_readings)
	# Never wrapped. These are padded readings with no spaces to break on, and a
	# wrapping label squeezed into a row degrades to one character per line —
	# which is precisely what it did.
	_elapsed_label = _reading("ELAPSED  00:00:00")
	_readings.add_child(_elapsed_label)
	_left_label = _reading("")
	_readings.add_child(_left_label)

	add_child(HSeparator.new())

	# The two halves are assembled before formatting rather than inside it: the
	# %s belongs to one fragment of a concatenation, and applying the format to
	# the wrong fragment prints the placeholder to the screen. It did.
	var explanation := (
		"Your machine is squaring a number over and over, and the answer is the "
		+ "key. It cannot be hurried, split across machines or paused. The keeper "
		+ "was quoted about %s, measured on their machine — this one may be "
		+ "faster or slower."
	) % expected
	_note_label = TempleTheme.line(
		explanation + "\n\n" + note, TempleTheme.GREY, TempleTheme.SIZE_SMALL
	)
	add_child(_note_label)

	_started_msec = Time.get_ticks_msec()
	_running = true
	set_process(true)
	_redraw()


## The host's latest reading.
func report(percent: float) -> void:
	if not _running:
		return
	# Never backwards: a reading that fell would read as lost work, and the
	# climb only ever goes up.
	if percent > _percent:
		_percent = percent
	_redraw()


## The climb is over, one way or the other. The clock stops where it stopped,
## because how long it took is the thing a reader will want to know next time.
func finish(headline: String, note: String, colour: Color) -> void:
	_running = false
	set_process(false)
	_percent_label.text = headline
	# A word is not a number: shrink it to something a word fits in.
	_percent_label.add_theme_font_size_override("font_size", TempleTheme.SIZE_TITLE)
	_percent_label.add_theme_color_override("font_color", colour)
	# The bar and the two readings answered "how far along", which is no longer
	# a question anybody has. What is left is the headline and what it means.
	_bar_label.hide()
	_readings.hide()
	_note_label.text = note
	_note_label.add_theme_color_override("font_color", colour)


## How long the climb has been running, in seconds.
func elapsed() -> int:
	@warning_ignore("integer_division")
	var seconds := (Time.get_ticks_msec() - _started_msec) / 1000
	return seconds


func _process(_delta: float) -> void:
	if not _running:
		return
	if elapsed() == _shown_second:
		return
	_redraw()


func _redraw() -> void:
	var seconds := elapsed()
	_shown_second = seconds
	_percent_label.text = "%d%%" % int(_percent)
	_bar_label.text = progress_bar(_percent)
	_elapsed_label.text = "ELAPSED  %s" % clock(seconds)

	# Measured from this machine rather than taken from the puzzle: the duration
	# the keeper was quoted was measured on the keeper's machine, which may be
	# much faster or much slower than this one.
	if _percent >= ESTIMATE_AFTER_PERCENT and seconds >= ESTIMATE_AFTER_SECONDS:
		var per_percent := float(seconds) / _percent
		_left_label.text = "REMAINING  %s" % remaining_phrase(
			int(per_percent * (100.0 - _percent))
		)
	else:
		_left_label.text = "REMAINING  not yet known"


## One reading, never wrapped and never clipped: it is short, and it is the
## thing being read.
static func _reading(text: String) -> Label:
	var label := TempleTheme.line(text, TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	return label


## The bar, drawn in characters. Public because it is worth checking: an
## off-by-one here draws a full bar on something that is still working.
static func progress_bar(percent: float) -> String:
	# Truncated rather than rounded: rounding fills the last cell at 99%, and a
	# full bar on something unfinished is the one lie a progress bar can tell.
	var filled := clampi(int(percent / 100.0 * BAR_CELLS), 0, BAR_CELLS)
	return "[%s%s]" % [BAR_FULL.repeat(filled), BAR_EMPTY.repeat(BAR_CELLS - filled)]


## How much is left, rounded. A reading of "04:29:56" claims a precision this
## does not have: it is extrapolated from a whole-percent reading, which on a
## day-long climb is a quarter of an hour wide. Saying "about 4h 30m" is the
## same guess without the false decimals.
static func remaining_phrase(seconds: int) -> String:
	var whole := maxi(seconds, 0)
	("integer_division")
	var days := whole / 86400
	("integer_division")
	var hours := (whole % 86400) / 3600
	("integer_division")
	var minutes := (whole % 3600) / 60
	if days > 0:
		return "about %dd %dh" % [days, hours]
	if hours > 0:
		return "about %dh %02dm" % [hours, minutes]
	if minutes > 0:
		return "about %dm" % minutes
	return "under a minute"


## A clock, not a rounded phrase. "3h ago" is right for a flame that was tended
## last spring and wrong for something a reader is watching: the seconds moving
## are the proof that it is still running.
static func clock(seconds: int) -> String:
	var whole := maxi(seconds, 0)
	@warning_ignore("integer_division")
	var days := whole / 86400
	@warning_ignore("integer_division")
	var hours := (whole % 86400) / 3600
	@warning_ignore("integer_division")
	var minutes := (whole % 3600) / 60
	var secs := whole % 60
	if days > 0:
		return "%dd %02d:%02d:%02d" % [days, hours, minutes, secs]
	return "%02d:%02d:%02d" % [hours, minutes, secs]
