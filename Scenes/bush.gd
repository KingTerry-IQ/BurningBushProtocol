## The bush, drawn in text and set on fire.
##
## Text-mode on purpose: this is a TempleOS-shaped app, and a bitmap flame would
## be less honest than characters flickering in a 16-colour palette.
##
## The fire is the status display. It burns while the flame is tended, thins and
## cools as the grace runs out, and goes to ash when the covenant comes due —
## so the state is readable across the room without parsing a word.

class_name BurningBush
extends RichTextLabel

## Characters that belong to the fire and therefore flicker.
const FLAME_GLYPHS := "()*.,'`\\/|"

## Rows 0..TRUNK_ROW-1 are fire; the rest is wood and ground.
const TRUNK_ROW := 7

const ART := [
	"        .  (   )  .   (  )  .",
	"      (  ) (  ( )  ) (  ) (  )",
	"     ( ( )  )  ( ) (  ) ( )  )",
	"      ) (  )  \\  |  /  (  ) (",
	"       ( ) (  \\\\ | //  ) ( )",
	"        ) (   \\\\\\|///   ) (",
	"          '  . \\\\|//  .  '",
	"           \\____\\|/____/",
	"                |||",
	"                |||",
	"         ~~~~~~~~~~~~~~~~~",
]

## TempleOS never had more than sixteen colours, so neither does the fire.
const HOT := [Color("FFFF55"), Color("FFFFFF"), Color("FF5555")]
const WARM := [Color("FF5555"), Color("AA5500"), Color("FFFF55")]
const COOL := [Color("AA5500"), Color("AA0000"), Color("555555")]
const ASH := [Color("555555"), Color("AAAAAA")]

const WOOD := Color("AA5500")
const GROUND := Color("555555")
const DEAD_WOOD := Color("555555")

## Redraws per second. The fire wants to look alive, not seizure-inducing.
const FLICKER_HZ := 9.0

var state: Flame.State = Flame.State.UNKNOWN:
	set(value):
		state = value
		_redraw()

var _rng := RandomNumberGenerator.new()
var _accumulated := 0.0


func _ready() -> void:
	bbcode_enabled = true
	scroll_active = false
	fit_content = true
	_rng.randomize()
	_redraw()


func _process(delta: float) -> void:
	# A dark bush is not burning, so there is nothing to animate.
	if state == Flame.State.DARK or state == Flame.State.NEVER_LIT:
		return
	_accumulated += delta
	if _accumulated >= 1.0 / FLICKER_HZ:
		_accumulated = 0.0
		_redraw()


func _redraw() -> void:
	var palette := _palette()
	# How much of the fire is lit at all. A guttering flame has gaps in it.
	var density := _density()

	var out := "[center]"
	for row in ART.size():
		var line: String = ART[row]
		if row < TRUNK_ROW:
			out += _burn(line, palette, density)
		else:
			out += _wood(line)
		out += "\n"
	out += "[/center]"
	text = out


func _burn(line: String, palette: Array, density: float) -> String:
	var out := ""
	for i in line.length():
		var glyph := line[i]
		if glyph == " ":
			out += " "
			continue
		if not FLAME_GLYPHS.contains(glyph):
			out += glyph
			continue
		# Thinning the fire reads as cooling far better than dimming it.
		if _rng.randf() > density:
			out += " "
			continue
		var colour: Color = palette[_rng.randi() % palette.size()]
		out += "[color=#%s]%s[/color]" % [colour.to_html(false), glyph]
	return out


func _wood(line: String) -> String:
	var colour := WOOD
	if state == Flame.State.DARK or state == Flame.State.NEVER_LIT:
		colour = DEAD_WOOD
	if line.contains("~"):
		colour = GROUND
	return "[color=#%s]%s[/color]" % [colour.to_html(false), line]


func _palette() -> Array:
	match state:
		Flame.State.BURNING:
			return HOT
		Flame.State.GUTTERING:
			return COOL
		Flame.State.DARK, Flame.State.NEVER_LIT:
			return ASH
		_:
			return WARM


func _density() -> float:
	match state:
		Flame.State.BURNING:
			return 0.92
		Flame.State.GUTTERING:
			return 0.45
		Flame.State.DARK:
			return 0.0
		Flame.State.NEVER_LIT:
			return 0.0
		_:
			return 0.25
