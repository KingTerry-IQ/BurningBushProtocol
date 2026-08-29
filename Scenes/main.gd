## Burning Bush Protocol.
##
## A dead man's switch built on inscribed proof of life. The keeper tends a
## flame on-chain; its absence is a public fact that needs no host to adjudicate
## and no organisation to remember. When a flame goes dark, the witnesses bring
## their fragments together and open what was sealed.
##
## A keeper may hold many at once, so the app is a list before it is anything
## else — and the row that matters is the one that has gone out. Dark tablets
## are listed first, above everything still being kept.
##
## Runs as an app launched by GodOnChain, which holds the keys and prompts the
## keeper before anything is spent. It ships no keys of its own.
##
## The UI is assembled in code: this is a text-mode app and the layout is a
## single column. Panel handlers are named methods rather than inline lambdas,
## because GDScript cannot parse a multi-line lambda inside a call argument.

extends Control

const CONFIG_PATH := "user://covenant.cfg"

## Column widths for the list. Monospaced, so padding is alignment.
const W_STATE := 10
const W_TITLE := 26
const W_SILENCE := 12

var iq: IQClient
var ark: Ark
var covenant: Covenant

## Defaults for new tablets. Per-tablet terms live on the Tablet itself.
var config := {
	"keeper": "",
	"db_root_id": "",
	"chain": "sol",
	"interval_days": 30,
	"grace_days": 60,
	"ambience": true,
}

var selected_id: String = ""

# Main screen
var bush: BurningBush
var fire: FireSound
var sound_toggle: CheckBox
var verse: Label
var gloss: Label
var readout: Label
var list_box: VBoxContainer
var console: RichTextLabel
var oracle: Label
var guidance: Label
var action_row: HBoxContainer
var _action_buttons: Array[Button] = []
var _busy := false

# Whichever prompt is open, and the widgets its handler needs.
var _panel: Control
var _seal_title: LineEdit
var _seal_body: TextEdit
var _seal_threshold: SpinBox
var _witness_box: VBoxContainer
var _witness_panel: VBoxContainer
var _timelock_panel: HBoxContainer
var _witness_count_label: Label
var _seal_chain: OptionButton
var _seal_interval: SpinBox
var _seal_grace: SpinBox
var _seal_include_self: CheckBox
var _seal_terms_line: Label
var _browse_chain: OptionButton
var _mode_note: Label
var _progress_label := ""
var _progress_shown := -1
## One entry per witness: {name: LineEdit, identity: LineEdit}.
var _witness_rows: Array = []
## This wallet's public encryption identity, fetched once on connect.
var _my_identity: String = ""
var _seal_use_witnesses: CheckBox
var _seal_use_burn: CheckBox
var _seal_warning: Label
var _seal_file_label: Label
var _seal_file_path: String = ""
var _file_dialog: FileDialog
var _fragments_listing: TextEdit
var _adopt_signature: LineEdit
var _survey_root: LineEdit
var _survey_box: VBoxContainer
var _survey_status: Label
var _seal_list_publicly: CheckBox
var _seal_use_timelock: CheckBox
var _seal_timelock_days: SpinBox
var _open_fragments: TextEdit
var _open_result: Label
var _solving_timelock := false
## Polls for a host while unattached, so starting GodOnChain later just works.
var _host_watch: Timer
var _settings_fields: Dictionary = {}


func _ready() -> void:
	theme = TempleTheme.build()
	_load_config()
	_build_ui()

	iq = IQClient.new()
	add_child(iq)

	covenant = Covenant.new(iq)
	ark = Ark.new(iq)

	_rebuild_list()
	await _connect()


#region Connection

## Attaches to the host. `quiet` suppresses the chatter for the background
## retry, which would otherwise fill the console with the same two lines.
func _connect(quiet: bool = false) -> void:
	if not quiet:
		_say("Seeking the mountain...", TempleTheme.GREY)

	if not await iq.discover():
		if not quiet:
			_say(iq.last_error, TempleTheme.BRIGHT_RED)
			_say(
				"This app holds no keys. Launch it from GodOnChain, or run "
				+ "GodOnChain alongside it.",
				TempleTheme.GREY
			)
		_paint_state(Flame.State.UNKNOWN)
		_rebuild_actions()
		_start_watching_for_host()
		return

	_stop_watching_for_host()
	_rebuild_actions()

	var who := iq.app_label if not iq.app_label.is_empty() else "an unnamed vessel"
	_say("Attached to the host as %s." % who, TempleTheme.CYAN)

	_my_identity = await iq.crypto_identity()
	if _my_identity.is_empty():
		_say(
			"This wallet has no encryption identity, so fragments cannot be "
			+ "wrapped to it. A Solana signing key is needed for that.",
			TempleTheme.AMBER
		)

	await _refresh()


func _refresh() -> void:
	if iq == null:
		return

	# The guidance tells the user to press this once GodOnChain is running, so
	# it has to be able to attach — not merely re-read a connection that was
	# never made. Without this, a BBP opened before the host could never catch
	# up, and the button the app pointed at did nothing.
	if not iq.is_available():
		await _connect()
		return
	if ark.tablets.is_empty():
		_say(
			"Nothing is being watched yet. Seal a covenant of your own, or look up "
			+ "someone who named you as a witness.",
			TempleTheme.GREY
		)
		# Repaint through the list, which also recomputes the guidance line.
		# Painting only the bush left the instructions stale on a connected app.
		_rebuild_list()
		return

	_set_busy(true)
	_say("Reading %d flame(s)..." % ark.tablets.size(), TempleTheme.GREY)

	var dark := await ark.refresh()
	_rebuild_list()

	if not dark.is_empty():
		for tablet: Tablet in dark:
			_say(
				"THE FLAME OF '%s' IS DARK. Silent %d days." % [
					tablet.title, ark.days_since(tablet)
				],
				TempleTheme.BRIGHT_RED
			)
	else:
		_say("All flames answered.", TempleTheme.CYAN)

	_set_busy(false)

#endregion


## While unattached, keep looking. The host may be started at any moment, and
## the app should notice by itself rather than waiting to be told.
##
## Three seconds because of a race that is easy to hit: GodOnChain only starts
## its service *after* the password is entered, and then spends a while
## unpacking and spawning it. Anyone who opens this app during that window sees
## nothing, and should not have to know why.
func _start_watching_for_host() -> void:
	if _host_watch != null:
		return
	_host_watch = Timer.new()
	_host_watch.wait_time = 3.0
	_host_watch.timeout.connect(_retry_connect)
	add_child(_host_watch)
	_host_watch.start()


func _stop_watching_for_host() -> void:
	if _host_watch != null:
		_host_watch.stop()
		_host_watch.queue_free()
		_host_watch = null


func _retry_connect() -> void:
	if iq == null or iq.is_available():
		_stop_watching_for_host()
		return
	await _connect(true)
	if iq.is_available():
		_say("GodOnChain is up. Attached.", TempleTheme.CYAN)

#endregion


#region The Ark list

func _rebuild_list() -> void:
	if list_box == null:
		return
	for child in list_box.get_children():
		child.queue_free()

	if ark == null or ark.tablets.is_empty():
		list_box.add_child(
			TempleTheme.line(
				"Nothing is kept here yet.", TempleTheme.GREY, TempleTheme.SIZE_SMALL
			)
		)
		_paint_selected()
		_rebuild_actions()
		return

	var dark := ark.dark_tablets()
	var living := ark.living_tablets()

	# Dark first, always. It is the only row anyone opened the app to see.
	if not dark.is_empty():
		list_box.add_child(_heading("— THE FLAME HAS GONE OUT —", TempleTheme.BRIGHT_RED))
		for tablet: Tablet in dark:
			list_box.add_child(_row(tablet))

	if not living.is_empty():
		list_box.add_child(_heading("— KEPT —", TempleTheme.AMBER))
		for tablet: Tablet in living:
			list_box.add_child(_row(tablet))

	_paint_selected()
	_rebuild_actions()


func _heading(text: String, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	label.add_theme_color_override("font_color", colour)
	return label


func _row(tablet: Tablet) -> Button:
	var state := ark.state_of(tablet)
	var button := Button.new()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text = _row_text(tablet, state)
	button.add_theme_color_override("font_color", _state_colour(state))
	button.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	button.pressed.connect(_select.bind(tablet.id))
	button.set_meta("tablet_id", tablet.id)
	return button


func _row_text(tablet: Tablet, state: Flame.State) -> String:
	var days := ark.days_since(tablet)
	var silence := "silent %dd" % days if days >= 0 else "—"
	var mine := ""
	if not _my_identity.is_empty():
		var testimony := Testimony.new(iq, tablet)
		if not testimony.my_envelope(_my_identity).is_empty():
			mine = "*"
	return "%s%s %s %s %s %s  %s" % [
		">" if tablet.id == selected_id else " ",
		mine,
		Flame.state_name(state).rpad(W_STATE),
		tablet.title.substr(0, W_TITLE).rpad(W_TITLE),
		silence.rpad(W_SILENCE),
		tablet.chain.to_upper().rpad(4),
		tablet.release_phrase(),
	]


func _state_colour(state: Flame.State) -> Color:
	match state:
		Flame.State.BURNING:
			return TempleTheme.YELLOW
		Flame.State.GUTTERING:
			return TempleTheme.AMBER
		Flame.State.DARK:
			return TempleTheme.BRIGHT_RED
		Flame.State.NEVER_LIT:
			return TempleTheme.GREY
		_:
			return TempleTheme.GREY


func _select(id: String) -> void:
	selected_id = "" if selected_id == id else id
	_rebuild_list()


func selected() -> Tablet:
	return ark.find(selected_id) if not selected_id.is_empty() else null


## The bush shows the selected tablet, or when nothing is picked, the worst
## state in the ark — so a dark flame is visible without hunting for it.
func _paint_selected() -> void:
	var tablet := selected()
	if tablet != null:
		_paint_state(ark.state_of(tablet), tablet)
		return

	var worst := Flame.State.NEVER_LIT
	for candidate: Tablet in ark.tablets:
		var state := ark.state_of(candidate)
		if state == Flame.State.DARK:
			worst = state
			break
		if state == Flame.State.GUTTERING or worst == Flame.State.NEVER_LIT:
			worst = state
	_paint_state(worst)


func _paint_state(state: Flame.State, tablet: Tablet = null) -> void:
	bush.state = state
	if fire != null:
		fire.set_state(state)
	if sound_toggle != null:
		sound_toggle.visible = FireSound.audible_at(state)
	verse.text = Scripture.state_verse(state)

	var days_left := 0
	if tablet != null:
		var status: Dictionary = ark.states.get(tablet.id, {})
		days_left = int(status.get("days_left", 0))
	gloss.text = Scripture.state_gloss(state, days_left)
	verse.add_theme_color_override("font_color", _state_colour(state))

	if tablet != null:
		readout.text = "%s   |   %s   |   opens to %s" % [
			tablet.title, tablet.chain.to_upper(), tablet.release_phrase()
		]
	else:
		var dark_count := ark.dark_tablets().size() if ark != null else 0
		var total := ark.tablets.size() if ark != null else 0
		readout.text = "%d kept   |   %d dark" % [total, dark_count]

#endregion


#region Actions on the selected tablet

func _on_tend() -> void:
	var tablet := selected()
	if tablet == null:
		_say("Choose a covenant to tend.", TempleTheme.YELLOW)
		return

	_set_busy(true)
	var flame := ark.flame_for(tablet)

	# Writing a row to a table that does not exist reverts, which on Monad
	# costs real money and achieves nothing. Look first.
	if not await flame.exists_on_chain():
		_say(
			"'%s' has no flame table on %s yet, so there is nothing to write to. "
			% [tablet.title, tablet.chain.to_upper()]
			+ "Press PREPARE first.",
			TempleTheme.BRIGHT_RED
		)
		_set_busy(false)
		return

	var result = await flame.tend("", _writing("Checking in"))
	if result == null:
		_say(flame.last_error, TempleTheme.BRIGHT_RED)
	else:
		ark.states[tablet.id] = await flame.read_status(5)
		var state: Flame.State = ark.states[tablet.id].get("state", Flame.State.UNKNOWN)
		if state == Flame.State.NEVER_LIT:
			_say(
				"The write completed but no check-in can be read back. It may "
				+ "need a moment to settle — press REFRESH shortly.",
				TempleTheme.AMBER
			)
		else:
			_say("The flame of '%s' is tended." % tablet.title, TempleTheme.CYAN)
		_rebuild_list()
	_set_busy(false)


func _on_kindle() -> void:
	var tablet := selected()
	if tablet == null:
		_say("Choose a covenant whose altar you want built.", TempleTheme.YELLOW)
		return

	# Prepare is several writes, and on Monad that is real money. Say so before
	# starting rather than after the third approval prompt.
	# Priced per call: table creations are the expensive part, the listing rows
	# are small and cheap.
	var tables := 2
	if tablet.has(Tablet.Release.WITNESSES):
		tables += 1
	if tablet.public_listing:
		tables += 1
	var rows := 2 if tablet.public_listing else 1
	var estimate := (
		Costs.create_table(tablet.chain) * tables + Costs.write_row(tablet.chain) * rows
	)

	_set_busy(true)
	_say(
		"Preparing '%s': %d table(s) and %d listing row(s), about %s in total."
		% [tablet.title, tables, rows, Costs.format(tablet.chain, estimate)],
		TempleTheme.AMBER
	)

	var flame := ark.flame_for(tablet)
	if await flame.kindle(_writing("Creating the flame table")) == null:
		# Keep going: the remaining steps are independent, and abandoning them
		# here is what left covenants sealed but unlisted.
		_say("Could not build the altar: %s" % flame.last_error, TempleTheme.BRIGHT_RED)
	elif not await flame.exists_on_chain():
		# The job finished but the chain does not have it. A reverted
		# transaction looks exactly like a successful one from the job's side.
		_say(
			"The write completed but no table appeared on %s. The transaction "
			% tablet.chain.to_upper()
			+ "was probably reverted — funds were spent and nothing was created. "
			+ "Check the signer's balance before trying again.",
			TempleTheme.BRIGHT_RED
		)
	else:
		_say("The altar stands, and the chain confirms it.", TempleTheme.CYAN)

	# Witnesses need somewhere to testify, and it must exist long before it is
	# needed — by then the keeper is not around to build it.
	if tablet.has(Tablet.Release.WITNESSES):
		_say("Preparing the place of testimony.", TempleTheme.YELLOW)
		var testimony := Testimony.new(iq, tablet)
		if await testimony.prepare() == null:
			_say(testimony.last_error, TempleTheme.BRIGHT_RED)
		else:
			_say("It stands ready.", TempleTheme.CYAN)

	# Retry anything that did not get listed when it was sealed.
	await _publish_listings(tablet)

	_say("Now check in to light the flame.", TempleTheme.YELLOW)
	await _refresh()
	_set_busy(false)


## Makes a covenant findable: under its keeper's own root always, and in the
## shared commons when that was asked for.
##
## Separate from building the flame, and safe to run twice — a covenant listed
## twice is still one covenant, and being unlisted is the failure that actually
## matters to a witness.
func _publish_listings(tablet: Tablet) -> void:
	if tablet.signature.is_empty():
		return

	var registry := Registry.new(iq, tablet.db_root_id, tablet.chain)
	await registry.prepare()
	if await registry.publish(tablet) == null:
		_say(
			"Not listed under '%s': %s. Witnesses would need the signature by hand — "
			% [tablet.db_root_id, registry.last_error]
			+ "press PREPARE to try again.",
			TempleTheme.AMBER
		)
	else:
		_say("Listed under '%s', where your witnesses can find it." % tablet.db_root_id,
			TempleTheme.CYAN)

	if not tablet.public_listing:
		return

	var commons := Registry.commons(iq, tablet.chain)
	await commons.prepare()
	if await commons.publish(tablet) == null:
		_say(
			"Not listed publicly: %s. Press PREPARE to try again."
			% commons.last_error,
			TempleTheme.AMBER
		)
	else:
		_say("Listed in the commons, where anyone can find it.", TempleTheme.CYAN)


func _on_forget() -> void:
	var tablet := selected()
	if tablet == null:
		_say("Choose a covenant to forget.", TempleTheme.YELLOW)
		return
	# Local only. The tablet is inscribed and the flame keeps its own time.
	ark.remove(tablet.id)
	selected_id = ""
	_rebuild_list()
	_say(
		"'%s' is out of the ark. It is still on-chain, and its flame still burns."
		% tablet.title,
		TempleTheme.GREY
	)

#endregion


#region Being a witness

## Shows this wallet's identity key, to hand to a keeper who wants to name you
## as a witness. It is a public key: there is nothing to protect about it.
func _show_identity() -> void:
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— YOUR IDENTITY —", TempleTheme.CYAN))

	if _my_identity.is_empty():
		box.add_child(
			TempleTheme.line(
				"No identity. This needs a Solana signing key in GodOnChain.",
				TempleTheme.BRIGHT_RED,
				TempleTheme.SIZE_SMALL
			)
		)
	else:
		box.add_child(
			TempleTheme.line(
				"Give this to anyone naming you a witness. It is derived from "
				+ "your wallet, so it is the same on every machine you sign "
				+ "with, and there is nothing to store or lose.",
				TempleTheme.GREY,
				TempleTheme.SIZE_SMALL
			)
		)
		var field := LineEdit.new()
		field.text = _my_identity
		field.editable = false
		box.add_child(field)

	var row := _button_row(box)
	if not _my_identity.is_empty():
		row.add_child(TempleTheme.button("COPY", _copy_identity))
	row.add_child(TempleTheme.button("CANCEL", _close_panel))


func _copy_identity() -> void:
	DisplayServer.clipboard_set(_my_identity)
	_say("Identity copied.", TempleTheme.YELLOW)


## Publishes our fragment so the covenant can be opened.
##
## This is the release itself, not a step towards privately reading it: once
## enough witnesses testify, the word is out to everyone, permanently.
func _on_testify() -> void:
	var tablet := selected()
	if tablet == null:
		_say("Choose a covenant to testify to.", TempleTheme.YELLOW)
		return
	if not tablet.has(Tablet.Release.WITNESSES):
		_say("'%s' has no witnesses." % tablet.title, TempleTheme.YELLOW)
		return

	var testimony := Testimony.new(iq, tablet)
	var envelope := testimony.my_envelope(_my_identity)
	if envelope.is_empty():
		_say("No fragment on this tablet is addressed to you.", TempleTheme.AMBER)
		return

	var state := ark.state_of(tablet)
	if not Flame.releasable(state):
		var status: Dictionary = ark.states.get(tablet.id, {})
		var left := maxi(int(status.get("days_left", 0)), 0)
		_say(
			(
				"'%s' is not released yet — its keeper is overdue, not gone. "
				% tablet.title
				+ "Publishing is refused for another %d day(s). If they are "
				% left
				+ "genuinely unreachable, wait it out; that wait is the whole "
				+ "point of the grace period."
			),
			TempleTheme.BRIGHT_RED
		)
		return

	_set_busy(true)
	_say("Opening the fragment addressed to you...", TempleTheme.YELLOW)

	# Decryption uses the wallet's identity key, so the host asks first.
	var fragment_hex := await iq.decrypt_envelope(envelope)
	if fragment_hex.is_empty():
		_say(iq.last_error, TempleTheme.BRIGHT_RED)
		_set_busy(false)
		return

	_say("Publishing your testimony. The keeper will be asked to approve this.", TempleTheme.YELLOW)
	var result = await testimony.testify(fragment_hex, str(config["keeper"]))
	if result == null:
		_say(testimony.last_error, TempleTheme.BRIGHT_RED)
	else:
		_say(
			"You have testified. %d fragment(s) are needed in all." % tablet.threshold,
			TempleTheme.CYAN
		)
	_set_busy(false)

#endregion


#region Adopting

func _show_adopt_panel() -> void:
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— ADOPT A TABLET —", TempleTheme.CYAN))
	box.add_child(
		TempleTheme.line(
			"Given a signature, the tablet says the rest: which root to watch, "
			+ "how long the silence must run, and how it opens.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	_adopt_signature = LineEdit.new()
	_adopt_signature.placeholder_text = "tablet signature"
	box.add_child(_adopt_signature)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("ADOPT", _adopt_confirmed))
	row.add_child(TempleTheme.button("CANCEL", _close_panel))


func _adopt_confirmed() -> void:
	var signature := _adopt_signature.text.strip_edges()
	_close_panel()
	if signature.is_empty():
		return

	_set_busy(true)
	var tablet := await ark.adopt(signature, str(config["chain"]))
	if tablet == null:
		_say(ark.last_error, TempleTheme.BRIGHT_RED)
	else:
		_say("Adopted '%s'." % tablet.title, TempleTheme.CYAN)
		selected_id = tablet.id
		await _refresh()
	_set_busy(false)

#endregion


#region Sealing

func _show_seal_panel() -> void:
	if str(config["db_root_id"]).strip_edges().is_empty():
		_say("Name your records in SET UP first.", TempleTheme.BRIGHT_RED)
		return
	if iq == null or not iq.is_available():
		_say("Not attached to a host.", TempleTheme.BRIGHT_RED)
		return

	_seal_file_path = ""
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— SEAL A COVENANT —", TempleTheme.BRIGHT_RED))

	# 1. What is being sealed.
	box.add_child(_section("WHAT IS BEING SEALED"))

	var name_row := _labelled(box, "Name")
	_seal_title = LineEdit.new()
	_seal_title.placeholder_text = "what to call this one"
	_seal_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_seal_title)

	_seal_body = TextEdit.new()
	_seal_body.custom_minimum_size = Vector2(0, 110)
	_seal_body.placeholder_text = "The word to be kept until the flame goes dark..."
	_seal_body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(_seal_body)

	var file_row := _labelled(box, "Or a file")
	file_row.add_child(TempleTheme.button("CHOOSE A FILE", _choose_file))
	_seal_file_label = _plain("none chosen")
	file_row.add_child(_seal_file_label)

	# 2. How it can be opened. Each mode reveals its own settings, so nothing
	#    is on screen that does not currently apply.
	box.add_child(_section("HOW IT CAN BE OPENED"))

	_seal_use_witnesses = CheckBox.new()
	_seal_use_witnesses.text = "Witnesses hold pieces of the key"
	_seal_use_witnesses.button_pressed = true
	_seal_use_witnesses.toggled.connect(_on_mode_toggled.bind("guarded"))
	box.add_child(_seal_use_witnesses)

	_witness_panel = VBoxContainer.new()
	_witness_panel.add_theme_constant_override("separation", 4)
	box.add_child(_witness_panel)

	var threshold_row := _labelled(_witness_panel, "        Needed to open")
	_seal_threshold = SpinBox.new()
	_seal_threshold.min_value = 1
	_seal_threshold.max_value = 16
	_seal_threshold.value = 2
	_seal_threshold.value_changed.connect(_on_counts_changed)
	threshold_row.add_child(_seal_threshold)
	_witness_count_label = _plain("")
	threshold_row.add_child(_witness_count_label)

	_seal_include_self = CheckBox.new()
	_seal_include_self.text = "Count myself as one of them"
	_seal_include_self.button_pressed = true
	_seal_include_self.tooltip_text = (
		"Keeps a piece for this wallet, so you can reopen your own covenant later."
	)
	_seal_include_self.toggled.connect(_on_modes_changed)
	_witness_panel.add_child(_seal_include_self)

	_witness_box = VBoxContainer.new()
	_witness_box.add_theme_constant_override("separation", 4)
	_witness_panel.add_child(_witness_box)
	_witness_rows = []
	# One row to begin with. Three empty rows looked like three obligations.
	_add_witness_row()

	var add_row := HBoxContainer.new()
	add_row.add_child(_plain("        "))
	add_row.add_child(TempleTheme.button("+ ADD WITNESS", _add_witness_row))
	_witness_panel.add_child(add_row)
	_witness_panel.add_child(
		_hint("Leave a key blank and you hand that piece over yourself.")
	)

	_seal_use_burn = CheckBox.new()
	_seal_use_burn.text = "Anyone, once the flame goes dark"
	_seal_use_burn.tooltip_text = (
		"Publishes the key with the covenant. Cannot be combined with the "
		+ "others, because it would make them meaningless."
	)
	_seal_use_burn.toggled.connect(_on_mode_toggled.bind("burn"))
	box.add_child(_seal_use_burn)

	_seal_use_timelock = CheckBox.new()
	_seal_use_timelock.text = "Anyone who solves a puzzle"
	_seal_use_timelock.toggled.connect(_on_mode_toggled.bind("guarded"))
	box.add_child(_seal_use_timelock)

	_timelock_panel = HBoxContainer.new()
	_timelock_panel.add_theme_constant_override("separation", 8)
	_timelock_panel.add_child(_plain("        Taking about"))
	_seal_timelock_days = SpinBox.new()
	_seal_timelock_days.min_value = 1
	_seal_timelock_days.max_value = 3650
	_seal_timelock_days.value = 30
	_seal_timelock_days.value_changed.connect(_on_counts_changed)
	_timelock_panel.add_child(_seal_timelock_days)
	_timelock_panel.add_child(_plain("days of computing"))
	box.add_child(_timelock_panel)

	# 3. Terms. Per covenant, not per app: one may live on Solana and be checked
	#    weekly, another on Monad and be checked once a year.
	box.add_child(_section("ITS OWN CLOCK"))

	var chain_row := _labelled(box, "Chain")
	_seal_chain = OptionButton.new()
	for i in CHAINS.size():
		_seal_chain.add_item(str(CHAINS[i][0]), i)
		if str(CHAINS[i][1]) == str(config["chain"]).to_lower():
			_seal_chain.select(i)
	if _seal_chain.selected < 0:
		_seal_chain.select(0)
	_seal_chain.item_selected.connect(_on_counts_changed)
	chain_row.add_child(_seal_chain)

	var interval_row := _labelled(box, "Check in every")
	_seal_interval = SpinBox.new()
	_seal_interval.min_value = 1
	_seal_interval.max_value = 365
	_seal_interval.value = int(config["interval_days"])
	_seal_interval.value_changed.connect(_on_counts_changed)
	interval_row.add_child(_seal_interval)
	interval_row.add_child(_plain("days"))

	var grace_row := _labelled(box, "Release after a further")
	_seal_grace = SpinBox.new()
	_seal_grace.min_value = 1
	_seal_grace.max_value = 730
	_seal_grace.value = int(config["grace_days"])
	_seal_grace.value_changed.connect(_on_counts_changed)
	grace_row.add_child(_seal_grace)
	grace_row.add_child(_plain("days of silence"))

	_seal_terms_line = _hint("")
	box.add_child(_seal_terms_line)

	# 4. Who can find it. Separate from how it opens: findable is not readable.
	_mode_note = _hint("")
	box.add_child(_mode_note)

	box.add_child(_section("WHERE IT CAN BE FOUND"))
	_seal_list_publicly = CheckBox.new()
	_seal_list_publicly.text = "List publicly, so strangers can find and watch it"
	_seal_list_publicly.toggled.connect(_on_modes_changed)
	box.add_child(_seal_list_publicly)

	box.add_child(HSeparator.new())
	_seal_warning = TempleTheme.line("", TempleTheme.AMBER, TempleTheme.SIZE_SMALL)
	_seal_warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(_seal_warning)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("SEAL IT", _seal_confirmed))
	row.add_child(TempleTheme.button("CANCEL", _close_panel))

	_on_modes_changed(true)


## A quiet heading, so the panel reads as three decisions rather than a list of
## twenty controls.
func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", TempleTheme.YELLOW)
	label.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	return label


## One witness: a name for the prompt, and optionally their identity key.
func _add_witness_row(name_text: String = "", identity: String = "") -> void:
	if _witness_box == null or _witness_rows.size() >= 16:
		return

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_plain("        "))

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "who"
	name_edit.text = name_text
	name_edit.custom_minimum_size = Vector2(150, 0)
	name_edit.text_changed.connect(_on_witness_text_changed)
	row.add_child(name_edit)

	var id_edit := LineEdit.new()
	id_edit.placeholder_text = "their identity key, or blank to hand over yourself"
	id_edit.text = identity
	id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_edit.text_changed.connect(_on_witness_text_changed)
	row.add_child(id_edit)

	var entry := {"name": name_edit, "identity": id_edit, "row": row}
	var drop := TempleTheme.button("−", _remove_witness_row.bind(entry))
	drop.tooltip_text = "Remove this witness"
	row.add_child(drop)

	_witness_box.add_child(row)
	_witness_rows.append(entry)
	_on_counts_changed(0.0)


func _remove_witness_row(entry: Dictionary) -> void:
	# Always leave one row: an empty list with no way back is a dead end.
	if _witness_rows.size() <= 1:
		(entry["name"] as LineEdit).text = ""
		(entry["identity"] as LineEdit).text = ""
		_on_counts_changed(0.0)
		return
	_witness_rows.erase(entry)
	(entry["row"] as Node).queue_free()
	_on_counts_changed(0.0)


func _on_witness_text_changed(_text: String) -> void:
	_on_counts_changed(0.0)


## Witness entries that have been filled in at all. Blank rows are ignored, so
## the count follows what the keeper actually typed.
func _witnesses() -> Array:
	var out: Array = []
	# The keeper's own wallet counts as a witness when asked for, which is what
	# makes a single named witness sensible: the two of you, both needed.
	if _seal_include_self != null and _seal_include_self.button_pressed:
		if not _my_identity.is_empty():
			out.append({"name": "you", "identity": _my_identity})
	for entry: Dictionary in _witness_rows:
		var name_text: String = (entry["name"] as LineEdit).text.strip_edges()
		var identity: String = (entry["identity"] as LineEdit).text.strip_edges().to_lower()
		if name_text.is_empty() and identity.is_empty():
			continue
		out.append({
			"name": name_text if not name_text.is_empty() else "witness %d" % (out.size() + 1),
			"identity": identity,
		})
	return out


func _choose_file() -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.use_native_dialog = true
		_file_dialog.file_selected.connect(_on_file_chosen)
		add_child(_file_dialog)
	_file_dialog.popup_centered_ratio(0.6)


func _on_file_chosen(path: String) -> void:
	_seal_file_path = path
	if _seal_file_label != null:
		_seal_file_label.text = path.get_file()
		_seal_file_label.add_theme_color_override("font_color", TempleTheme.CYAN)
	_on_counts_changed(0.0)


## A public burn cancels the others rather than adding to them, so ticking one
## side clears the other instead of quietly producing a covenant whose
## safeguards do nothing.
func _on_mode_toggled(pressed: bool, which: String) -> void:
	if pressed:
		if which == "burn":
			_seal_use_witnesses.set_pressed_no_signal(false)
			_seal_use_timelock.set_pressed_no_signal(false)
		else:
			_seal_use_burn.set_pressed_no_signal(false)
	_on_modes_changed(pressed)


## Each mode shows only its own settings, and modes that cannot apply are
## disabled rather than merely ignored.
func _on_modes_changed(_pressed: bool) -> void:
	if _witness_panel == null:
		return

	var burning := _seal_use_burn.button_pressed
	var guarded: bool = _seal_use_witnesses.button_pressed or _seal_use_timelock.button_pressed

	_seal_use_witnesses.disabled = burning
	_seal_use_timelock.disabled = burning
	_seal_use_burn.disabled = guarded

	_witness_panel.visible = _seal_use_witnesses.button_pressed
	_timelock_panel.visible = _seal_use_timelock.button_pressed

	if _mode_note != null:
		if burning:
			_mode_note.text = (
				"        Open to anyone means the key travels with the covenant, "
				+ "so witnesses and a puzzle would guard nothing. It is used on "
				+ "its own."
			)
		elif guarded:
			_mode_note.text = (
				"        Witnesses and a puzzle can be combined — whichever "
				+ "happens first opens it."
			)
		else:
			_mode_note.text = "        Choose at least one, or this can never be opened."

	_on_counts_changed(0.0)


## Short consequences, one line each, instead of three stacked paragraphs that
## pushed the buttons off the bottom of the panel.
func _on_counts_changed(_value: float) -> void:
	if _seal_warning == null:
		return

	var lines: PackedStringArray = []
	lines.append("Nothing sealed can ever be edited, deleted or recalled.")

	if _seal_use_witnesses.button_pressed:
		var witnesses := _witnesses()
		var wrapped := 0
		for entry: Dictionary in witnesses:
			if not str(entry["identity"]).is_empty():
				wrapped += 1
		# "of 0 witnesses" is accurate and reads like a bug, so say what to do
		# instead until there is somebody to count.
		# Never ask for more pieces than exist; silently clamp rather than let
		# someone seal something nobody can ever open.
		_seal_threshold.max_value = maxi(witnesses.size(), 1)
		if witnesses.is_empty():
			_witness_count_label.text = "— name at least one witness below"
		else:
			_witness_count_label.text = "of %d" % witnesses.size()
			if int(_seal_threshold.value) <= 1 and witnesses.size() >= 1:
				lines.append(
					"Any one of them can open this whenever they like — one "
					+ "piece is the whole key."
				)
		if witnesses.size() - wrapped > 0:
			lines.append(
				"%d fragment(s) have no identity key — you deliver those by hand, "
				% (witnesses.size() - wrapped)
				+ "shown once and never stored."
			)

	if _seal_use_burn.button_pressed:
		lines.append(
			"Open to anyone: the key travels in the tablet, so it can be read "
			+ "from day one. A convention, not a lock."
		)

	if _seal_use_timelock.button_pressed:
		lines.append(
			"Puzzle: the clock starts now, not when your flame goes out, and "
			+ "faster hardware finishes sooner."
		)

	if _seal_list_publicly.button_pressed:
		lines.append("Listed publicly: strangers can find it and watch its clock run down.")

	if not (
		_seal_use_witnesses.button_pressed
		or _seal_use_burn.button_pressed
		or _seal_use_timelock.button_pressed
	):
		lines.append("Choose at least one way for this to be opened, or it never can be.")

	# Estimate what this will cost, from whatever is in the box right now.
	var bytes := _seal_body.text.to_utf8_buffer().size()
	if not _seal_file_path.is_empty() and FileAccess.file_exists(_seal_file_path):
		var file := FileAccess.open(_seal_file_path, FileAccess.READ)
		if file != null:
			@warning_ignore("integer_division")
			bytes = (file.get_length() + 2) / 3 * 4
			file.close()
	var sealing_chain := str(config["chain"])
	if _seal_chain != null:
		sealing_chain = str(CHAINS[maxi(_seal_chain.selected, 0)][1])
	lines.append(
		"Sealing this costs about %s."
		% Costs.format(sealing_chain, Costs.for_bytes(sealing_chain, bytes))
	)

	if _seal_terms_line != null and _seal_interval != null:
		var interval := int(_seal_interval.value)
		var grace := int(_seal_grace.value)
		var chain := str(CHAINS[maxi(_seal_chain.selected, 0)][1])
		_seal_terms_line.text = (
			"        Overdue after %d days, released after %d.  Checking in costs %s a year."
			% [interval, interval + grace, Costs.format(chain, Costs.per_year(chain, interval))]
		)

	_seal_warning.text = "\n".join(lines)


func _seal_confirmed() -> void:
	var release: int = Tablet.Release.NONE
	if _seal_use_witnesses.button_pressed:
		release |= Tablet.Release.WITNESSES
	if _seal_use_burn.button_pressed:
		release |= Tablet.Release.PUBLIC_BURN
	if _seal_use_timelock.button_pressed:
		release |= Tablet.Release.TIME_LOCK

	if not Tablet.release_is_coherent(release):
		if release == Tablet.Release.NONE:
			_say("Choose at least one way for this to be opened.", TempleTheme.BRIGHT_RED)
		else:
			_say(
				"Open-to-anyone cannot be combined with the others: it would "
				+ "make them do nothing.",
				TempleTheme.BRIGHT_RED
			)
		return

	var witness_list := _witnesses()
	var witnesses := witness_list.size()
	var threshold := mini(int(_seal_threshold.value), maxi(witnesses, 1))
	if (release & Tablet.Release.WITNESSES) != 0:
		if witnesses < 1:
			_say("Name at least one witness.", TempleTheme.BRIGHT_RED)
			return

	# A file wins over the text box when both are filled in.
	var payload := ""
	var kind := Tablet.Payload.TEXT
	var filename := ""
	var filetype := ""

	if not _seal_file_path.is_empty():
		var file := FileAccess.open(_seal_file_path, FileAccess.READ)
		if file == null:
			_say("Could not read that file.", TempleTheme.BRIGHT_RED)
			return
		payload = Marshalls.raw_to_base64(file.get_buffer(file.get_length()))
		file.close()
		kind = Tablet.Payload.FILE
		filename = _seal_file_path.get_file()
		filetype = _seal_file_path.get_extension().to_lower()
	else:
		payload = _seal_body.text
		if payload.strip_edges().is_empty():
			_say("There is nothing to seal.", TempleTheme.BRIGHT_RED)
			return

	var title := _seal_title.text.strip_edges()
	if title.is_empty():
		title = filename if not filename.is_empty() else "untitled"

	_close_panel()
	_set_busy(true)

	var tablet := Tablet.new()
	tablet.id = Ark.mint_id(title)
	tablet.title = title
	tablet.keeper = str(config["keeper"])
	tablet.db_root_id = str(config["db_root_id"])
	# Each covenant keeps its own chain and clock.
	tablet.chain = str(CHAINS[maxi(_seal_chain.selected, 0)][1])
	tablet.interval_days = int(_seal_interval.value)
	tablet.grace_days = int(_seal_grace.value)
	tablet.payload_kind = kind
	tablet.filename = filename
	tablet.filetype = filetype
	tablet.release = release
	tablet.public_listing = _seal_list_publicly.button_pressed
	tablet.threshold = threshold
	tablet.witness_count = witnesses if (release & Tablet.Release.WITNESSES) != 0 else 0

	var sealed := covenant.seal(payload, {})
	if sealed.is_empty():
		_say(covenant.last_error, TempleTheme.BRIGHT_RED)
		_set_busy(false)
		return

	var record: Dictionary = sealed["tablet"]
	var key: PackedByteArray = sealed["key"]
	tablet.iv_hex = str(record.get("iv", ""))
	tablet.ciphertext_b64 = str(record.get("ciphertext", ""))
	tablet.sealed_at = int(record.get("sealed_at", 0))

	# A public burn simply carries the key. Nothing is hidden about that.
	if (release & Tablet.Release.PUBLIC_BURN) != 0:
		tablet.burn_key_hex = key.hex_encode()

	if (release & Tablet.Release.TIME_LOCK) != 0:
		var days := int(_seal_timelock_days.value)
		_say("Building the puzzle. This is quick for you and slow for everyone else.", TempleTheme.YELLOW)
		var puzzle := await iq.timelock_create(key.hex_encode(), days * 86400)
		if puzzle.is_empty():
			_say("Could not build the time lock: %s" % iq.last_error, TempleTheme.BRIGHT_RED)
			_set_busy(false)
			return
		tablet.timelock = puzzle
		_say(
			"Sealed behind roughly %d days of computing (%s squarings)."
			% [days, str(puzzle.get("t", "?"))],
			TempleTheme.CYAN
		)

	# Fragments with an identity are wrapped and inscribed with the tablet; the
	# rest come back to the keeper to hand over in person.
	var undelivered: Array[PackedByteArray] = []
	var undelivered_names: Array = []
	if (release & Tablet.Release.WITNESSES) != 0:
		var fragments: Array[PackedByteArray] = []
		if threshold <= 1:
			# Any one of them opens it, so each simply gets the whole key.
			# Splitting into one-of-n is not a threshold scheme.
			for i in witnesses:
				var whole := PackedByteArray([0])
				whole.append_array(key)
				fragments.append(whole)
		else:
			fragments = covenant.shatter(key, witnesses, threshold)
		if fragments.is_empty():
			_say(covenant.last_error, TempleTheme.BRIGHT_RED)
			_set_busy(false)
			return

		for i in witnesses:
			var witness: Dictionary = witness_list[i]
			var identity := str(witness["identity"])
			if identity.is_empty():
				undelivered.append(fragments[i])
				undelivered_names.append(str(witness["name"]))
				continue

			var envelope := await iq.encrypt_to(
				PackedStringArray([identity]), Shamir.to_hex(fragments[i])
			)
			if envelope.is_empty():
				_say(
					"Could not wrap the fragment for %s: %s"
					% [str(witness["name"]), iq.last_error],
					TempleTheme.BRIGHT_RED
				)
				_set_busy(false)
				return

			tablet.witness_envelopes.append({
				"recipient": identity,
				"label": str(witness["name"]),
				"envelope": envelope,
			})

	_say("Inscribing '%s'. The keeper will be asked to approve this." % title, TempleTheme.YELLOW)
	var signature = await covenant.inscribe(tablet.to_record(), tablet.chain)
	if signature == null:
		_say(covenant.last_error, TempleTheme.BRIGHT_RED)
		_set_busy(false)
		return

	# Remembered as the starting point for the next covenant, not as a setting.
	config["chain"] = tablet.chain
	config["interval_days"] = tablet.interval_days
	config["grace_days"] = tablet.grace_days
	tablet.signature = str(signature)
	ark.add(tablet)
	selected_id = tablet.id

	_say("The tablet is inscribed: %s" % str(signature), TempleTheme.CYAN)
	await _publish_listings(tablet)
	if not tablet.witness_envelopes.is_empty():
		_say(
			"%d fragment(s) travelled with it, wrapped so only their witness can "
			% tablet.witness_envelopes.size()
			+ "open them. Those witnesses need nothing but the signature.",
			TempleTheme.CYAN
		)
	_say("Now build its altar, then tend the flame.", TempleTheme.YELLOW)
	_set_busy(false)
	_rebuild_list()

	if not undelivered.is_empty():
		_show_fragments(undelivered, undelivered_names, threshold, str(signature))


## The fragments exist in memory and nowhere else. This is the only time they
## are shown, and nothing writes them down — putting every fragment in one file
## would undo the whole point of splitting them.
func _show_fragments(
	fragments: Array[PackedByteArray], names: Array, threshold: int, signature: String
) -> void:
	var box := _open_panel_box()

	box.add_child(TempleTheme.title("— FRAGMENTS TO DELIVER —", TempleTheme.YELLOW))
	box.add_child(
		TempleTheme.line(
			"These witnesses had no identity key, so you deliver theirs by hand, "
			+ "by some means that is not this machine. They are shown once and "
			+ "never stored. Close this and they are gone.",
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
		var who: String = str(names[i]) if i < names.size() else "witness %d" % (i + 1)
		lines.append(who.to_upper() + ":")
		lines.append(Shamir.to_hex(fragments[i]))
		lines.append("")
	_fragments_listing.text = "\n".join(lines)
	box.add_child(_fragments_listing)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("COPY ALL", _fragments_copy))
	row.add_child(TempleTheme.button("DONE — I HAVE SENT THEM", _fragments_done))


func _fragments_copy() -> void:
	DisplayServer.clipboard_set(_fragments_listing.text)
	_say("Fragments copied. Distribute them now.", TempleTheme.YELLOW)


func _fragments_done() -> void:
	_close_panel()
	_say("The fragments are forgotten by this machine.", TempleTheme.GREY)

#endregion


#region Opening

func _show_open_panel() -> void:
	var tablet := selected()
	if tablet == null:
		_say("Choose a covenant to open.", TempleTheme.YELLOW)
		return

	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— OPEN '%s' —" % tablet.title.to_upper(), TempleTheme.CYAN))

	var state := ark.state_of(tablet)
	var releasable := Flame.releasable(state)
	if not releasable:
		var status: Dictionary = ark.states.get(tablet.id, {})
		var left := maxi(int(status.get("days_left", 0)), 0)
		var why := (
			"Its flame has not been read yet, so there is nothing to act on."
			if state == Flame.State.UNKNOWN or state == Flame.State.NEVER_LIT
			else "Its keeper is overdue, not gone — %d day(s) of grace remain." % left
		)
		box.add_child(
			TempleTheme.line(
				"This covenant is not released. " + why,
				TempleTheme.AMBER,
				TempleTheme.SIZE_SMALL
			)
		)

	# Which routes this tablet has decides everything below it, so it goes first.
	# Showing a fragments box on a covenant sealed with none of them is how a
	# reader ends up hunting for something that was never issued.
	box.add_child(TempleTheme.line("HOW THIS ONE OPENS", TempleTheme.YELLOW, TempleTheme.SIZE_SMALL))
	for route: Dictionary in tablet.routes():
		box.add_child(
			TempleTheme.line("  " + str(route["text"]), TempleTheme.GREY, TempleTheme.SIZE_SMALL)
		)
	box.add_child(HSeparator.new())

	# Only built when this tablet actually has witnesses.
	_open_fragments = null

	if tablet.has(Tablet.Release.PUBLIC_BURN):
		box.add_child(
			TempleTheme.line(
				"Its key rides in the tablet itself. Press OPEN — there is nothing "
				+ "to gather and nobody to ask.",
				TempleTheme.GREY,
				TempleTheme.SIZE_SMALL
			)
		)

	if tablet.has(Tablet.Release.WITNESSES):
		box.add_child(
			TempleTheme.line(
				"FRAGMENTS — %d OF %d NEEDED" % [tablet.threshold, tablet.witness_count],
				TempleTheme.YELLOW,
				TempleTheme.SIZE_SMALL
			)
		)
		box.add_child(
			TempleTheme.line(
				"A fragment is a line of hex handed to a witness when this was sealed; "
				+ "no one of them opens anything alone. Fragments already testified "
				+ "on-chain are counted for you. Paste here only ones given to you "
				+ "privately, one per line.",
				TempleTheme.GREY,
				TempleTheme.SIZE_SMALL
			)
		)
		_open_fragments = TextEdit.new()
		_open_fragments.custom_minimum_size = Vector2(0, 160)
		_open_fragments.placeholder_text = "One fragment per line..."
		box.add_child(_open_fragments)

	if tablet.has(Tablet.Release.TIME_LOCK):
		box.add_child(TempleTheme.line("THE PUZZLE", TempleTheme.YELLOW, TempleTheme.SIZE_SMALL))
		box.add_child(
			TempleTheme.line(
				(
					"This route asks nothing of anyone. Your own machine grinds out a "
					+ "sum that takes about %s, and the answer is the key. It cannot be "
					+ "hurried, split across machines, or paused — closing the app loses "
					+ "the progress and starts it over."
				) % tablet.timelock_duration(),
				TempleTheme.GREY,
				TempleTheme.SIZE_SMALL
			)
		)

	_open_result = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	box.add_child(_open_result)

	var row := _button_row(box)
	if releasable:
		# One button per route it actually has, so nothing on screen leads nowhere.
		if tablet.has(Tablet.Release.PUBLIC_BURN):
			row.add_child(TempleTheme.button("OPEN", _open_confirmed))
		elif tablet.has(Tablet.Release.WITNESSES):
			row.add_child(TempleTheme.button("OPEN WITH FRAGMENTS", _open_confirmed))
		if tablet.has(Tablet.Release.TIME_LOCK):
			row.add_child(
				TempleTheme.button(
					"SOLVE THE PUZZLE (~%s)" % tablet.timelock_duration(), _solve_confirmed
				)
			)
	row.add_child(TempleTheme.button("CANCEL", _close_panel))

func _open_confirmed() -> void:
	var tablet := selected()
	if tablet == null:
		return
	# Belt and braces: the buttons are hidden, but nothing should release a
	# covenant whose keeper may simply be on holiday.
	if not Flame.releasable(ark.state_of(tablet)):
		_result("This covenant is not released yet.", TempleTheme.BRIGHT_RED)
		return

	_result("Fetching the tablet...", TempleTheme.GREY)
	var record := await covenant.fetch(tablet.signature, tablet.chain)
	if record.is_empty():
		_result(covenant.last_error, TempleTheme.BRIGHT_RED)
		return

	var key := PackedByteArray()

	if tablet.has(Tablet.Release.PUBLIC_BURN):
		key = Covenant.hex_to_bytes(str(record.get("burn_key", tablet.burn_key_hex)))
		if key.is_empty():
			_result("This tablet claims a public burn but carries no key.", TempleTheme.BRIGHT_RED)
			return
	elif _solving_timelock:
		# The slow road, taken only when the reader asked for it.
		var puzzle: Variant = record.get("timelock", tablet.timelock)
		if not puzzle is Dictionary or (puzzle as Dictionary).is_empty():
			_result("This tablet has no puzzle to solve.", TempleTheme.BRIGHT_RED)
			return
		_result("Solving. This will take about %s and cannot be hurried." % tablet.timelock_duration(), TempleTheme.YELLOW)
		var secret := await iq.timelock_solve(puzzle, _on_solve_progress)
		_solving_timelock = false
		if secret.is_empty():
			_result(iq.last_error, TempleTheme.BRIGHT_RED)
			return
		key = Covenant.hex_to_bytes(secret)
	else:
		if not tablet.has(Tablet.Release.WITNESSES):
			_result(
				"No witnesses hold this one. Use SOLVE THE PUZZLE.", TempleTheme.YELLOW
			)
			return
		# Whatever witnesses have published counts on its own once the threshold
		# is met; pasted fragments only top it up.
		_result("Gathering testimony...", TempleTheme.GREY)
		var testimony := Testimony.new(iq, tablet)
		var gathered: Dictionary = await testimony.gather()

		var fragments: Array[PackedByteArray] = gathered.get("fragments", [])
		var seen := {}
		for already: PackedByteArray in fragments:
			seen[already[0]] = true

		if not fragments.is_empty():
			_say(
				"%d witness(es) have testified: %s"
				% [fragments.size(), ", ".join(gathered.get("witnesses", []))],
				TempleTheme.CYAN
			)
		# The box is built only on the witness route, so it may not be there.
		var pasted := _open_fragments.text if _open_fragments != null else ""
		for raw: String in pasted.split("\n", false):
			if raw.strip_edges().is_empty():
				continue
			var fragment := covenant.read_fragment(raw)
			if fragment.is_empty():
				_result(covenant.last_error, TempleTheme.BRIGHT_RED)
				return
			if seen.has(fragment[0]):
				continue
			seen[fragment[0]] = true
			fragments.append(fragment)

		if fragments.size() < tablet.threshold:
			_result(
				"This tablet needs %d fragments. You have %d."
				% [tablet.threshold, fragments.size()],
				TempleTheme.YELLOW
			)
			return

		key = covenant.gather(fragments)
		if key.is_empty():
			_result(covenant.last_error, TempleTheme.BRIGHT_RED)
			return

	var text := covenant.unseal(record, key)
	if text.is_empty():
		_result(covenant.last_error, TempleTheme.BRIGHT_RED)
		return

	_result("The tablet is open.", TempleTheme.CYAN)

	if tablet.payload_kind == Tablet.Payload.FILE:
		_save_opened_file(tablet, text)
	else:
		_say("=== THE WORD OF '%s' ===" % tablet.title, TempleTheme.YELLOW)
		_say(text, TempleTheme.WHITE)


func _save_opened_file(tablet: Tablet, base64_data: String) -> void:
	var bytes := Marshalls.base64_to_raw(base64_data)
	if bytes.is_empty():
		_say("The tablet opened, but its contents are not a file.", TempleTheme.BRIGHT_RED)
		return

	DirAccess.make_dir_recursive_absolute("user://opened")
	var name := tablet.filename if not tablet.filename.is_empty() else tablet.id
	var path := "user://opened/%s" % name
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_say("Could not write the file out.", TempleTheme.BRIGHT_RED)
		return
	file.store_buffer(bytes)
	file.close()

	_say("=== THE WORD OF '%s' ===" % tablet.title, TempleTheme.YELLOW)
	_say("Written to %s" % ProjectSettings.globalize_path(path), TempleTheme.WHITE)


## Starts the long climb. Kept behind its own button so nobody begins days of
## computing by pressing the ordinary OPEN.
func _solve_confirmed() -> void:
	_solving_timelock = true
	await _open_confirmed()


func _on_solve_progress(percent: float) -> void:
	_result(
		"Solving... %d%%. This cannot be hurried, and closing the app loses the progress."
		% int(percent),
		TempleTheme.YELLOW
	)


func _result(message: String, colour: Color) -> void:
	if _open_result == null:
		return
	_open_result.add_theme_color_override("font_color", colour)
	_open_result.text = message

#endregion


#region Settings

## Chains the app can write to. The value is what the SDK expects; the label is
## what a person recognises.
const CHAINS := [["SOL — Solana", "sol"], ["MON — Monad", "mon"]]

## Width of the label column, so every control lines up down the panel.
const LABEL_COLUMN := 200

var _cost_line: Label
var _timing_line: Label


func _show_settings() -> void:
	var box := _open_panel_box()
	_settings_fields = {}

	box.add_child(TempleTheme.title("— SETUP —", TempleTheme.YELLOW))

	_settings_fields["keeper"] = _field_row(
		box, "Your name", "keeper", "what your witnesses will see"
	)

	# The only field whose meaning nobody could guess, so it is the only one
	# with a sentence under it — and a button that fills it in.
	_settings_fields["db_root_id"] = _field_row(
		box, "Name for your records", "db_root_id", "like a username", true
	)
	box.add_child(
		_hint("Witnesses need this to find what you sealed. Keep it somewhere they will look.")
	)

	box.add_child(HSeparator.new())
	box.add_child(
		_hint(
			"Which chain a covenant lives on, and how often you must check in, "
			+ "are chosen for each covenant when you seal it — not here."
		)
	)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("SAVE", _settings_keep))
	row.add_child(TempleTheme.button("CANCEL", _close_panel))


## Label on the left, control on the right, aligned down the panel.
func _labelled(box: VBoxContainer, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var caption := Label.new()
	caption.text = label
	caption.custom_minimum_size = Vector2(LABEL_COLUMN, 0)
	caption.add_theme_color_override("font_color", TempleTheme.GREY)
	caption.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	row.add_child(caption)
	box.add_child(row)
	return row


## Quiet note, indented under the field it belongs to.
func _hint(text: String) -> Label:
	var note := Label.new()
	note.text = "        " + text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", TempleTheme.GREY)
	note.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	return note


func _field_row(
	box: VBoxContainer, label: String, key: String, hint: String, suggestable: bool = false
) -> LineEdit:
	var row := _labelled(box, label)
	var edit := LineEdit.new()
	edit.text = str(config.get(key, ""))
	edit.placeholder_text = hint
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	if suggestable:
		row.add_child(TempleTheme.button("SUGGEST", _suggest_root))
	return edit


func _chain_row(box: VBoxContainer) -> OptionButton:
	var row := _labelled(box, "Chain")
	var picker := OptionButton.new()
	var current := str(config["chain"]).to_lower()
	for i in CHAINS.size():
		picker.add_item(str(CHAINS[i][0]), i)
		if str(CHAINS[i][1]) == current:
			picker.select(i)
	if picker.selected < 0:
		picker.select(0)
	picker.item_selected.connect(_on_setting_changed)
	row.add_child(picker)
	return picker


func _spin_row(
	box: VBoxContainer, label: String, unit: String, value: int, low: int, high: int
) -> SpinBox:
	var row := _labelled(box, label)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.value = value
	spin.value_changed.connect(_on_setting_changed)
	row.add_child(spin)
	row.add_child(_plain(unit))
	return row.get_child(1)


func _plain(text: String) -> Label:
	var note := Label.new()
	note.text = text
	note.add_theme_color_override("font_color", TempleTheme.GREY)
	note.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	return note


func _on_setting_changed(_value: Variant) -> void:
	_update_summaries()


## The two lines that answer "what did I just choose", in numbers.
func _update_summaries() -> void:
	if _cost_line == null or _timing_line == null:
		return

	var picker: OptionButton = _settings_fields["chain"]
	var chain := str(CHAINS[maxi(picker.selected, 0)][1])
	var interval := int((_settings_fields["interval_days"] as SpinBox).value)
	var grace := int((_settings_fields["grace_days"] as SpinBox).value)

	_cost_line.text = "        %s  ·  checking in costs %s a year at this rate." % [
		Costs.comparison(),
		Costs.format(chain, Costs.per_year(chain, interval)),
	]
	_timing_line.text = "        Overdue after %d days.  Released after %d days of silence." % [
		interval, interval + grace
	]


## Fills in a record name so nobody has to invent one. Built from the keeper's
## name where there is one, plus randomness, because two people sharing a name
## on-chain would share their records.
func _suggest_root() -> void:
	var edit: LineEdit = _settings_fields.get("db_root_id")
	if edit == null:
		return
	var keeper: LineEdit = _settings_fields.get("keeper")
	var stem := Tablet.slug(keeper.text if keeper != null else "")
	stem = stem.strip_edges().replace("_", "")
	if stem.length() < 3:
		stem = "bush"
	edit.text = "%s-%s" % [stem.substr(0, 12), Crypto.new().generate_random_bytes(3).hex_encode()]


func _settings_keep() -> void:
	config["keeper"] = (_settings_fields["keeper"] as LineEdit).text.strip_edges()

	var root := (_settings_fields["db_root_id"] as LineEdit).text.strip_edges()
	# It becomes part of an on-chain address, so keep it to something that will
	# survive being used as a seed and typed out by a witness.
	root = Tablet.slug(root.to_lower()).replace("_", "-")
	while root.contains("--"):
		root = root.replace("--", "-")
	config["db_root_id"] = root.lstrip("-").rstrip("-")

	_save_config()
	_close_panel()

	if str(config["db_root_id"]).is_empty():
		_say("Give your records a name before sealing anything.", TempleTheme.BRIGHT_RED)
	else:
		_say(
			"Kept. Your records live under '%s' on %s."
			% [config["db_root_id"], str(config["chain"]).to_upper()],
			TempleTheme.CYAN
		)
	_rebuild_list()

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
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	column.add_child(TempleTheme.title("BURNING  BUSH  PROTOCOL", TempleTheme.YELLOW))

	bush = BurningBush.new()
	column.add_child(bush)

	# Heard as well as seen: the same state drives both, so the room tells you
	# how the covenant is doing without being looked at.
	fire = FireSound.new()
	add_child(fire)
	fire.set_enabled(bool(config.get("ambience", true)))

	verse = TempleTheme.line("", TempleTheme.YELLOW)
	column.add_child(verse)

	gloss = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	column.add_child(gloss)

	readout = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	column.add_child(readout)

	# The mute switch lives beside the thing making the noise, and appears only
	# while something is actually burning. In a settings page it was a control
	# over something you could neither see nor hear from there.
	var sound_row := HBoxContainer.new()
	sound_row.alignment = BoxContainer.ALIGNMENT_END
	sound_toggle = CheckBox.new()
	sound_toggle.text = "Ambient sound"
	sound_toggle.button_pressed = bool(config.get("ambience", true))
	sound_toggle.add_theme_font_size_override("font_size", TempleTheme.SIZE_SMALL)
	sound_toggle.tooltip_text = "Fire while a flame burns; wind once one has gone out."
	sound_toggle.toggled.connect(_on_sound_toggled)
	sound_toggle.visible = false
	sound_row.add_child(sound_toggle)
	column.add_child(sound_row)

	# The ark itself. Scrolls, because a keeper may hold a great many.
	var ark_panel := PanelContainer.new()
	ark_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 2)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)
	ark_panel.add_child(scroll)
	column.add_child(ark_panel)

	# The app says what to do next rather than leaving it to be deduced from a
	# row of controls that are all always present.
	guidance = TempleTheme.line("", TempleTheme.YELLOW, TempleTheme.SIZE_BODY)
	column.add_child(guidance)

	action_row = HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 8)
	column.add_child(action_row)

	var console_panel := PanelContainer.new()
	console_panel.custom_minimum_size = Vector2(0, 150)
	console = RichTextLabel.new()
	console.bbcode_enabled = true
	console.scroll_following = true
	console.add_theme_font_size_override("normal_font_size", TempleTheme.SIZE_SMALL)
	console_panel.add_child(console)
	column.add_child(console_panel)

	oracle = TempleTheme.line(Scripture.oracle(), TempleTheme.AMBER, TempleTheme.SIZE_SMALL)
	column.add_child(oracle)

	var ticker := Timer.new()
	ticker.wait_time = 11.0
	ticker.timeout.connect(_turn_the_oracle)
	add_child(ticker)
	ticker.start()


func _on_sound_toggled(enabled: bool) -> void:
	config["ambience"] = enabled
	if fire != null:
		fire.set_enabled(enabled)
	_save_config()


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
		margin.add_theme_constant_override("margin_" + side, 22)
	_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(centre)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(800, 0)
	box.add_theme_constant_override("separation", 10)
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


## Narrates a write while it happens. The approval prompt appears in
## GodOnChain, which is a different window, so without this the app simply sits
## there looking broken for as long as the user takes to notice.
func _writing(what: String) -> Callable:
	# The chime belongs to GodOnChain: it raises the prompt, and it rings for
	# every app that asks, not just this one.
	_say("%s — approve it in GodOnChain." % what, TempleTheme.YELLOW)
	_progress_label = what
	_progress_shown = -1
	return _on_write_progress


func _on_write_progress(percent: float) -> void:
	var step := int(percent) / 10 * 10
	if step <= _progress_shown:
		return
	_progress_shown = step
	if step <= 0:
		_say("  %s: waiting for approval..." % _progress_label, TempleTheme.GREY)
	elif step >= 100:
		_say("  %s: done." % _progress_label, TempleTheme.CYAN)
	else:
		_say("  %s: %d%%" % [_progress_label, step], TempleTheme.GREY)


#region What to do next

## Every action, with a plain-language description. The labels say what the
## button does; the flavour lives in the verse and the oracle, not the controls.
const ACTIONS := {
	"setup": ["SET UP", "Say where your records live and how often you will check in."],
	"seal": ["NEW COVENANT", "Seal something to be released when you stop checking in."],
	"prepare": ["PREPARE", "Create this covenant's records on-chain. Needed once, before checking in."],
	"checkin": ["CHECK IN", "Prove you are still here. Do this before the deadline."],
	"open": ["OPEN", "Read what was sealed, if enough fragments are available."],
	"publish": ["PUBLISH MY FRAGMENT", "Release your piece. Once enough witnesses do, it opens for everyone."],
	"witness": ["I AM A WITNESS", "Get your identity key, or look up someone who named you."],
	"browse": ["BROWSE", "See covenants people have listed publicly, and when they run out."],
	"remove": ["REMOVE", "Stop tracking this here. It stays on-chain regardless."],
	"refresh": ["REFRESH", "Read every flame again."],
	"help": ["HELP", "How all of this works."],
	"settings": ["SETTINGS", "Change the defaults used for new covenants."],
}


## Works out what the keeper should do next, and which actions are worth
## showing at all. Returns {text, primary, actions}.
func _guidance() -> Dictionary:
	if iq == null or not iq.is_available():
		return {
			"text": (
				"Waiting for GodOnChain. Start it and unlock your keys — this "
				+ "will attach by itself."
			),
			"primary": "refresh",
			"actions": ["refresh", "help"],
		}

	if str(config["db_root_id"]).strip_edges().is_empty():
		return {
			"text": "First, tell the app where to keep your records.",
			"primary": "setup",
			"actions": ["setup", "witness", "help"],
		}

	var tablet := selected()
	if tablet == null:
		if ark.tablets.is_empty():
			return {
				"text": "Nothing is kept yet. Seal something, or add one you were named in.",
				"primary": "seal",
				"actions": ["seal", "browse", "witness", "help", "settings"],
			}
		var dark := ark.dark_tablets().size()
		if dark > 0:
			return {
				"text": "%d flame(s) have gone out. Choose one to see what can be done." % dark,
				"primary": "",
				"actions": ["seal", "browse", "witness", "refresh", "help", "settings"],
			}
		return {
			"text": "Choose a row to work on it.",
			"primary": "",
			"actions": ["seal", "browse", "witness", "refresh", "help", "settings"],
		}

	return _guidance_for(tablet)


## What can be done with the tablet currently chosen.
func _guidance_for(tablet: Tablet) -> Dictionary:
	var state := ark.state_of(tablet)
	var testimony := Testimony.new(iq, tablet)
	var i_am_witness := not testimony.my_envelope(_my_identity).is_empty()

	var common := ["refresh", "remove", "help"]
	var status: Dictionary = ark.states.get(tablet.id, {})
	var left := int(status.get("days_left", 0))

	match state:
		Flame.State.NEVER_LIT:
			return {
				"text": "'%s' has no records on-chain yet. Prepare it, then check in." % tablet.title,
				"primary": "prepare",
				"actions": ["prepare", "checkin"] + common,
			}
		Flame.State.BURNING:
			return {
				"text": "'%s' is safe. Check in again within %d days." % [tablet.title, left],
				"primary": "",
				"actions": ["checkin", "open"] + common,
			}
		Flame.State.GUTTERING:
			if i_am_witness:
				return {
					"text": (
						"'%s' is overdue, but not released. Nothing can be "
						% tablet.title
						+ "published for another %d day(s)." % maxi(left, 0)
					),
					"primary": "",
					"actions": ["checkin", "open"] + common,
				}
			return {
				"text": (
					"'%s' is overdue. Check in within %d days or it releases."
					% [tablet.title, maxi(left, 0)]
				),
				"primary": "checkin",
				"actions": ["checkin", "open"] + common,
			}
		Flame.State.DARK:
			if i_am_witness:
				return {
					"text": (
						"'%s' has gone dark and you hold a fragment. Publishing it helps open it."
						% tablet.title
					),
					"primary": "publish",
					"actions": ["publish", "open", "checkin"] + common,
				}
			return {
				"text": (
					"'%s' has gone dark. It opens once enough fragments are published."
					% tablet.title
				),
				"primary": "open",
				"actions": ["open", "checkin"] + common,
			}
		_:
			return {
				"text": "Could not read '%s'. This says nothing about its keeper." % tablet.title,
				"primary": "refresh",
				"actions": ["refresh", "open"] + common,
			}


## Redraws the guidance line and the buttons that go with it.
func _rebuild_actions() -> void:
	if action_row == null:
		return
	for child in action_row.get_children():
		child.queue_free()
	_action_buttons = []

	var advice := _guidance()
	guidance.text = str(advice["text"])
	var primary := str(advice.get("primary", ""))

	for key: String in advice["actions"]:
		var spec: Array = ACTIONS[key]
		var handler := _handler_for(key)
		var button: Button = (
			TempleTheme.primary_button(str(spec[0]), handler)
			if key == primary
			else TempleTheme.button(str(spec[0]), handler)
		)
		button.tooltip_text = str(spec[1])
		button.disabled = _busy
		action_row.add_child(button)
		_action_buttons.append(button)


func _handler_for(key: String) -> Callable:
	match key:
		"setup", "settings":
			return _show_settings
		"seal":
			return _show_seal_panel
		"prepare":
			return _on_kindle
		"checkin":
			return _on_tend
		"open":
			return _show_open_panel
		"publish":
			return _on_testify
		"witness":
			return _show_witness_door
		"browse":
			return _show_browse
		"remove":
			return _on_forget
		"refresh":
			return _refresh
		_:
			return _show_help


## The commons: everything anyone has chosen to list publicly, with how long
## each has left before it releases.
func _show_browse() -> void:
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— THE COMMONS —", TempleTheme.CYAN))
	box.add_child(
		TempleTheme.line(
			"Covenants their keepers chose to list publicly. A flame that runs "
			+ "out means its keeper stopped checking in.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	var chain_row := HBoxContainer.new()
	chain_row.add_theme_constant_override("separation", 8)
	chain_row.add_child(_plain("Looking at"))
	_browse_chain = OptionButton.new()
	for i in CHAINS.size():
		_browse_chain.add_item(str(CHAINS[i][0]), i)
		if str(CHAINS[i][1]) == str(config["chain"]).to_lower():
			_browse_chain.select(i)
	if _browse_chain.selected < 0:
		_browse_chain.select(0)
	_browse_chain.item_selected.connect(_on_browse_chain_changed)
	chain_row.add_child(_browse_chain)
	box.add_child(chain_row)

	_survey_status = TempleTheme.line("Reading the commons...", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	box.add_child(_survey_status)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	_survey_box = VBoxContainer.new()
	_survey_box.add_theme_constant_override("separation", 2)
	_survey_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_survey_box)
	box.add_child(scroll)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("CLOSE", _close_panel))

	await _fill_browse()


func _on_browse_chain_changed(_index: int) -> void:
	for child in _survey_box.get_children():
		child.queue_free()
	_survey_status.text = "Reading the commons..."
	await _fill_browse()


func _fill_browse() -> void:
	var chain := str(CHAINS[maxi(_browse_chain.selected, 0)][1])
	var found := await ark.browse(chain, _my_identity)
	if not is_instance_valid(_survey_box):
		return

	if found.is_empty():
		_survey_status.add_theme_color_override("font_color", TempleTheme.AMBER)
		_survey_status.text = ark.last_error
		return

	# Lead with what has run out, then what is closest to running out.
	found.sort_custom(_most_urgent_first)

	var expired := 0
	var mine := 0
	for entry: Dictionary in found:
		if int(entry.get("state", 0)) == Flame.State.DARK:
			expired += 1
		if bool(entry.get("i_am_witness", false)):
			mine += 1

	_survey_status.add_theme_color_override("font_color", TempleTheme.CYAN)
	_survey_status.text = "%d listed, %d expired, %d naming you." % [found.size(), expired, mine]

	for entry: Dictionary in found:
		_survey_box.add_child(_browse_row(entry))


static func _most_urgent_first(a: Dictionary, b: Dictionary) -> bool:
	var da: bool = int(a.get("state", 0)) == Flame.State.DARK
	var db: bool = int(b.get("state", 0)) == Flame.State.DARK
	if da != db:
		return da
	return int(a.get("days_left", 0)) < int(b.get("days_left", 0))


func _browse_row(entry: Dictionary) -> HBoxContainer:
	var tablet: Tablet = entry["tablet"]
	var state: Flame.State = entry["state"]
	var left := int(entry.get("days_left", 0))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var deadline := ""
	match state:
		Flame.State.DARK:
			deadline = "EXPIRED"
		Flame.State.NEVER_LIT:
			deadline = "not started"
		Flame.State.UNKNOWN:
			deadline = "unreadable"
		_:
			deadline = "%dd left" % maxi(left, 0)

	var who: String = tablet.keeper if not tablet.keeper.is_empty() else tablet.db_root_id
	var line := TempleTheme.line(
		"%s %s %s %s %s" % [
			"*" if bool(entry["i_am_witness"]) else " ",
			tablet.title.substr(0, 20).rpad(20),
			who.substr(0, 16).rpad(16),
			Flame.state_name(state).rpad(10),
			deadline.rpad(12),
		],
		_state_colour(state),
		TempleTheme.SIZE_SMALL
	)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(line)

	# An expired covenant is the only one where a way in is worth offering.
	if state == Flame.State.DARK:
		var ways := _open_routes(tablet, bool(entry["i_am_witness"]))
		row.add_child(
			TempleTheme.line(ways, TempleTheme.YELLOW, TempleTheme.SIZE_SMALL)
		)

	if bool(entry.get("already_held", false)):
		row.add_child(
			TempleTheme.line("watching", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
		)
	else:
		row.add_child(TempleTheme.button("WATCH", _watch_surveyed.bind(tablet)))

	return row


## A short phrase saying how, if at all, the reader could open this one now.
func _open_routes(tablet: Tablet, i_am_witness: bool) -> String:
	var ways: PackedStringArray = []
	if tablet.has(Tablet.Release.PUBLIC_BURN):
		ways.append("open to anyone")
	if i_am_witness:
		ways.append("you hold a fragment")
	elif tablet.has(Tablet.Release.WITNESSES):
		ways.append("needs %d witnesses" % tablet.threshold)
	return " / ".join(ways)


## One door for the witness role, so the keeper's screen is not carrying
## controls that belong to somebody else's job.
func _show_witness_door() -> void:
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— IF YOU ARE A WITNESS —", TempleTheme.CYAN))
	box.add_child(
		TempleTheme.line(
			"Somebody can name you as a witness to their covenant. You hold one "
			+ "piece of the key; it takes several to open anything.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)
	box.add_child(HSeparator.new())

	box.add_child(
		TempleTheme.line(
			"1. Give them your identity key", TempleTheme.YELLOW, TempleTheme.SIZE_SMALL
		)
	)
	var field := LineEdit.new()
	field.editable = false
	if _my_identity.is_empty():
		field.text = "no identity yet — GodOnChain needs a Solana key"
	else:
		field.text = _my_identity
	box.add_child(field)

	if not _my_identity.is_empty():
		var copy_row := HBoxContainer.new()
		copy_row.alignment = BoxContainer.ALIGNMENT_CENTER
		copy_row.add_child(TempleTheme.button("COPY MY KEY", _copy_identity))
		box.add_child(copy_row)

	box.add_child(HSeparator.new())
	box.add_child(
		TempleTheme.line(
			"2. Look up what they have sealed",
			TempleTheme.YELLOW,
			TempleTheme.SIZE_SMALL
		)
	)
	box.add_child(
		TempleTheme.line(
			"Ask them where they keep their records — a short name, not a long "
			+ "signature. Everything they have listed will show up here, marked "
			+ "with whether you hold a fragment.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	var look_row := HBoxContainer.new()
	look_row.add_theme_constant_override("separation", 8)
	_survey_root = LineEdit.new()
	_survey_root.placeholder_text = "where they keep their records"
	_survey_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	look_row.add_child(_survey_root)
	look_row.add_child(TempleTheme.button("LOOK", _survey_confirmed))
	box.add_child(look_row)

	_survey_status = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	box.add_child(_survey_status)

	_survey_box = VBoxContainer.new()
	_survey_box.add_theme_constant_override("separation", 2)
	box.add_child(_survey_box)

	box.add_child(HSeparator.new())
	box.add_child(
		TempleTheme.line(
			"Or add one directly, if they gave you its signature",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)
	_adopt_signature = LineEdit.new()
	_adopt_signature.placeholder_text = "signature"
	box.add_child(_adopt_signature)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("ADD BY SIGNATURE", _adopt_confirmed))
	row.add_child(TempleTheme.button("CLOSE", _close_panel))


## Lists everything a keeper has published under their root, with the flame
## state of each and whether we hold a fragment.
func _survey_confirmed() -> void:
	var root := _survey_root.text.strip_edges()
	if root.is_empty():
		return

	for child in _survey_box.get_children():
		child.queue_free()
	_survey_status.add_theme_color_override("font_color", TempleTheme.GREY)
	_survey_status.text = "Looking under '%s'..." % root

	var found := await ark.survey(root, str(config["chain"]), _my_identity)
	if found.is_empty():
		_survey_status.add_theme_color_override("font_color", TempleTheme.AMBER)
		_survey_status.text = ark.last_error
		return

	var mine := 0
	for entry: Dictionary in found:
		if bool(entry.get("i_am_witness", false)):
			mine += 1

	_survey_status.add_theme_color_override("font_color", TempleTheme.CYAN)
	_survey_status.text = "%d covenant(s) listed, %d naming you as a witness." % [
		found.size(), mine
	]

	for entry: Dictionary in found:
		_survey_box.add_child(_survey_row(entry))


func _survey_row(entry: Dictionary) -> HBoxContainer:
	var tablet: Tablet = entry["tablet"]
	var state: Flame.State = entry["state"]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var days := int(entry.get("days_since", -1))
	var line := TempleTheme.line(
		"%s %s  %s  %s" % [
			"*" if bool(entry["i_am_witness"]) else " ",
			tablet.title.substr(0, 22).rpad(22),
			Flame.state_name(state).rpad(10),
			("silent %dd" % days) if days >= 0 else "—",
		],
		_state_colour(state),
		TempleTheme.SIZE_SMALL
	)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(line)

	if bool(entry.get("already_held", false)):
		row.add_child(
			TempleTheme.line("already watching", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
		)
	else:
		row.add_child(TempleTheme.button("WATCH", _watch_surveyed.bind(tablet)))

	return row


func _watch_surveyed(tablet: Tablet) -> void:
	ark.add(tablet)
	_say("Now watching '%s'." % tablet.title, TempleTheme.CYAN)
	_close_panel()
	await _refresh()


func _show_help() -> void:
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— HOW THIS WORKS —", TempleTheme.YELLOW))

	var paragraphs := [
		"You seal something — a note, a file — and it is encrypted and written "
		+ "to the blockchain. It is public from that moment, but unreadable.",
		"You then check in, on a schedule you choose. Checking in writes a small "
		+ "record proving you are still here.",
		"If you stop checking in for long enough, anyone can see that. That is "
		+ "the whole trick: nobody has to decide whether you are gone.",
		"The key to the sealed thing is split into fragments and given to "
		+ "witnesses you name. No single one of them can open it.",
		"When your flame goes dark, the witnesses publish their fragments. Once "
		+ "enough are published, the sealed thing can be read.",
		"You can hold several covenants at once, each on its own schedule. The "
		+ "list shows them, worst first.",
	]
	for para: String in paragraphs:
		box.add_child(TempleTheme.line(para, TempleTheme.GREY, TempleTheme.SIZE_SMALL))

	box.add_child(HSeparator.new())
	box.add_child(
		TempleTheme.line(
			"Nothing sealed here can ever be edited, deleted or recalled. Never "
			+ "seal anyone else's private business.",
			TempleTheme.BRIGHT_RED,
			TempleTheme.SIZE_SMALL
		)
	)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("CLOSE", _close_panel))

#endregion


#region Output

func _set_busy(busy: bool) -> void:
	_busy = busy
	for button: Button in _action_buttons:
		if is_instance_valid(button):
			button.disabled = busy


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
