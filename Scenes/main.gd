## Burning Bush Protocol.
##
## A dead man's switch built on inscribed proof of life. The keeper tends a
## flame on-chain; its absence is a public fact that needs no host to adjudicate
## and no organisation to remember. When the flame goes dark, the witnesses can
## bring their fragments together and open what was sealed.
##
## Runs as an app launched by GodOnChain, which holds the keys and prompts the
## keeper before anything is spent. It ships no keys of its own.
##
## The UI is assembled in code: this is a text-mode app and the layout is a
## single column, so a scene file would only be somewhere for typos to hide.
## Panel handlers are named methods rather than inline lambdas, because GDScript
## cannot parse a multi-line lambda inside a call argument.

extends Control

const CONFIG_PATH := "user://covenant.cfg"

var iq: IQClient
var flame: Flame
var covenant: Covenant

var config := {
	"keeper": "",
	"db_root_id": "",
	"chain": "sol",
	"interval_days": 30,
	"grace_days": 60,
	"tablet_signature": "",
	"witnesses": 4,
	"threshold": 2,
}

var _status: Dictionary = {}
var _busy := false

# Main screen
var bush: BurningBush
var verse: Label
var gloss: Label
var readout: Label
var console: RichTextLabel
var oracle: Label
var buttons: Dictionary = {}

# Whichever prompt is open, and the widgets its handler needs.
var _panel: Control
var _seal_body: TextEdit
var _seal_witnesses: SpinBox
var _seal_threshold: SpinBox
var _seal_warning: Label
var _fragments_listing: TextEdit
var _open_signature: LineEdit
var _open_fragments: TextEdit
var _open_result: Label
var _settings_fields: Dictionary = {}


func _ready() -> void:
	theme = TempleTheme.build()
	_load_config()
	_build_ui()

	iq = IQClient.new()
	add_child(iq)

	covenant = Covenant.new(iq)
	flame = Flame.new(iq, str(config["db_root_id"]), str(config["chain"]))
	flame.interval_days = int(config["interval_days"])
	flame.grace_days = int(config["grace_days"])

	await _connect()


#region Connection

func _connect() -> void:
	_say("Seeking the mountain...", TempleTheme.DARK_GREY)

	if not await iq.discover():
		_say(iq.last_error, TempleTheme.BRIGHT_RED)
		_say(
			"This app holds no keys. Launch it from GodOnChain, or run "
			+ "GodOnChain alongside it.",
			TempleTheme.DARK_GREY
		)
		_set_state(Flame.State.UNKNOWN)
		return

	var who := iq.app_label if not iq.app_label.is_empty() else "an unnamed vessel"
	_say("Attached to the host as %s." % who, TempleTheme.CYAN)

	if str(config["db_root_id"]).strip_edges().is_empty():
		_say("No covenant root is set. Open SETTINGS and name one.", TempleTheme.YELLOW)
		_set_state(Flame.State.NEVER_LIT)
		return

	await _refresh()


func _refresh() -> void:
	if iq == null or not iq.is_available():
		return
	_set_busy(true)
	_say("Reading the flame...", TempleTheme.DARK_GREY)

	_status = await flame.read_status()
	var state: Flame.State = _status.get("state", Flame.State.UNKNOWN)
	_set_state(state)

	if state == Flame.State.UNKNOWN and not flame.last_error.is_empty():
		_say(flame.last_error, TempleTheme.BRIGHT_RED)
	elif state != Flame.State.NEVER_LIT:
		var last := int(_status.get("last_ts", 0))
		if last > 0:
			_say(
				"Last tended %s UTC."
				% Time.get_datetime_string_from_unix_time(last, true),
				TempleTheme.GREY
			)

	_set_busy(false)

#endregion


#region Actions

func _on_kindle() -> void:
	if not _require_root():
		return
	_set_busy(true)
	_say("Building the altar. The keeper will be asked to approve this.", TempleTheme.YELLOW)

	var result = await flame.kindle()
	if result == null:
		_say(flame.last_error, TempleTheme.BRIGHT_RED)
	else:
		_say("The altar stands. Tend the flame to light it.", TempleTheme.CYAN)
		await _refresh()
	_set_busy(false)


func _on_tend() -> void:
	if not _require_root():
		return
	_set_busy(true)
	_say("Tending the flame. The keeper will be asked to approve this.", TempleTheme.YELLOW)

	var result = await flame.tend()
	if result == null:
		_say(flame.last_error, TempleTheme.BRIGHT_RED)
	else:
		var sig := ""
		if result is Dictionary:
			sig = str((result as Dictionary).get("signature", ""))
		_say("The flame is tended. %s" % sig.substr(0, 24), TempleTheme.CYAN)
		await _refresh()
	_set_busy(false)


func _require_root() -> bool:
	if str(config["db_root_id"]).strip_edges().is_empty():
		_say("Name a covenant root in SETTINGS first.", TempleTheme.BRIGHT_RED)
		return false
	if iq == null or not iq.is_available():
		_say("Not attached to a host.", TempleTheme.BRIGHT_RED)
		return false
	return true

#endregion


#region Sealing

func _show_seal_panel() -> void:
	if not _require_root():
		return
	var box := _open_panel_box()

	box.add_child(TempleTheme.title("— SEAL A COVENANT —", TempleTheme.BRIGHT_RED))
	box.add_child(
		TempleTheme.line(
			"What is written here is encrypted now and inscribed forever. "
			+ "Only the key is withheld.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	_seal_body = TextEdit.new()
	_seal_body.custom_minimum_size = Vector2(0, 180)
	_seal_body.placeholder_text = "The word to be kept until the flame goes dark..."
	_seal_body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(_seal_body)

	var counts := HBoxContainer.new()
	counts.add_theme_constant_override("separation", 14)
	counts.alignment = BoxContainer.ALIGNMENT_CENTER

	_seal_witnesses = SpinBox.new()
	_seal_witnesses.min_value = 2
	_seal_witnesses.max_value = 16
	_seal_witnesses.value = int(config["witnesses"])
	_seal_witnesses.value_changed.connect(_on_counts_changed)
	counts.add_child(TempleTheme.line("Witnesses:", TempleTheme.GREY))
	counts.add_child(_seal_witnesses)

	_seal_threshold = SpinBox.new()
	_seal_threshold.min_value = 2
	_seal_threshold.max_value = 16
	_seal_threshold.value = int(config["threshold"])
	_seal_threshold.value_changed.connect(_on_counts_changed)
	counts.add_child(TempleTheme.line("Needed to open:", TempleTheme.GREY))
	counts.add_child(_seal_threshold)
	box.add_child(counts)

	_seal_warning = TempleTheme.line("", TempleTheme.BROWN, TempleTheme.SIZE_SMALL)
	box.add_child(_seal_warning)
	_on_counts_changed(0.0)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("SEAL IT", _seal_confirmed))
	row.add_child(TempleTheme.button("TURN ASIDE", _close_panel))


func _on_counts_changed(_value: float) -> void:
	if _seal_warning == null:
		return
	_seal_warning.text = Scripture.sealing_warning(
		int(_seal_witnesses.value), int(_seal_threshold.value)
	)


func _seal_confirmed() -> void:
	var text := _seal_body.text
	var witnesses := int(_seal_witnesses.value)
	var threshold := int(_seal_threshold.value)

	if threshold > witnesses:
		_say("Cannot need more fragments than there are witnesses.", TempleTheme.BRIGHT_RED)
		return
	if text.strip_edges().is_empty():
		_say("There is nothing to seal.", TempleTheme.BRIGHT_RED)
		return

	_close_panel()
	_set_busy(true)

	var terms := {
		"root": str(config["db_root_id"]),
		"keeper": str(config["keeper"]),
		"threshold": threshold,
		"witnesses": witnesses,
		"interval_days": int(config["interval_days"]),
		"grace_days": int(config["grace_days"]),
	}

	var sealed := covenant.seal(text, terms)
	if sealed.is_empty():
		_say(covenant.last_error, TempleTheme.BRIGHT_RED)
		_set_busy(false)
		return

	var key: PackedByteArray = sealed["key"]
	var fragments := covenant.shatter(key, witnesses, threshold)
	if fragments.is_empty():
		_say(covenant.last_error, TempleTheme.BRIGHT_RED)
		_set_busy(false)
		return

	_say("Inscribing the tablet. The keeper will be asked to approve this.", TempleTheme.YELLOW)
	var signature = await covenant.inscribe(sealed["tablet"], str(config["chain"]))
	if signature == null:
		_say(covenant.last_error, TempleTheme.BRIGHT_RED)
		_set_busy(false)
		return

	config["tablet_signature"] = str(signature)
	config["witnesses"] = witnesses
	config["threshold"] = threshold
	_save_config()

	_say("The tablet is inscribed: %s" % str(signature), TempleTheme.CYAN)
	_set_busy(false)
	_show_fragments(fragments, threshold, str(signature))


## The fragments exist in memory and nowhere else. This is the only time they
## are shown, and nothing writes them down — putting every fragment in one file
## would undo the whole point of splitting them.
func _show_fragments(
	fragments: Array[PackedByteArray], threshold: int, signature: String
) -> void:
	var box := _open_panel_box()

	box.add_child(TempleTheme.title("— THE FRAGMENTS —", TempleTheme.YELLOW))
	box.add_child(
		TempleTheme.line(
			"Give exactly one to each witness, by some means that is not this "
			+ "machine. They are shown once and never stored. Close this and "
			+ "they are gone.",
			TempleTheme.BRIGHT_RED,
			TempleTheme.SIZE_SMALL
		)
	)
	box.add_child(
		TempleTheme.line(
			"Any %d of them open the tablet. Fewer reveal nothing." % threshold,
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	_fragments_listing = TextEdit.new()
	_fragments_listing.custom_minimum_size = Vector2(0, 230)
	_fragments_listing.editable = false

	var lines: PackedStringArray = []
	lines.append("TABLET: " + signature)
	lines.append("")
	for i in fragments.size():
		lines.append("WITNESS %d:" % (i + 1))
		lines.append(Shamir.to_hex(fragments[i]))
		lines.append("")
	_fragments_listing.text = "\n".join(lines)
	box.add_child(_fragments_listing)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("COPY ALL", _fragments_copy))
	row.add_child(TempleTheme.button("I HAVE GIVEN THEM OUT", _fragments_done))


func _fragments_copy() -> void:
	DisplayServer.clipboard_set(_fragments_listing.text)
	_say("Fragments copied. Distribute them now.", TempleTheme.YELLOW)


func _fragments_done() -> void:
	_close_panel()
	_say("The fragments are forgotten by this machine.", TempleTheme.DARK_GREY)

#endregion


#region Opening

func _show_open_panel() -> void:
	var box := _open_panel_box()

	box.add_child(TempleTheme.title("— OPEN A TABLET —", TempleTheme.CYAN))
	box.add_child(
		TempleTheme.line(
			"Anyone may read a sealed tablet. Only the fragments open it.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	_open_signature = LineEdit.new()
	_open_signature.placeholder_text = "tablet signature"
	_open_signature.text = str(config["tablet_signature"])
	box.add_child(_open_signature)

	_open_fragments = TextEdit.new()
	_open_fragments.custom_minimum_size = Vector2(0, 180)
	_open_fragments.placeholder_text = "One fragment per line, as given to each witness..."
	box.add_child(_open_fragments)

	_open_result = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	box.add_child(_open_result)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("OPEN", _open_confirmed))
	row.add_child(TempleTheme.button("TURN ASIDE", _close_panel))


func _open_confirmed() -> void:
	_result("Fetching the tablet...", TempleTheme.GREY)

	var tablet := await covenant.fetch(
		_open_signature.text.strip_edges(), str(config["chain"])
	)
	if tablet.is_empty():
		_result(covenant.last_error, TempleTheme.BRIGHT_RED)
		return

	var fragments: Array[PackedByteArray] = []
	for raw: String in _open_fragments.text.split("\n", false):
		if raw.strip_edges().is_empty():
			continue
		var fragment := covenant.read_fragment(raw)
		if fragment.is_empty():
			_result(covenant.last_error, TempleTheme.BRIGHT_RED)
			return
		fragments.append(fragment)

	var needed := int(tablet.get("threshold", 2))
	if fragments.size() < needed:
		_result(
			"This tablet needs %d fragments. You have %d." % [needed, fragments.size()],
			TempleTheme.YELLOW
		)
		return

	var key := covenant.gather(fragments)
	if key.is_empty():
		_result(covenant.last_error, TempleTheme.BRIGHT_RED)
		return

	var text := covenant.unseal(tablet, key)
	if text.is_empty():
		_result(covenant.last_error, TempleTheme.BRIGHT_RED)
		return

	_result("The tablet is open.", TempleTheme.CYAN)
	_say("=== THE WORD ===", TempleTheme.YELLOW)
	_say(text, TempleTheme.WHITE)


func _result(message: String, colour: Color) -> void:
	if _open_result == null:
		return
	_open_result.add_theme_color_override("font_color", colour)
	_open_result.text = message

#endregion


#region Settings

func _show_settings() -> void:
	var box := _open_panel_box()
	_settings_fields = {}

	box.add_child(TempleTheme.title("— THE TERMS —", TempleTheme.YELLOW))

	_add_setting(box, "keeper", "Keeper", "the name the witnesses will see")
	_add_setting(box, "db_root_id", "Covenant root", "the dbRootId this flame lives under")
	_add_setting(box, "chain", "Chain", "sol or mon")
	_add_setting(box, "interval_days", "Tend every (days)", "30")
	_add_setting(box, "grace_days", "Grace after that (days)", "60")

	box.add_child(
		TempleTheme.line(
			"The flame is declared dark after the interval plus the grace. "
			+ "Being unreachable is not being dead — leave room.",
			TempleTheme.BROWN,
			TempleTheme.SIZE_SMALL
		)
	)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("KEEP", _settings_keep))
	row.add_child(TempleTheme.button("TURN ASIDE", _close_panel))


func _add_setting(box: VBoxContainer, key: String, label: String, hint: String) -> void:
	box.add_child(TempleTheme.line(label, TempleTheme.GREY, TempleTheme.SIZE_SMALL))
	var edit := LineEdit.new()
	edit.text = str(config[key])
	edit.placeholder_text = hint
	box.add_child(edit)
	_settings_fields[key] = edit


func _settings_keep() -> void:
	for key: String in _settings_fields:
		var value: String = (_settings_fields[key] as LineEdit).text.strip_edges()
		if key.ends_with("_days"):
			config[key] = maxi(1, int(value))
		else:
			config[key] = value
	_save_config()

	flame.db_root_id = str(config["db_root_id"])
	flame.chain = str(config["chain"])
	flame.interval_days = int(config["interval_days"])
	flame.grace_days = int(config["grace_days"])

	_close_panel()
	_say("The terms are kept.", TempleTheme.CYAN)
	await _refresh()

#endregion


#region UI construction

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = TempleTheme.BLACK
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.anchor_right = 1.0
	background.anchor_bottom = 1.0
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	column.add_child(TempleTheme.title("BURNING  BUSH  PROTOCOL", TempleTheme.YELLOW))
	column.add_child(
		TempleTheme.line(
			"a dead man's switch that asks no one's permission",
			TempleTheme.DARK_GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	bush = BurningBush.new()
	column.add_child(bush)

	verse = TempleTheme.line("", TempleTheme.YELLOW)
	column.add_child(verse)

	gloss = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	column.add_child(gloss)

	readout = TempleTheme.line("", TempleTheme.DARK_GREY, TempleTheme.SIZE_SMALL)
	column.add_child(readout)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	buttons["tend"] = TempleTheme.button("TEND THE FLAME", _on_tend)
	buttons["kindle"] = TempleTheme.button("BUILD THE ALTAR", _on_kindle)
	buttons["seal"] = TempleTheme.button("SEAL A COVENANT", _show_seal_panel)
	buttons["open"] = TempleTheme.button("OPEN A TABLET", _show_open_panel)
	buttons["refresh"] = TempleTheme.button("LOOK AGAIN", _refresh)
	buttons["settings"] = TempleTheme.button("SETTINGS", _show_settings)
	for key: String in buttons:
		row.add_child(buttons[key])
	column.add_child(row)

	var console_panel := PanelContainer.new()
	console_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	console = RichTextLabel.new()
	console.bbcode_enabled = true
	console.scroll_following = true
	console.add_theme_font_size_override("normal_font_size", TempleTheme.SIZE_SMALL)
	console_panel.add_child(console)
	column.add_child(console_panel)

	oracle = TempleTheme.line(Scripture.oracle(), TempleTheme.BROWN, TempleTheme.SIZE_SMALL)
	column.add_child(oracle)

	var ticker := Timer.new()
	ticker.wait_time = 11.0
	ticker.timeout.connect(_turn_the_oracle)
	add_child(ticker)
	ticker.start()


func _turn_the_oracle() -> void:
	oracle.text = Scripture.oracle()


## Opens a full-screen prompt, replacing any already showing, and returns the
## VBox to fill.
func _open_panel_box() -> VBoxContainer:
	_close_panel()

	_panel = Panel.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 26)
	_panel.add_child(margin)

	var centre := CenterContainer.new()
	margin.add_child(centre)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(760, 0)
	box.add_theme_constant_override("separation", 12)
	centre.add_child(box)

	add_child(_panel)
	return box


func _close_panel() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null


func _button_row(box: VBoxContainer) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	return row

#endregion


#region State and output

func _set_state(state: Flame.State) -> void:
	bush.state = state
	verse.text = Scripture.state_verse(state)
	gloss.text = Scripture.state_gloss(state, int(_status.get("days_left", 0)))

	var colour := TempleTheme.YELLOW
	match state:
		Flame.State.GUTTERING:
			colour = TempleTheme.BROWN
		Flame.State.DARK:
			colour = TempleTheme.BRIGHT_RED
		Flame.State.UNKNOWN, Flame.State.NEVER_LIT:
			colour = TempleTheme.DARK_GREY
	verse.add_theme_color_override("font_color", colour)

	var days_since := int(_status.get("days_since", -1))
	if days_since >= 0:
		readout.text = "FLAME: %s   |   SILENT %d DAYS   |   DARK AT %d" % [
			Flame.state_name(state), days_since, flame.days_until_dark()
		]
	else:
		readout.text = "FLAME: %s" % Flame.state_name(state)


func _set_busy(busy: bool) -> void:
	_busy = busy
	for key: String in buttons:
		(buttons[key] as Button).disabled = busy


func _say(message: String, colour: Color = TempleTheme.GREY) -> void:
	if console == null:
		print(message)
		return
	console.append_text("[color=#%s]%s[/color]\n" % [colour.to_html(false), message])
	print(message)

#endregion


#region Config

func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		for key: String in config:
			if (parsed as Dictionary).has(key):
				config[key] = (parsed as Dictionary)[key]


func _save_config() -> void:
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_error("Could not keep the terms: %d" % FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(config, "\t"))
	file.close()

#endregion
