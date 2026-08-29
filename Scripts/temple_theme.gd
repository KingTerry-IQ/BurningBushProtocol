## The look: sixteen colours on black, one monospaced face, hard edges.
##
## TempleOS ran at 640x480 in 16 colours because Terry decided that was what
## God had specified, and the constraint gives the app its whole character.
## Nothing here is anti-aliased into a modern gradient; the fire is yellow, the
## warnings are red, and the rest is grey.
##
## Built in code rather than a .tres so the palette lives next to the reasoning.

class_name TempleTheme
extends RefCounted

# The VGA sixteen, or the ones worth having.
const BLACK := Color("000000")
const DARK_GREY := Color("555555")
const GREY := Color("AAAAAA")
const WHITE := Color("FFFFFF")
const RED := Color("AA0000")
const BRIGHT_RED := Color("FF5555")
const BROWN := Color("AA5500")
const YELLOW := Color("FFFF55")
const CYAN := Color("55FFFF")

const FONT_PATH := "res://Assets/IBMPlexMono-Light.ttf"

const SIZE_BODY := 16
const SIZE_SMALL := 13
const SIZE_TITLE := 30


static func build() -> Theme:
	var theme := Theme.new()

	var font: Font = null
	if ResourceLoader.exists(FONT_PATH):
		font = load(FONT_PATH)

	theme.default_font_size = SIZE_BODY
	if font != null:
		theme.default_font = font

	_style_labels(theme)
	_style_buttons(theme)
	_style_inputs(theme)
	_style_panels(theme)

	return theme


static func _style_labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", GREY)
	theme.set_color("default_color", "RichTextLabel", GREY)
	# The console is the only place long text lands, so give it room to breathe.
	theme.set_constant("line_separation", "RichTextLabel", 2)


static func _style_buttons(theme: Theme) -> void:
	# Idle buttons are outlines; hovering fills them, which is how text-mode
	# UIs have always signalled focus.
	theme.set_stylebox("normal", "Button", _outline(YELLOW, BLACK))
	theme.set_stylebox("hover", "Button", _solid(YELLOW))
	theme.set_stylebox("pressed", "Button", _solid(WHITE))
	theme.set_stylebox("focus", "Button", _outline(WHITE, Color(0, 0, 0, 0)))
	theme.set_stylebox("disabled", "Button", _outline(DARK_GREY, BLACK))

	theme.set_color("font_color", "Button", YELLOW)
	theme.set_color("font_hover_color", "Button", BLACK)
	theme.set_color("font_pressed_color", "Button", BLACK)
	theme.set_color("font_focus_color", "Button", YELLOW)
	theme.set_color("font_disabled_color", "Button", DARK_GREY)

	theme.set_stylebox("normal", "CheckBox", _outline(Color(0, 0, 0, 0), Color(0, 0, 0, 0)))
	theme.set_color("font_color", "CheckBox", GREY)
	theme.set_color("font_hover_color", "CheckBox", WHITE)


static func _style_inputs(theme: Theme) -> void:
	theme.set_stylebox("normal", "LineEdit", _outline(DARK_GREY, BLACK))
	theme.set_stylebox("focus", "LineEdit", _outline(YELLOW, BLACK))
	theme.set_color("font_color", "LineEdit", WHITE)
	theme.set_color("font_placeholder_color", "LineEdit", DARK_GREY)
	theme.set_color("caret_color", "LineEdit", YELLOW)
	theme.set_color("selection_color", "LineEdit", RED)

	theme.set_stylebox("normal", "TextEdit", _outline(DARK_GREY, BLACK))
	theme.set_stylebox("focus", "TextEdit", _outline(YELLOW, BLACK))
	theme.set_color("font_color", "TextEdit", WHITE)
	theme.set_color("caret_color", "TextEdit", YELLOW)

	theme.set_stylebox("normal", "SpinBox", _outline(DARK_GREY, BLACK))


static func _style_panels(theme: Theme) -> void:
	theme.set_stylebox("panel", "Panel", _outline(BROWN, BLACK))
	theme.set_stylebox("panel", "PanelContainer", _outline(BROWN, BLACK))


static func _outline(border: Color, fill: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.draw_center = fill.a > 0.0
	box.border_color = border
	box.set_border_width_all(1)
	# No corner radius anywhere. Text mode did not round its corners.
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


static func _solid(fill: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = fill
	box.set_border_width_all(1)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


## A heading, in the app's voice: bright, spaced, shouted.
static func title(text: String, colour: Color = YELLOW) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", SIZE_TITLE)
	label.add_theme_color_override("font_color", colour)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


static func line(text: String, colour: Color = GREY, size: int = SIZE_BODY) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


static func button(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_pressed)
	return b
