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
## bush on the left and the ark on the right. Panel handlers are named methods
## rather than inline lambdas, because GDScript cannot parse a multi-line
## lambda inside a call argument.
##
## Named so the suite can reach the column widths: a list whose rows outgrow
## their pane is a defect, and one worth a test rather than an eye.

class_name Main
extends Control

const CONFIG_PATH := "user://covenant.cfg"

## How long to leave between two transactions in the same ceremony, and how
## many times to ask whether what one wrote has appeared.
##
## Sealing a covenant is now four or five writes in a row, and a chain will not
## take them all at once: the next one is built against a state the last has not
## landed in yet, and it fails outright rather than queueing. Nothing in a
## ceremony is urgent — nobody is watching a clock that runs in months — so
## waiting costs nothing, and not waiting costs a half-made covenant.
##
## Eight tries at two and a half seconds is twenty seconds of patience per
## step, which covers a slow block without leaving the keeper staring at a
## screen that says nothing.
const SETTLE_SECONDS := 2.5
const SETTLE_TRIES := 8

## Column widths for the list. Monospaced, so padding is alignment.
##
## Kept narrow enough that a row never needs horizontal scrolling: the list is
## the thing you scan, and a scrollbar under it hides the far columns exactly
## when they matter. The release phrase used to sit at the end and ran to any
## length it liked, which is what pushed rows off the edge.
const W_STATE := 10
const W_TITLE := 44
const W_WHEN := 10

## The commons is a wider table than the ark: it carries a keeper as well.
const W_BROWSE_TITLE := 20
const W_BROWSE_KEEPER := 16
const W_BROWSE_WHEN := 12
const W_BROWSE_ACTION := 90

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
## Our wallet address per chain, e.g. {"sol": "Fid…", "mon": "0x8F…", "rh": "0x8F…"}.
##
## The addresses differ by chain, so a covenant is ours only when it matches
## the one for its own chain. Read from the host, never stored: it follows
## whichever keys GodOnChain is currently holding.
var _my_wallets: Dictionary = {}
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
var _seal_timelock_unit: OptionButton

var _open_fragments: TextEdit
var _open_result: Label
var _solving_timelock := false
## The window watching the climb, while there is one. A solve runs for hours or
## days, so it gets somewhere of its own to report from rather than a line on a
## panel the reader has to keep open.
var _solver: SolverWindow = null
## Polls for a host while unattached, so starting GodOnChain later just works.
var _host_watch: Timer
var _settings_fields: Dictionary = {}
## The records name, kept separately because it locks itself once set.
var _settings_root: LineEdit
var _root_warning: Label
## What the last OPEN revealed, held only so COPY has something to copy.
var _opened_text: TextEdit
var _opened_path: String = ""


func _ready() -> void:
	theme = TempleTheme.build()
	_load_config()
	_build_ui()

	iq = IQClient.new()
	add_child(iq)

	covenant = Covenant.new(iq)
	# The root is passed in so the ark can settle covenants saved before they
	# recorded who sealed them.
	ark = Ark.new(iq, str(config.get("db_root_id", "")))

	_rebuild_list()
	await _connect()


#region Connection

## Attaches to the host. `quiet` suppresses the chatter for the background
## retry, which would otherwise fill the console with the same two lines.
func _connect(quiet: bool = false) -> void:
	if not quiet:
		_say("Seeking the mountain...", TempleTheme.GREY)

	# Say who we are. Launched from GodOnChain this is ignored, because it named
	# us already — but running alongside it we would otherwise share one
	# anonymous token with every other such app, and every prompt would ask the
	# keeper to approve a spend for something it could not name.
	if not await iq.discover("Burning Bush Protocol"):
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

	# A host that goes away later has to be noticed. GodOnChain issues a fresh
	# port and token every time it starts, so an attachment never survives a
	# restart of it — and without this the app simply went quiet until it was
	# itself restarted, which reads as losing the connection for good.
	if not iq.host_missing.is_connected(_on_host_lost):
		iq.host_missing.connect(_on_host_lost)

	var who := iq.app_label if not iq.app_label.is_empty() else "an unnamed vessel"
	_say("Attached to the host as %s." % who, TempleTheme.CYAN)

	# Which wallet is paying decides which covenants are ours to tend.
	var wallets: Dictionary = await iq.wallet_info()
	_my_wallets = {}
	for chain: Variant in wallets.keys():
		var entry: Variant = wallets[chain]
		if entry is Dictionary and not (entry as Dictionary).has("error"):
			_my_wallets[str(chain)] = str((entry as Dictionary).get("address", ""))

	_my_identity = await iq.crypto_identity()
	if _my_identity.is_empty():
		_say(
			"This wallet has no encryption identity, so shares cannot be "
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

	var dark := await ark.refresh(Callable(), _repaint_row)
	# One regrouping at the end. The rows have been answering one by one as they
	# came in; this is where the dark ones move to the top.
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


## The host stopped answering mid-session — most often GodOnChain was
## restarted, which issues a new port and a new token. Start looking again
## rather than leaving the user to work out that nothing is responding.
func _on_host_lost(reason: String) -> void:
	if _host_watch != null:
		return
	_say("Lost GodOnChain: %s Looking for it again..." % reason, TempleTheme.AMBER)
	_paint_state(Flame.State.UNKNOWN)
	_rebuild_actions()
	_start_watching_for_host()


func _retry_connect() -> void:
	if iq == null or iq.is_available():
		_stop_watching_for_host()
		return
	await _connect(true)
	if iq.is_available():
		_say("GodOnChain is up. Attached.", TempleTheme.CYAN)

#endregion


#region The Ark list

## Repaints one row where it stands, without rebuilding the list.
##
## Reading a flame is a round trip each, so a keeper with a dozen covenants used
## to watch a column of UNKNOWN for several seconds and then have every answer
## arrive at once. Now each lands as it comes.
##
## In place, deliberately: a full rebuild would regroup dark-first on every
## answer, and rows that jump while a list is being read are worse than rows
## that fill in. The regrouping happens once, when the reading is done.
func _repaint_row(tablet: Tablet) -> void:
	if list_box == null:
		return

	var state := ark.state_of(tablet)
	for child: Node in list_box.get_children():
		if child.is_queued_for_deletion() or not child is Button:
			continue
		var row: Button = child
		if str(row.get_meta("tablet_id", "")) != tablet.id:
			continue
		row.text = _row_text(tablet, state)
		row.add_theme_color_override("font_color", _state_colour(state))
		break

	# The bush is showing this one, so it should light with it rather than wait
	# for the rest of the ark to answer.
	if tablet.id == selected_id:
		_paint_selected()


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

	# The columns are a table, so say what they are. Same widths as _row_text.
	list_box.add_child(
		_heading(
			"   %s %s %s %s %s %s"
			% [
				"FLAME".rpad(W_STATE),
				"TENDED".rpad(W_WHEN),
				"OVERDUE".rpad(W_WHEN),
				"RELEASES".rpad(W_WHEN),
				"CHAIN".rpad(4),
				"COVENANT",
			],
			TempleTheme.MUTED
		)
	)

	# Dark first, always. It is the only row anyone opened the app to see.
	if not dark.is_empty():
		list_box.add_child(_heading("— THE FLAME HAS GONE OUT —", TempleTheme.BRIGHT_RED))
		for tablet: Tablet in dark:
			list_box.add_child(_row(tablet))

	if not living.is_empty():
		list_box.add_child(_heading("— KEPT —", TempleTheme.AMBER))
		for tablet: Tablet in living:
			list_box.add_child(_row(tablet))

	# A bare asterisk explains nothing, so only mention it when one is showing.
	var starred := false
	for tablet: Tablet in ark.tablets:
		if not _my_identity.is_empty():
			if not Testimony.new(iq, tablet).my_envelope(_my_identity).is_empty():
				starred = true
				break
	if starred:
		list_box.add_child(
			_heading("  * a share of this one is addressed to your wallet", TempleTheme.CYAN)
		)

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
	# A long title must shorten the row, never widen the list past its pane.
	button.clip_text = true

	# A leading ">" was the only sign a row was selected, which is easy to miss
	# in a column of monospaced text and impossible to see at a glance.
	if tablet.id == selected_id:
		var picked := StyleBoxFlat.new()
		picked.bg_color = Color("1E1E14")
		picked.border_color = TempleTheme.YELLOW
		picked.set_border_width_all(1)
		picked.set_content_margin_all(4)
		for slot: String in ["normal", "hover", "pressed", "focus"]:
			button.add_theme_stylebox_override(slot, picked)

	button.pressed.connect(_select.bind(tablet.id))
	button.set_meta("tablet_id", tablet.id)
	return button


func _row_text(tablet: Tablet, state: Flame.State) -> String:
	var days := ark.days_since(tablet)
	# Always one character wide: an unpadded marker shifted every column to the
	# right on starred rows and broke the table.
	var mine := " "
	if not _my_identity.is_empty():
		var testimony := Testimony.new(iq, tablet)
		if not testimony.my_envelope(_my_identity).is_empty():
			mine = "*"

	# The three moments a keeper actually needs: when they last proved they were
	# here, when being late starts, and when it releases. Worked out in seconds
	# rather than whole days so the last hours before a release read as hours —
	# "in 0d" was the least useful thing the row could have said at exactly the
	# moment it mattered most.
	var tended := "never"
	var grace := "—"
	var dark := "—"
	var last := ark.last_tended(tablet)
	if last > 0:
		var elapsed := int(Time.get_unix_time_from_system()) - last
		tended = Tablet.since_time(elapsed)
		grace = Tablet.in_time(tablet.interval_days * 86400 - elapsed)
		dark = Tablet.in_time(tablet.days_until_dark() * 86400 - elapsed)
	elif days >= 0:
		# Read from an older status that carried only whole days.
		tended = Tablet.since_time(days * 86400)
		grace = Tablet.in_time((tablet.interval_days - days) * 86400)
		dark = Tablet.in_time((tablet.days_until_dark() - days) * 86400)
	elif state == Flame.State.UNKNOWN:
		tended = "—"

	# The name goes last: it is the one column with no natural width, and any
	# variable-width field in the middle pushes everything after it out of line.
	return "%s%s %s %s %s %s %s %s" % [
		">" if tablet.id == selected_id else " ",
		mine,
		Flame.state_name(state).rpad(W_STATE),
		tended.rpad(W_WHEN),
		grace.rpad(W_WHEN),
		dark.rpad(W_WHEN),
		tablet.chain.to_upper().rpad(4),
		tablet.title.substr(0, W_TITLE),
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


## Back to the whole ark. Clicking the selected row again does the same, but
## that is not discoverable, and nothing else on screen said so.
## Our wallet on one chain, or "" if the host has no key for it.
func _wallet_for(chain: String) -> String:
	return str(_my_wallets.get(chain.strip_edges().to_lower(), ""))


func _deselect() -> void:
	selected_id = ""
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

	# Belt and braces: the button is not offered, but tending is a claim to be
	# alive, and a covenant must never carry one made by anyone but its keeper.
	if not tablet.is_kept_by(_wallet_for(tablet.chain)):
		_say(
			"'%s' is not yours to tend. Only its keeper can say they are still "
			% tablet.title
			+ "here, and its flame is kept under their records, not yours.",
			TempleTheme.AMBER
		)
		return

	_set_busy(true)
	await _tend_tablet(tablet)
	_rebuild_list()
	_set_busy(false)


## A pause between two things the chain has to do in order.
func _pause(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Waits for a table that was just created to actually be there.
##
## A completed job means the host finished its work, not that the chain has
## caught up: the transaction still has to confirm, and the node answering the
## next question still has to have seen it. Asking once and taking "no" for an
## answer reports a perfectly good table as a reverted transaction — and
## writing the first row into that same gap is the transaction error that
## sealing, preparing and checking in back to back used to produce.
func _await_table(flame: Flame, title: String) -> bool:
	for attempt in SETTLE_TRIES:
		if await flame.exists_on_chain():
			return true
		if attempt == 0:
			_say("  Waiting for the chain to catch up with '%s'." % title, TempleTheme.GREY)
		if attempt < SETTLE_TRIES - 1:
			await _pause(SETTLE_SECONDS)
	return false


## Writes one proof-of-life row for this tablet and reads it back. Returns
## whether the row was written, which is what actually lights the flame — the
## chain may take a further moment to show it.
##
## Split out from the button because sealing checks in the moment the altar
## stands: a covenant whose flame has never been lit reads as UNLIT to every
## witness, and leaving that to a second press left new covenants keeping
## nothing while their keeper believed otherwise.
##
## `retries` is for the check-in that follows straight on from building the
## altar, which can be refused for no better reason than arriving too soon
## behind the transaction that created the table it writes to.
func _tend_tablet(tablet: Tablet, retries: int = 0) -> bool:
	var flame := ark.flame_for(tablet)

	# Writing a row to a table that does not exist reverts, which on an EVM
	# chain costs real money and achieves nothing. Look first.
	#
	# When this follows straight on from building the altar — which is what a
	# retry means here — the table may still be on its way, so wait for it
	# rather than announce it missing to a keeper who just paid for it.
	var there := false
	if retries > 0:
		there = await _await_table(flame, tablet.title)
	else:
		there = await flame.exists_on_chain()
	if not there:
		_say(
			"'%s' has no flame table on %s yet, so there is nothing to write to. "
			% [tablet.title, tablet.chain.to_upper()]
			+ "Press PREPARE first.",
			TempleTheme.BRIGHT_RED
		)
		return false

	var result = await flame.tend("", _writing("Checking in"))
	if result == null:
		if retries > 0:
			_say(
				"That did not go through: %s. Waiting for the chain, then "
				% flame.last_error
				+ "trying once more.",
				TempleTheme.AMBER
			)
			await _pause(SETTLE_SECONDS * 2.0)
			return await _tend_tablet(tablet, retries - 1)
		_say(flame.last_error, TempleTheme.BRIGHT_RED)
		return false

	# Right after a check-in, so verify it the same way a refresh would — and
	# patiently, because a row is not readable the instant its transaction
	# lands. Reads cost nothing, so waiting here costs only time.
	var author := await ark.author_of(tablet)
	for attempt in SETTLE_TRIES:
		ark.states[tablet.id] = await flame.read_status(5, Callable(), author)
		if ark.state_of(tablet) != Flame.State.NEVER_LIT:
			_say("The flame of '%s' is tended." % tablet.title, TempleTheme.CYAN)
			return true
		if attempt == 0:
			_say("  Written. Waiting for the chain to show it.", TempleTheme.GREY)
		if attempt < SETTLE_TRIES - 1:
			await _pause(SETTLE_SECONDS)

	# The row is written and paid for; only the reading back is behind.
	_say(
		"The check-in is written, but the chain has not shown it back yet. "
		+ "Press REFRESH in a minute.",
		TempleTheme.AMBER
	)
	return true


func _on_kindle() -> void:
	var tablet := selected()
	if tablet == null:
		_say("Choose a covenant whose altar you want built.", TempleTheme.YELLOW)
		return

	# Building an altar creates tables under the covenant's own root. Under
	# someone else's root the chain refuses it on Solana and merely takes the
	# money on the EVM chains, so refuse it here, where refusing is free.
	if not tablet.is_kept_by(_wallet_for(tablet.chain)):
		_say(
			"'%s' is not yours to prepare. Its records live under its keeper's "
			% tablet.title
			+ "root, which only their wallet can build on.",
			TempleTheme.AMBER
		)
		return

	_set_busy(true)
	# The button is now a retry for a covenant that did not finish being made,
	# so it carries on into the first check-in the same way sealing does —
	# unless the flame is already alight, in which case there is nothing owed.
	var standing := await _prepare_tablet(tablet)
	if standing and ark.state_of(tablet) != Flame.State.BURNING:
		# Same as sealing: let the altar land before writing the first row to it.
		await _pause(SETTLE_SECONDS)
		await _tend_tablet(tablet, 1)
	await _refresh()
	_set_busy(false)


## What it costs to make a covenant ready to keep: the tables it needs, the
## rows that list it, and the first check-in.
##
## Priced per call, because the table creations are the expensive part and the
## rows are small and cheap. Returns {tables, rows, total}.
func _prepare_cost(chain: String, witnesses: bool, listing: bool) -> Dictionary:
	var tables := 1
	if witnesses:
		tables += 1
	if listing:
		# The registry table, which only the first covenant on a chain pays for.
		tables += 1
	var rows := 1 if listing else 0
	return {
		"tables": tables,
		"rows": rows,
		# One row beyond the listing: lighting the flame.
		"total": Costs.create_table(chain) * tables + Costs.write_row(chain) * (rows + 1),
	}


## Creates everything a covenant needs on-chain: its flame table, the place its
## witnesses will testify, and its listing. Returns whether the altar stands.
##
## Safe to run twice, which is what makes PREPARE a usable retry. Pass `list`
## false when the caller has just published the listings itself — sealing has —
## so the same row is not written, and charged for, twice.
func _prepare_tablet(tablet: Tablet, list: bool = true) -> bool:
	# Preparing is several writes, and off Solana that is real money. Say so
	# before starting rather than after the third approval prompt.
	var cost := _prepare_cost(tablet.chain, tablet.has(Tablet.Release.WITNESSES), list)
	_say(
		"Preparing '%s': %d table(s) and %d row(s) including the first check-in, about %s in total."
		% [
			tablet.title,
			int(cost["tables"]),
			int(cost["rows"]) + 1,
			Costs.format(tablet.chain, float(cost["total"])),
		],
		TempleTheme.AMBER
	)

	var flame := ark.flame_for(tablet)
	# The keeper's wallet becomes the flame table's only permitted writer, so
	# the chain refuses a check-in from anyone else rather than this app merely
	# declining to offer one.
	var keeper_wallet := tablet.keeper_wallet
	if keeper_wallet.is_empty():
		keeper_wallet = _wallet_for(tablet.chain)

	# Ask before building. Creating a table that is already there is a
	# transaction that fails, so a retry after a ceremony that stopped half way
	# would otherwise pay for the half that worked and report an error for it.
	var standing := await flame.exists_on_chain()
	if standing:
		_say("The altar of '%s' already stands." % tablet.title, TempleTheme.CYAN)
	elif await flame.kindle(keeper_wallet, _writing("Creating the flame table")) == null:
		# Keep going: the remaining steps are independent, and abandoning them
		# here is what left covenants sealed but unlisted.
		_say("Could not build the altar: %s" % flame.last_error, TempleTheme.BRIGHT_RED)
	elif not await _await_table(flame, tablet.title):
		# The job finished and the chain still does not have it, twenty seconds
		# on. Either it was reverted or the chain is having a bad day, and this
		# cannot tell which — so it says both, and says that trying again is
		# safe, because the check above will not build a second one.
		_say(
			"The write completed but no table has appeared on %s. Either the "
			% tablet.chain.to_upper()
			+ "transaction was reverted — funds spent, nothing created — or the "
			+ "chain is only slow today. Check the signer's balance, then press "
			+ "PREPARE again: it will not build a second altar if the first arrives.",
			TempleTheme.BRIGHT_RED
		)
	else:
		standing = true
		_say("The altar stands, and the chain confirms it.", TempleTheme.CYAN)

	# Witnesses need somewhere to testify, and it must exist long before it is
	# needed — by then the keeper is not around to build it.
	if tablet.has(Tablet.Release.WITNESSES):
		var testimony := Testimony.new(iq, tablet)
		if await testimony.stands():
			_say("The place of testimony already stands.", TempleTheme.CYAN)
		else:
			# One transaction at a time: the altar has only just landed.
			await _pause(SETTLE_SECONDS)
			_say("Preparing the place of testimony.", TempleTheme.YELLOW)
			if await testimony.prepare() == null:
				_say(testimony.last_error, TempleTheme.BRIGHT_RED)
			else:
				_say("It stands ready.", TempleTheme.CYAN)

	# Retry anything that did not get listed when it was sealed.
	if list:
		await _pause(SETTLE_SECONDS)
		await _publish_listings(tablet)

	return standing


## Makes a covenant findable: under its keeper's own root always, and in the
## shared commons when that was asked for.
##
## Separate from building the flame, and safe to run twice — a covenant listed
## twice is still one covenant, and being unlisted is the failure that actually
## matters to a witness.
func _publish_listings(tablet: Tablet) -> void:
	if tablet.signature.is_empty():
		return

	# One registry now, under the protocol's own root. A listing used to be
	# written twice — once under the keeper's own root, once into a shared
	# commons — which under a single root is the same row written to the same
	# table twice, and charged for twice.
	var handle := str(config.get("db_root_id", "")).strip_edges()
	var registry := Registry.new(iq, tablet.chain)

	# Only the first covenant on a chain creates the registry. Every one after
	# it was paying for a transaction that could only fail, because the table it
	# asks for is already there — and that failure arrived, confusingly, in the
	# middle of an otherwise successful sealing.
	if not await registry.stands():
		await registry.prepare()
		# The listing row goes into the table that was just created, so give the
		# chain the same beat it gets everywhere else in the ceremony.
		await _pause(SETTLE_SECONDS)

	if await registry.publish(tablet, handle) == null:
		_say(
			"Not listed: %s. Witnesses would need the signature by hand — "
			% registry.last_error
			+ "press PREPARE to try again.",
			TempleTheme.AMBER
		)
		return

	if handle.is_empty():
		_say("Listed, where anyone browsing can find it.", TempleTheme.CYAN)
	else:
		_say(
			"Listed under '%s', where your witnesses can find it by that name." % handle,
			TempleTheme.CYAN
		)


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
		var row_empty := _button_row(box)
		row_empty.add_child(TempleTheme.button("CANCEL", _close_panel))
		return

	box.add_child(
		TempleTheme.line(
			"Give this to anyone naming you a witness. It is a public key: it "
			+ "is derived from your wallet, is the same on every machine you "
			+ "sign with, and there is nothing to store or lose. Handing it "
			+ "out lets a keeper address a share to you that only you can open.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)
	var field := LineEdit.new()
	field.text = _my_identity
	field.editable = false
	box.add_child(field)

	# The question a witness actually arrives with is "what am I holding?",
	# which an identity string alone never answered.
	box.add_child(HSeparator.new())
	box.add_child(
		TempleTheme.line("WHAT IS ADDRESSED TO YOU", TempleTheme.YELLOW, TempleTheme.SIZE_SMALL)
	)

	var mine: Array = []
	for tablet: Tablet in ark.tablets:
		if not Testimony.new(iq, tablet).my_envelope(_my_identity).is_empty():
			mine.append(tablet)

	if mine.is_empty():
		box.add_child(
			TempleTheme.line(
				"Nothing in your ark names you. A covenant only reaches you "
				+ "once its keeper seals you in as a witness and you add it "
				+ "here by its signature.",
				TempleTheme.GREY,
				TempleTheme.SIZE_SMALL
			)
		)
	else:
		for tablet: Tablet in mine:
			var state := ark.state_of(tablet)
			box.add_child(
				TempleTheme.line(
					"  %s — %s%s"
					% [
						tablet.title,
						Flame.state_name(state),
						(
							"" if tablet.threshold <= 1
							else "  (needs %d of %d)" % [tablet.threshold, tablet.witness_count]
						),
					],
					TempleTheme.CYAN if Flame.releasable(state) else TempleTheme.GREY,
					TempleTheme.SIZE_SMALL
				)
			)
		box.add_child(
			TempleTheme.line(
				"Open one from the list to read it with your own wallet. "
				+ "TESTIFY is different: it publishes your share, which "
				+ "releases the covenant to everyone, permanently.",
				TempleTheme.AMBER,
				TempleTheme.SIZE_SMALL
			)
		)

	var row := _button_row(box)
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
		_say("No share on this tablet is addressed to you.", TempleTheme.AMBER)
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
	_say("Opening the share addressed to you...", TempleTheme.YELLOW)

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
			"You have testified. %d share(s) are needed in all." % tablet.threshold,
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
	# Off by default: naming witnesses means collecting identity keys from real
	# people first, which is a lot to ask of a first covenant. The puzzle below
	# needs nobody, so it is what a new covenant starts with.
	_seal_use_witnesses.button_pressed = false
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
	# The default route: it depends on nobody, needs nothing collected in
	# advance, and still cannot be opened before the flame goes out.
	_seal_use_timelock.button_pressed = true
	_seal_use_timelock.toggled.connect(_on_mode_toggled.bind("guarded"))
	box.add_child(_seal_use_timelock)

	_timelock_panel = HBoxContainer.new()
	_timelock_panel.add_theme_constant_override("separation", 8)
	_timelock_panel.add_child(_plain("        Taking about"))
	_seal_timelock_days = SpinBox.new()
	_seal_timelock_days.min_value = 1
	_seal_timelock_days.max_value = 3650
	# A day is long enough to be a real barrier and short enough that a keeper
	# can watch one actually resolve before trusting the mechanism with a year.
	_seal_timelock_days.value = 1
	_seal_timelock_days.value_changed.connect(_on_counts_changed)
	_timelock_panel.add_child(_seal_timelock_days)

	# Days only was too coarse to try the feature out: calibrating a puzzle is
	# the one thing you want to test at a few minutes before trusting it with
	# a year.
	_seal_timelock_unit = OptionButton.new()
	for i in Tablet.DURATION_UNITS.size():
		_seal_timelock_unit.add_item(str(Tablet.DURATION_UNITS[i][0]), i)
	_seal_timelock_unit.select(Tablet.DURATION_DEFAULT_UNIT)
	_seal_timelock_unit.item_selected.connect(_on_counts_changed)
	_timelock_panel.add_child(_seal_timelock_unit)
	_timelock_panel.add_child(_plain("of computing"))
	box.add_child(_timelock_panel)

	# 3. Terms. Per covenant, not per app: one may live on Solana and be checked
	#    weekly, another on Robinhood Chain and be checked once a year.
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
	# On by default: a covenant nobody can find is one nobody can act on when
	# the flame goes out, and listing never makes anything readable — the
	# tablet was already public and permanent the moment it was inscribed.
	_seal_list_publicly.button_pressed = true
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
				"%d share(s) have no identity key — you deliver those by hand, "
				% (witnesses.size() - wrapped)
				+ "shown once and never stored."
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
	# SEAL IT does the whole ceremony — inscribe, prepare, first check-in — so
	# quote the whole ceremony. Quoting only the inscription would leave the
	# keeper meeting the larger half of the bill unannounced.
	var seal_cost := Costs.for_bytes(sealing_chain, bytes)
	# Every covenant is listed so its witnesses can find it, whether or not it
	# is offered to strangers browsing, so the listing is always in the price.
	var ready_cost: Dictionary = _prepare_cost(
		sealing_chain, _seal_use_witnesses.button_pressed, true
	)
	lines.append(
		"Sealing this costs about %s. It is then prepared and checked in "
		% Costs.format(sealing_chain, seal_cost)
		+ "straight away — several transactions, one at a time, so give it a "
		+ "minute — for about %s in all."
		% Costs.format(sealing_chain, seal_cost + float(ready_cost["total"]))
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
	# Every table this protocol creates sits under one root, so the creation
	# fees go to the protocol rather than each keeper paying themselves. The
	# keeper's own name is now a handle in the registry, not a root.
	tablet.db_root_id = Tablet.APP_ROOT
	# Each covenant keeps its own chain and clock.
	tablet.chain = str(CHAINS[maxi(_seal_chain.selected, 0)][1])
	# Inscribed with the covenant: the wallet that seals it is the only one that
	# may ever tend it, and a reader needs to know which that is to tell a
	# genuine check-in from a stranger's.
	tablet.keeper_wallet = _wallet_for(tablet.chain)
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
		_say("Building the puzzle. This is quick for you and slow for everyone else.", TempleTheme.YELLOW)
		var puzzle := await iq.timelock_create(key.hex_encode(), _timelock_seconds())
		if puzzle.is_empty():
			_say("Could not build the time lock: %s" % iq.last_error, TempleTheme.BRIGHT_RED)
			_set_busy(false)
			return
		tablet.timelock = puzzle
		_say(
			"Sealed behind roughly %s of computing (%s squarings)."
			% [tablet.timelock_duration(), str(puzzle.get("t", "?"))],
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
			# Splitting into one-of-n is not a threshold scheme. The marker on it
			# is what tells the opening side not to hand this to Shamir, which
			# would refuse it and leave the covenant shut for ever.
			for i in witnesses:
				fragments.append(Covenant.whole_key(key))
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
					"Could not wrap the share for %s: %s"
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
	# We sealed it, so we are the one who can honestly tend its flame. Both are
	# set: the wallet is the authority, mine is what an older build reads.
	tablet.mine = true
	ark.add(tablet)
	selected_id = tablet.id

	_say("The tablet is inscribed: %s" % str(signature), TempleTheme.CYAN)

	# One transaction at a time from here on. The inscription has only just
	# been submitted, and the listing that follows is built against a chain
	# state that has to include it.
	await _pause(SETTLE_SECONDS)
	await _publish_listings(tablet)
	if not tablet.witness_envelopes.is_empty():
		_say(
			"%d share(s) travelled with it, wrapped so only their witness can "
			% tablet.witness_envelopes.size()
			+ "open them. Those witnesses need nothing but the signature.",
			TempleTheme.CYAN
		)
	# A sealed covenant that was never prepared keeps nothing: its flame has no
	# table to burn in, so it reads as UNLIT to every witness and its clock has
	# not started. Nobody wants a half-made covenant, so the rest of the
	# ceremony follows straight on from the seal rather than waiting on two
	# more presses. The listings are already done above, so they are neither
	# rewritten nor charged for twice.
	_say("Making it ready to keep.", TempleTheme.YELLOW)
	await _pause(SETTLE_SECONDS)
	var lit := false
	if await _prepare_tablet(tablet, false):
		# The altar has just landed and this writes to it, which is the one
		# place in the ceremony most likely to arrive too soon — so it is the
		# one step allowed a second attempt.
		await _pause(SETTLE_SECONDS)
		lit = await _tend_tablet(tablet, 1)

	if lit and ark.state_of(tablet) == Flame.State.BURNING:
		_say(
			"'%s' is sealed, prepared and burning. Check in again within %d days."
			% [tablet.title, tablet.interval_days],
			TempleTheme.CYAN
		)
	elif lit:
		# Written and paid for, and the chain is merely behind. Saying it is
		# unfinished here would send the keeper to pay for it a second time.
		_say(
			"'%s' is sealed, prepared and checked in. The chain has not shown "
			% tablet.title
			+ "the check-in back yet — press REFRESH in a minute to see it.",
			TempleTheme.AMBER
		)
	else:
		# The tablet is inscribed and permanent either way — only the records
		# around it are missing, and PREPARE finishes exactly those.
		_say(
			"'%s' is inscribed, but its records are not finished. It is not "
			% tablet.title
			+ "keeping anything until they are: press PREPARE to try again.",
			TempleTheme.BRIGHT_RED
		)
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

	box.add_child(TempleTheme.title("— SHARES TO DELIVER BY HAND —", TempleTheme.YELLOW))
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
	_say("Shares copied. Distribute them now.", TempleTheme.YELLOW)


func _fragments_done() -> void:
	_close_panel()
	_say("The shares are forgotten by this machine.", TempleTheme.GREY)

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
	# A covenant whose flame still burns cannot be opened by anyone, so there is
	# nothing worth showing. Laying out the routes and then disabling the
	# buttons invited the attempt and made the refusal look like a fault.
	if not releasable:
		var status: Dictionary = ark.states.get(tablet.id, {})
		var left := maxi(int(status.get("days_left", 0)), 0)
		var why := (
			"Its flame has not been read yet, so there is nothing to act on."
			if state == Flame.State.UNKNOWN or state == Flame.State.NEVER_LIT
			else (
				"Its keeper is overdue but not gone — %d day(s) of grace " % left
				+ "remain, and that wait is the whole point of a grace period."
			)
		)
		box.add_child(
			TempleTheme.line(
				"'%s' is not released. " % tablet.title + why,
				TempleTheme.AMBER,
				TempleTheme.SIZE_SMALL
			)
		)
		var refused := _button_row(box)
		refused.add_child(TempleTheme.button("CLOSE", _close_panel))
		return

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
	var addressed_to_me := false

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
				"WITNESSES — %d OF %d NEEDED" % [tablet.threshold, tablet.witness_count],
				TempleTheme.YELLOW,
				TempleTheme.SIZE_SMALL
			)
		)

		# Reading the tablet we already hold; no network, no cost.
		addressed_to_me = not Testimony.new(iq, tablet).my_envelope(_my_identity).is_empty()

		if addressed_to_me:
			box.add_child(
				TempleTheme.line(
					(
						"You are one of them. Your share rode inside the tablet, "
						+ "wrapped so that only your wallet opens it — there is "
						+ "nothing for you to find, and nobody to ask. "
						+ (
							"Press OPEN and it opens here, privately."
							if tablet.threshold <= 1
							else (
								"It takes %d shares in all, so yours alone is not "
								% tablet.threshold
								+ "enough; OPEN counts it against any others "
								+ "already testified."
							)
						)
					),
					TempleTheme.CYAN,
					TempleTheme.SIZE_SMALL
				)
			)
		else:
			box.add_child(
				TempleTheme.line(
					"A share is one piece of the key. This tablet holds none "
					+ "addressed to your wallet, so opening it means collecting "
					+ "shares from the witnesses it does name. Any they have "
					+ "already testified on-chain are counted for you.",
					TempleTheme.GREY,
					TempleTheme.SIZE_SMALL
				)
			)

	if tablet.has(Tablet.Release.TIME_LOCK):
		box.add_child(TempleTheme.line("THE PUZZLE", TempleTheme.YELLOW, TempleTheme.SIZE_SMALL))
		box.add_child(
			TempleTheme.line(
				(
					"This route asks nothing of anyone. Your own machine grinds out a "
					+ "sum that takes about %s, and the answer is the key. It cannot be "
					+ "hurried, split across machines, or paused. It runs in a window of "
					+ "its own that you can push aside and leave to it — but Burning Bush "
					+ "has to stay open, because closing it starts the climb over."
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
			row.add_child(
				TempleTheme.button(
					"OPEN" if addressed_to_me else "OPEN WITH SHARES", _open_confirmed
				)
			)
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
		_result(
			"Solving. This will take about %s and cannot be hurried."
			% tablet.timelock_duration(),
			TempleTheme.YELLOW
		)
		_say(
			"Solving the puzzle of '%s'. Watch it in its own window."
			% tablet.title,
			TempleTheme.YELLOW
		)
		_solver = SolverWindow.open_beside(self, tablet.title, tablet.timelock_duration())
		var secret := await iq.timelock_solve(puzzle, _on_solve_progress)
		_solving_timelock = false
		if secret.is_empty():
			var refusal := _solve_refusal()
			_end_solver(refusal)
			_result(refusal, TempleTheme.BRIGHT_RED)
			_say(refusal, TempleTheme.BRIGHT_RED)
			return
		_end_solver("")
		key = Covenant.hex_to_bytes(secret)
	else:
		if not tablet.has(Tablet.Release.WITNESSES):
			_result(
				"No witnesses hold this one. Use SOLVE THE PUZZLE.", TempleTheme.YELLOW
			)
			return
		var testimony := Testimony.new(iq, tablet)
		var fragments: Array[PackedByteArray] = []
		var seen := {}

		# The share addressed to us opens with our own wallet and never has to
		# be published. When the keeper set the threshold to one, that alone is
		# the whole key: the covenant opens here, privately, and nothing is
		# written to any chain. Testifying is a separate, public act.
		var mine: Dictionary = testimony.my_envelope(_my_identity)
		if not mine.is_empty():
			_result("Opening the share addressed to you...", TempleTheme.GREY)
			var mine_hex := await iq.decrypt_envelope(mine)
			if mine_hex.is_empty():
				_result(iq.last_error, TempleTheme.BRIGHT_RED)
				return
			var mine_share := Shamir.from_hex(mine_hex)
			if not mine_share.is_empty():
				fragments.append(mine_share)
				seen[mine_share[0]] = true

		# Only reach for what others published if our own share is not enough.
		if fragments.size() < tablet.threshold:
			_result("Gathering testimony...", TempleTheme.GREY)
			var gathered: Dictionary = await testimony.gather()
			for already: PackedByteArray in gathered.get("fragments", []):
				if seen.has(already[0]):
					continue
				seen[already[0]] = true
				fragments.append(already)
			var witnesses: Array = gathered.get("witnesses", [])
			if not witnesses.is_empty():
				var who := (
					"%d witness(es) have testified: %s"
					% [witnesses.size(), ", ".join(witnesses)]
				)
				# On the panel as well as in the log: the panel is covering the
				# log, so anything said only there is said to nobody.
				_result(who, TempleTheme.CYAN)
				_say(who, TempleTheme.CYAN)
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
				"This tablet needs %d shares. You have %d."
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
		# The console keeps a copy, but it sits behind this panel and cannot be
		# read while the panel is up — and the sealed word is the entire reason
		# anyone pressed OPEN. It belongs on the screen that opened it.
		_say("=== THE WORD OF '%s' ===" % tablet.title, TempleTheme.YELLOW)
		_say(text, TempleTheme.WHITE)
		_show_opened(tablet, text, "")


## What was sealed, shown where it was opened.
##
## Replaces the open panel rather than closing it. A covenant is usually opened
## once, and returning the reader to the list with the words only in a log they
## cannot see is how something irreplaceable gets lost.
func _show_opened(tablet: Tablet, text: String, saved_to: String) -> void:
	var box := _open_panel_box()
	box.add_child(
		TempleTheme.title("— THE WORD OF '%s' —" % tablet.title.to_upper(), TempleTheme.YELLOW)
	)

	_opened_text = null
	if saved_to.is_empty():
		_opened_text = TextEdit.new()
		_opened_text.text = text
		_opened_text.editable = false
		_opened_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		_opened_text.custom_minimum_size = Vector2(0, 320)
		box.add_child(_opened_text)
	else:
		box.add_child(
			TempleTheme.line(
				"This covenant held a file. It has been written to:",
				TempleTheme.GREY,
				TempleTheme.SIZE_SMALL
			)
		)
		var where := LineEdit.new()
		where.text = saved_to
		where.editable = false
		box.add_child(where)

	box.add_child(
		TempleTheme.line(
			"Nothing here can be resealed. If this covenant released publicly, "
			+ "everyone who can reach the chain can read it too.",
			TempleTheme.AMBER,
			TempleTheme.SIZE_SMALL
		)
	)

	var row := _button_row(box)
	row.add_child(TempleTheme.button("COPY", _copy_opened))
	row.add_child(TempleTheme.button("CLOSE", _close_panel))


func _copy_opened() -> void:
	# The panel owns the TextEdit, and closing it frees the node while this
	# reference survives. Ask whether it is still alive, not merely non-null.
	var what := (
		_opened_text.text
		if _opened_text != null and is_instance_valid(_opened_text)
		else _opened_path
	)
	if what.is_empty():
		return
	DisplayServer.clipboard_set(what)
	_say("Copied.", TempleTheme.YELLOW)


func _save_opened_file(tablet: Tablet, base64_data: String) -> void:
	var bytes := Marshalls.base64_to_raw(base64_data)
	if bytes.is_empty():
		_result("The tablet opened, but its contents are not a file.", TempleTheme.BRIGHT_RED)
		_say("The tablet opened, but its contents are not a file.", TempleTheme.BRIGHT_RED)
		return

	DirAccess.make_dir_recursive_absolute("user://opened")
	var name := tablet.filename if not tablet.filename.is_empty() else tablet.id
	var path := "user://opened/%s" % name
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_result("Could not write the file out.", TempleTheme.BRIGHT_RED)
		_say("Could not write the file out.", TempleTheme.BRIGHT_RED)
		return
	file.store_buffer(bytes)
	file.close()

	_opened_path = ProjectSettings.globalize_path(path)
	_say("=== THE WORD OF '%s' ===" % tablet.title, TempleTheme.YELLOW)
	_say("Written to %s" % _opened_path, TempleTheme.WHITE)
	_show_opened(tablet, "", _opened_path)


## Starts the long climb. Kept behind its own button so nobody begins days of
## computing by pressing the ordinary OPEN.
##
## It runs in a window of its own — one this app owns, beside the app rather
## than inside a panel — so it can be pushed aside while the reader gets on
## with something else, and so a display that changes once every quarter of an
## hour is not sitting on top of everything else the app has to say.
##
## The app has to stay open for it. That is the one thing the window says
## plainly, because a climb thrown away at 90% is a day nobody gets back.
func _solve_confirmed() -> void:
	var tablet := selected()
	if tablet == null:
		return
	# Belt and braces, the same as OPEN: nothing releases a covenant whose
	# keeper may simply be on holiday.
	if not Flame.releasable(ark.state_of(tablet)):
		_result("This covenant is not released yet.", TempleTheme.BRIGHT_RED)
		return

	# One climb at a time. The host solves one puzzle at a time and refuses a
	# second outright, and that refusal would arrive in a window the reader is
	# not looking at — so this doubles as the way back to a window that was
	# closed while its climb kept going.
	if _solver != null and is_instance_valid(_solver):
		_solver.show()
		_solver.call_deferred("move_to_center")
		_result("Already solving. Its window is on screen.", TempleTheme.YELLOW)
		return

	_solving_timelock = true
	await _open_confirmed()


func _on_solve_progress(percent: float) -> void:
	if _solver != null and is_instance_valid(_solver):
		_solver.report(percent)
	# Said in both places on purpose: the window can be closed, and the panel is
	# behind it. Whichever one the reader is looking at, it is current.
	_result(
		"Solving... %d%%. This cannot be hurried, and closing the app loses the progress."
		% int(percent),
		TempleTheme.YELLOW
	)


## Why the host would not start a climb, at more length than the host says it.
##
## One refusal deserves the explanation: a solve runs inside GodOnChain rather
## than in this app, and it keeps running after the window that started it is
## gone. So "a puzzle is already being solved" almost always means an earlier
## climb of your own is still going, hours or days after the app that began it
## was closed. It cannot be joined either — the host hands a finished puzzle to
## the first caller that asks for it, and this app no longer knows which job to
## ask about.
func _solve_refusal() -> String:
	if iq.last_code != 409:
		return iq.last_error
	return (
		"GodOnChain is already solving a puzzle, and it does one at a time. That "
		+ "is most likely a climb of your own from earlier: it runs inside "
		+ "GodOnChain, not in this app, so it carries on for hours after the "
		+ "window that started it is closed. This app cannot join it. Either wait "
		+ "for it to finish, or restart GodOnChain to abandon it — which frees the "
		+ "slot and starts this one again from nothing."
	)


## Closes the watching window. An empty reason means the puzzle opened, and the
## word is about to appear in the app — there is nothing left for a progress
## window to say. A reason means it stopped, and that stays on screen until it
## is dismissed, because an error that closes itself is one nobody read.
func _end_solver(reason: String) -> void:
	if _solver == null or not is_instance_valid(_solver):
		_solver = null
		return
	if reason.is_empty():
		_solver.solved()
	else:
		_solver.failed(reason)
	_solver = null


func _result(message: String, colour: Color) -> void:
	# The panel it lives on can be closed while a solve runs on for hours, which
	# is exactly what the separate window is for — so the label may be gone.
	if _open_result == null or not is_instance_valid(_open_result):
		return
	_open_result.add_theme_color_override("font_color", colour)
	_open_result.text = message

#endregion


#region Settings

## Chains the app can write to. The value is what the SDK expects; the label is
## what a person recognises.
## The chains a covenant may live on, as label and the code the host wants.
## A tablet records its own, and one on-chain cannot be moved, so this list
## only ever grows.
const CHAINS := [
	["SOL — Solana", "sol"],
	["MON — Monad", "mon"],
	["RH — Robinhood Chain", "rh"],
]

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

	# Renaming this after anything has been sealed strands every covenant filed
	# under the old name: witnesses look where they were told to look, and a
	# tablet on-chain cannot be moved. So it reads as text once set, and
	# unlocking it has to be asked for.
	var root_row := _labelled(box, "Name for your records")
	_settings_root = LineEdit.new()
	_settings_root.text = str(config.get("db_root_id", ""))
	_settings_root.placeholder_text = "like a username"
	_settings_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_root.editable = _settings_root.text.strip_edges().is_empty()
	root_row.add_child(_settings_root)

	if _settings_root.editable:
		root_row.add_child(TempleTheme.button("SUGGEST", _suggest_root))
	else:
		root_row.add_child(TempleTheme.button("COPY", _copy_root))
		root_row.add_child(TempleTheme.button("EDIT", _unlock_root))
	_settings_fields["db_root_id"] = _settings_root

	box.add_child(
		_hint("Witnesses need this to find what you sealed. Keep it somewhere they will look.")
	)

	_root_warning = _hint("")
	_root_warning.add_theme_color_override("font_color", TempleTheme.BRIGHT_RED)
	_root_warning.visible = false
	box.add_child(_root_warning)

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


## How long the puzzle should take, in seconds, from the count and its unit.
func _timelock_seconds() -> int:
	if _seal_timelock_days == null:
		return 86400
	var unit := Tablet.DURATION_DEFAULT_UNIT
	if _seal_timelock_unit != null and _seal_timelock_unit.selected >= 0:
		unit = _seal_timelock_unit.selected
	return maxi(1, int(_seal_timelock_days.value)) * int(Tablet.DURATION_UNITS[unit][1])


func _copy_root() -> void:
	if _settings_root == null:
		return
	DisplayServer.clipboard_set(_settings_root.text)
	_say("Records name copied.", TempleTheme.YELLOW)


## Unlocks the records name, having first said what changing it costs.
func _unlock_root() -> void:
	if _settings_root == null:
		return
	_settings_root.editable = true
	_settings_root.grab_focus()
	if _root_warning != null:
		_root_warning.text = (
			"Changing this does not move anything. Covenants already sealed "
			+ "stay filed under '%s' forever, and witnesses told to look "
			% str(config.get("db_root_id", ""))
			+ "there will keep finding only those. Change it only if nothing "
			+ "has been sealed yet."
		)
		_root_warning.visible = true


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

	# The bush and its readings sit in a fixed column on the left so the ark
	# gets the full height of the window on the right. Stacked vertically the
	# art took the space the list needed, and a keeper with a dozen covenants
	# scrolled a four-row window.
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 14)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(split)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.custom_minimum_size = Vector2(380, 0)
	left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	split.add_child(left)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)

	bush = BurningBush.new()
	# A RichTextLabel will happily take every pixel it is offered; the art is a
	# fixed number of rows, so give it exactly those and let the ark have the
	# rest of the height.
	bush.fit_content = true
	bush.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	left.add_child(bush)

	# Heard as well as seen: the same state drives both, so the room tells you
	# how the covenant is doing without being looked at.
	fire = FireSound.new()
	add_child(fire)
	fire.set_enabled(bool(config.get("ambience", true)))

	verse = TempleTheme.line("", TempleTheme.YELLOW)
	left.add_child(verse)

	gloss = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	left.add_child(gloss)

	readout = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	left.add_child(readout)

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
	left.add_child(sound_row)

	# The ark itself. Scrolls, because a keeper may hold a great many.
	var ark_panel := PanelContainer.new()
	ark_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	# Vertical only: the columns are sized to fit, and a horizontal bar here
	# hid the release dates behind a scroll exactly when they mattered.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 2)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)
	ark_panel.add_child(scroll)
	right.add_child(ark_panel)

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
	box.custom_minimum_size = Vector2(1040, 0)
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
	"prepare": ["PREPARE", "Finish making this covenant: its records on-chain and its first check-in. Sealing does this already — this is the retry."],
	"checkin": ["CHECK IN", "Prove you are still here. Do this before the deadline."],
	"open": ["OPEN", "Read what was sealed, if enough shares are available."],
	"publish": ["PUBLISH MY SHARE", "Releases it to everyone, permanently. To read it yourself instead, use OPEN."],
	"witness": ["I AM A WITNESS", "Your identity key to hand out, and what is currently addressed to you."],
	"browse": ["BROWSE", "See covenants people have listed publicly, and when they run out."],
	"deselect": ["← ALL COVENANTS", "Stop working on this one and go back to the whole ark."],
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

	# While one is selected the action bar is about that covenant, so the way
	# back to the app's own actions has to be on screen rather than guessed at.
	var common := ["deselect", "refresh", "remove", "help"]
	var status: Dictionary = ark.states.get(tablet.id, {})
	var left := int(status.get("days_left", 0))

	# Only the keeper can honestly say they are still here, and only their
	# wallet can write under their root. Offering these over someone else's
	# covenant proposes forging proof of life for a person who may be dead.
	var mine := tablet.is_kept_by(_wallet_for(tablet.chain))
	var tend: Array = ["checkin"] if mine else []
	var build: Array = ["prepare"] if mine else []

	match state:
		Flame.State.NEVER_LIT:
			return {
				"text": (
					"'%s' was never finished: it has no records on-chain, so it "
					% tablet.title
					+ "is keeping nothing and its clock has not started. Prepare it."
				),
				"primary": "prepare" if mine else "",
				"actions": build + tend + common,
			}
		Flame.State.BURNING:
			return {
				"text": (
					"'%s' is safe. Check in again within %d days."
					% [tablet.title, left]
					if mine
					else "'%s' is being kept. Its keeper checked in %d day(s) ago."
					% [tablet.title, maxi(ark.days_since(tablet), 0)]
				),
				"primary": "",
				"actions": tend + common,
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
					"actions": tend + common,
				}
			return {
				"text": (
					"'%s' is overdue. Check in within %d days or it releases."
					% [tablet.title, maxi(left, 0)]
				),
				"primary": "checkin" if mine else "",
				"actions": tend + common,
			}
		Flame.State.DARK:
			# Publishing releases a covenant to everyone, so it only leads when
			# it is genuinely needed: a lone witness whose share is the whole
			# key should read it privately instead, and a covenant with no
			# witnesses has nothing to publish at all.
			var can_publish := i_am_witness and tablet.threshold > 1
			var doors: Array = ["publish", "open"] if i_am_witness else ["open"]
			return {
				"text": _dark_text(tablet, i_am_witness),
				"primary": "publish" if can_publish else "open",
				"actions": doors + tend + common,
			}
		_:
			return {
				"text": "Could not read '%s'. This says nothing about its keeper." % tablet.title,
				"primary": "refresh",
				"actions": ["refresh"] + common,
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
		"deselect":
			return _deselect
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

	# Headers, so the columns are readable without being decoded. Padded to the
	# same widths the rows use, and outside the scroll so they stay put.
	box.add_child(
		_heading(
			"  %s %s %s %s"
			% [
				"FLAME".rpad(W_STATE),
				"DEADLINE".rpad(W_BROWSE_WHEN),
				"KEPT BY".rpad(W_BROWSE_KEEPER),
				"COVENANT",
			],
			TempleTheme.MUTED
		)
	)

	var listing := PanelContainer.new()
	listing.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_survey_box = VBoxContainer.new()
	_survey_box.add_theme_constant_override("separation", 2)
	_survey_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_survey_box)
	listing.add_child(scroll)
	box.add_child(listing)

	box.add_child(
		TempleTheme.line(
			"* a share of that one is addressed to your wallet.  "
			+ "WATCH adds it to your ark so its flame is read with the rest.",
			TempleTheme.MUTED,
			TempleTheme.SIZE_SMALL
		)
	)

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
			deadline = "RELEASED"
		Flame.State.NEVER_LIT:
			deadline = "not started"
		Flame.State.UNKNOWN:
			deadline = "unreadable"
		_:
			deadline = "%dd left" % maxi(left, 0)

	var who: String = tablet.keeper if not tablet.keeper.is_empty() else tablet.db_root_id

	# cell(), not line(): a padded layout has no spaces to wrap on, so squeezed
	# beside a button the old labels broke one character per line.
	row.add_child(
		TempleTheme.cell(
			"%s %s %s %s %s" % [
				"*" if bool(entry["i_am_witness"]) else " ",
				Flame.state_name(state).rpad(W_STATE),
				deadline.rpad(W_BROWSE_WHEN),
				who.substr(0, W_BROWSE_KEEPER).rpad(W_BROWSE_KEEPER),
				tablet.title.substr(0, W_BROWSE_TITLE),
			],
			_state_colour(state)
		)
	)

	# Always present, even when empty, so the column below it stays a column.
	# Built conditionally, the rows to either side of a released one shifted.
	var ways := TempleTheme.cell(
		_open_routes(tablet, bool(entry["i_am_witness"])) if state == Flame.State.DARK else "",
		TempleTheme.YELLOW
	)
	ways.custom_minimum_size = Vector2(190, 0)
	ways.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(ways)

	if bool(entry.get("already_held", false)):
		var held := TempleTheme.cell("watching", TempleTheme.MUTED)
		held.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		held.custom_minimum_size = Vector2(W_BROWSE_ACTION, 0)
		held.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(held)
	else:
		var watch := TempleTheme.button("WATCH", _watch_surveyed.bind(tablet))
		watch.custom_minimum_size = Vector2(W_BROWSE_ACTION, 0)
		row.add_child(watch)

	return row


## A short phrase saying how, if at all, the reader could open this one now.
static func _open_routes(tablet: Tablet, i_am_witness: bool) -> String:
	var ways: PackedStringArray = []
	if tablet.has(Tablet.Release.PUBLIC_BURN):
		ways.append("open to anyone")
	if tablet.has(Tablet.Release.WITNESSES):
		ways.append(
			"you hold a share" if i_am_witness else "needs %d witnesses" % tablet.threshold
		)
	# Was missing entirely, so a time-locked covenant showed a blank way in —
	# the one route that needs nobody looked like no route at all.
	if tablet.has(Tablet.Release.TIME_LOCK):
		ways.append("%s of computing" % tablet.timelock_duration())
	return " / ".join(ways)


## What to say about a covenant whose flame has gone out.
##
## Built from the release modes the tablet actually carries. One sentence about
## witnesses used to be shown to every reader however the covenant was sealed,
## so a public burn and a time lock both claimed to be waiting on shares that
## were never issued to anybody.
static func _dark_text(tablet: Tablet, i_am_witness: bool) -> String:
	var ways: PackedStringArray = []

	if tablet.has(Tablet.Release.PUBLIC_BURN):
		ways.append("its key rides in the tablet, so anyone can open it now")

	if tablet.has(Tablet.Release.WITNESSES):
		if i_am_witness and tablet.threshold <= 1:
			ways.append("your share alone opens it, and OPEN reads it here without publishing")
		elif i_am_witness:
			ways.append(
				"it takes %d of its %d witnesses, and you are one of them"
				% [tablet.threshold, tablet.witness_count]
			)
		else:
			ways.append(
				"it opens once %d of its %d witnesses publish their shares"
				% [tablet.threshold, tablet.witness_count]
			)

	if tablet.has(Tablet.Release.TIME_LOCK):
		ways.append(
			"anyone willing to spend about %s of computing can open it"
			% tablet.timelock_duration()
		)

	if ways.is_empty():
		return (
			"'%s' has gone dark, but no way to open it was ever set." % tablet.title
		)
	return "'%s' has gone dark: %s." % [tablet.title, " — or ".join(ways)]


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
			+ "with whether you hold a share.",
			TempleTheme.GREY,
			TempleTheme.SIZE_SMALL
		)
	)

	var look_row := HBoxContainer.new()
	look_row.add_theme_constant_override("separation", 8)
	_survey_root = LineEdit.new()
	_survey_root.placeholder_text = "their name for their records"
	_survey_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	look_row.add_child(_survey_root)
	look_row.add_child(TempleTheme.button("LOOK", _survey_confirmed))
	box.add_child(look_row)

	_survey_status = TempleTheme.line("", TempleTheme.GREY, TempleTheme.SIZE_SMALL)
	box.add_child(_survey_status)

	box.add_child(
		_heading(
			"  %s %s %s"
			% [
				"FLAME".rpad(W_STATE),
				"TENDED".rpad(W_BROWSE_WHEN),
				"COVENANT",
			],
			TempleTheme.MUTED
		)
	)

	_survey_box = VBoxContainer.new()
	_survey_box.add_theme_constant_override("separation", 2)
	_survey_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	var handle := _survey_root.text.strip_edges()
	if handle.is_empty():
		return

	for child in _survey_box.get_children():
		child.queue_free()
	_survey_status.add_theme_color_override("font_color", TempleTheme.GREY)
	_survey_status.text = "Looking under '%s'..." % handle

	var found := await ark.survey(handle, str(config["chain"]), _my_identity)
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
	# cell(), not line(): a padded column layout has no spaces to break on, so
	# word-wrap in a narrow row degrades into one character per line.
	row.add_child(
		TempleTheme.cell(
			"%s %s %s %s" % [
				"*" if bool(entry["i_am_witness"]) else " ",
				Flame.state_name(state).rpad(W_STATE),
				Tablet.since_time(days * 86400 if days >= 0 else -1).rpad(W_BROWSE_WHEN),
				tablet.title.substr(0, W_BROWSE_TITLE),
			],
			_state_colour(state)
		)
	)

	if bool(entry.get("already_held", false)):
		var held := TempleTheme.cell("watching", TempleTheme.MUTED)
		held.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		held.custom_minimum_size = Vector2(W_BROWSE_ACTION, 0)
		held.size_flags_horizontal = Control.SIZE_SHRINK_END
		row.add_child(held)
	else:
		var watch := TempleTheme.button("WATCH", _watch_surveyed.bind(tablet))
		watch.custom_minimum_size = Vector2(W_BROWSE_ACTION, 0)
		row.add_child(watch)

	return row


func _watch_surveyed(tablet: Tablet) -> void:
	ark.add(tablet)
	_say("Now watching '%s'." % tablet.title, TempleTheme.CYAN)
	_close_panel()
	await _refresh()


func _show_help() -> void:
	var box := _open_panel_box()
	box.add_child(TempleTheme.title("— HOW THIS WORKS —", TempleTheme.YELLOW))

	var sections := [
		["THE IDEA",
		"You seal something — a note, a file — and it is encrypted and written "
		+ "to a blockchain. It is public from that moment, and unreadable. You "
		+ "then check in on a schedule you choose. If you stop checking in for "
		+ "long enough, anyone can see that you stopped. That is the whole "
		+ "trick: nobody has to decide whether you are gone, and no company or "
		+ "friend has to still exist for it to work."],

		["THE STEPS",
		"SET UP names where your records live. NEW COVENANT does the rest in "
		+ "one go: it seals the thing, inscribes it, creates its records "
		+ "on-chain and checks in once, so it comes back already keeping. That "
		+ "is several transactions and they are sent one at a time, on purpose, "
		+ "so give it a minute. "
		+ "CHECK IN then writes a small record proving you are still here — "
		+ "that is the one you repeat, before every deadline. PREPARE is only "
		+ "there for when something in that first ceremony did not finish."],

		["THE CLOCK",
		"Each covenant has its own chain, its own check-in interval and its "
		+ "own grace period. Miss the interval and it is overdue but not "
		+ "released; the grace period is the extra time after that before "
		+ "anything can be opened. It exists so a holiday, a hospital stay or "
		+ "a dead laptop does not release your covenant. Nothing can be opened "
		+ "or published until both have run out."],

		["THE THREE WAYS IT CAN OPEN",
		"Anyone once the flame goes dark: the key rides in the tablet, so it "
		+ "opens to the whole world the moment you stop checking in. Chosen "
		+ "witnesses: the key is split into shares and each is encrypted to "
		+ "one witness's wallet. A puzzle: a sum that takes a set amount of "
		+ "unbroken computing, which anyone may grind out. That one runs in a "
		+ "window of its own you can push aside, though the app has to stay "
		+ "open for it. The last two can be "
		+ "combined; the first cannot be combined with anything, because a key "
		+ "published in the open guards nothing."],

		["IF YOU ARE A WITNESS",
		"You need no file and no password — only your wallet. Give the keeper "
		+ "your identity key from I AM A WITNESS and your share travels inside "
		+ "the tablet itself, wrapped so only you can open it. Once the flame "
		+ "is dark, OPEN reads it on your machine and tells nobody. PUBLISH MY "
		+ "SHARE is the opposite and is irreversible: it puts your share "
		+ "on-chain so that, once enough witnesses do the same, the covenant "
		+ "is open to everyone forever."],

		["FINDING THINGS",
		"Listing a covenant publicly makes it findable, not readable — it was "
		+ "already public and permanent when it was inscribed. BROWSE shows "
		+ "what others have listed. A * beside a row means a share of that one "
		+ "is addressed to your wallet."],

		["WHAT IT COSTS",
		"Every write is a real transaction on a real chain, approved by you in "
		+ "GodOnChain. Sealing, preparing and each check-in all cost; reading "
		+ "costs nothing. A covenant you never check in on will release, so "
		+ "only seal what you are willing to keep paying to hold shut."],
	]
	for section: Array in sections:
		box.add_child(
			TempleTheme.line(str(section[0]), TempleTheme.YELLOW, TempleTheme.SIZE_SMALL)
		)
		box.add_child(
			TempleTheme.line(str(section[1]), TempleTheme.GREY, TempleTheme.SIZE_SMALL)
		)

	box.add_child(HSeparator.new())
	box.add_child(
		TempleTheme.line(
			"Nothing sealed here can ever be edited, deleted or recalled.",
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
