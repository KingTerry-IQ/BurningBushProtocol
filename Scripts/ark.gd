## The Ark: every tablet this keeper holds, and the state of each flame.
##
## A keeper can run many switches at once — different words, different people,
## different clocks — so the app is a list before it is anything else. The most
## important row in that list is the one that has gone dark.
##
## The index is a local convenience only. Everything needed to reconstruct it
## lives on-chain in the tablets themselves; losing this file loses nothing but
## the shortcut.

class_name Ark
extends RefCounted

const INDEX_PATH := "user://ark.json"

## Overridable so a test never deletes a real keeper's list of covenants.
var index_path: String = INDEX_PATH

var client: IQClient
var tablets: Array[Tablet] = []
## tablet id -> the last status read for it.
var states: Dictionary = {}

var last_error: String = ""


func _init(iq: IQClient = null) -> void:
	client = iq
	load_index()


#region The list

func add(tablet: Tablet) -> void:
	for i in tablets.size():
		if tablets[i].id == tablet.id:
			tablets[i] = tablet
			save_index()
			return
	tablets.append(tablet)
	save_index()


func remove(id: String) -> void:
	# Only forgets it locally. The tablet itself is on-chain and permanent, and
	# the flame keeps burning whether or not this app is watching.
	var kept: Array[Tablet] = []
	for tablet: Tablet in tablets:
		if tablet.id != id:
			kept.append(tablet)
	tablets = kept
	states.erase(id)
	save_index()


func find(id: String) -> Tablet:
	for tablet: Tablet in tablets:
		if tablet.id == id:
			return tablet
	return null


## A fresh id. Human-readable so it can be recognised in a table name.
static func mint_id(title: String) -> String:
	var stamp := str(Time.get_unix_time_from_system())
	var slug := Tablet.slug(title if not title.strip_edges().is_empty() else "tablet")
	return "%s_%s" % [slug, stamp.substr(stamp.length() - 6)]

#endregion


#region Watching

## Reads every flame. Returns the tablets whose flame has gone dark, so the
## caller can lead with them.
func refresh(progress: Callable = Callable()) -> Array[Tablet]:
	var dark: Array[Tablet] = []
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return dark

	for tablet: Tablet in tablets:
		var flame := flame_for(tablet)
		var status := await flame.read_status(5, progress)
		states[tablet.id] = status
		if int(status.get("state", Flame.State.UNKNOWN)) == Flame.State.DARK:
			dark.append(tablet)

	return dark


## The flame belonging to one tablet. Each has its own table.
func flame_for(tablet: Tablet) -> Flame:
	var flame := Flame.new(client, tablet.db_root_id, tablet.chain)
	flame.interval_days = tablet.interval_days
	flame.grace_days = tablet.grace_days
	flame.table_name = tablet.flame_table()
	return flame


func state_of(tablet: Tablet) -> Flame.State:
	var status: Dictionary = states.get(tablet.id, {})
	return status.get("state", Flame.State.UNKNOWN)


func days_since(tablet: Tablet) -> int:
	var status: Dictionary = states.get(tablet.id, {})
	return int(status.get("days_since", -1))


## Tablets whose flame is dark, newest silence first. These are the ones that
## matter: the keeper is presumed gone and the word is due.
func dark_tablets() -> Array[Tablet]:
	var out: Array[Tablet] = []
	for tablet: Tablet in tablets:
		if state_of(tablet) == Flame.State.DARK:
			out.append(tablet)
	out.sort_custom(func(a: Tablet, b: Tablet) -> bool: return days_since(a) > days_since(b))
	return out


## Everything still being kept, most urgent first: guttering before burning.
func living_tablets() -> Array[Tablet]:
	var out: Array[Tablet] = []
	for tablet: Tablet in tablets:
		var state := state_of(tablet)
		if state != Flame.State.DARK:
			out.append(tablet)
	out.sort_custom(_more_urgent)
	return out


func _more_urgent(a: Tablet, b: Tablet) -> bool:
	var rank := func(t: Tablet) -> int:
		match state_of(t):
			Flame.State.GUTTERING:
				return 0
			Flame.State.BURNING:
				return 1
			Flame.State.NEVER_LIT:
				return 2
			_:
				return 3
	var ra: int = rank.call(a)
	var rb: int = rank.call(b)
	if ra != rb:
		return ra < rb
	return days_since(a) > days_since(b)

#endregion


#region Persistence

func load_index() -> void:
	tablets = []
	if not FileAccess.file_exists(index_path):
		return
	var file := FileAccess.open(index_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Array:
		return
	for entry: Variant in parsed:
		if entry is Dictionary:
			tablets.append(Tablet.from_record(entry))


func save_index() -> void:
	var entries: Array = []
	for tablet: Tablet in tablets:
		entries.append(tablet.to_index())
	var file := FileAccess.open(index_path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not write the index: %d" % FileAccess.get_open_error()
		return
	file.store_string(JSON.stringify(entries, "\t"))
	file.close()


## Everything a keeper has listed under their root, without adopting any of it.
##
## This is how a witness finds what they were named in: they need the keeper's
## root, which is short and durable, rather than a signature per covenant handed
## over by some channel that has to survive the keeper.
##
## Returns entries of {tablet, state, days_since, i_am_witness, already_held}.
func survey(
	root: String, chain: String, my_identity: String, progress: Callable = Callable()
) -> Array:
	var found: Array = []
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return found

	var registry := Registry.new(client, root, chain)
	var listed := await registry.list(50, progress)
	if listed.is_empty():
		last_error = registry.last_error
		return found

	for entry: Dictionary in listed:
		var signature := str(entry.get("signature", ""))
		var tablet := await read_tablet(signature, str(entry.get("chain", chain)))
		if tablet == null:
			continue

		# Reading the flame is free, so the survey can show state immediately
		# rather than making the reader adopt something to find out.
		var flame := flame_for(tablet)
		var status := await flame.read_status(5)

		var testimony := Testimony.new(client, tablet)
		found.append({
			"tablet": tablet,
			"state": status.get("state", Flame.State.UNKNOWN),
			"days_since": int(status.get("days_since", -1)),
			# Counts down to release, negative once passed.
			"days_left": int(status.get("days_left", tablet.days_until_dark())),
			"i_am_witness": not testimony.my_envelope(my_identity).is_empty(),
			"already_held": find(tablet.id) != null,
		})

	return found


## The shared commons: covenants their keepers chose to list publicly.
##
## This is the only view that reaches across keepers. Everything else needs a
## root you were given.
func browse(chain: String, my_identity: String, progress: Callable = Callable()) -> Array:
	return await survey(Registry.COMMONS_ROOT, chain, my_identity, progress)


## Fetches and parses a tablet without adding it to the ark.
func read_tablet(signature: String, chain: String = "sol") -> Tablet:
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return null

	var document = await client.read_code_in(signature, chain)
	if document == null:
		last_error = client.last_error
		return null

	var raw = document.data if document is Dictionary else document
	var parsed: Variant = JSON.parse_string(str(raw))
	if not parsed is Dictionary:
		last_error = "That inscription is not a tablet."
		return null
	if str((parsed as Dictionary).get("protocol", "")) != Tablet.PROTOCOL:
		last_error = "That inscription is not a %s tablet." % Tablet.PROTOCOL
		return null

	var tablet := Tablet.from_record(parsed)
	tablet.signature = signature
	if tablet.id.is_empty():
		tablet.id = mint_id(tablet.title)
	return tablet


## Rebuilds an entry from a tablet on-chain, for a witness who was handed only
## a signature, or a keeper restoring onto a new machine.
func adopt(signature: String, chain: String = "sol") -> Tablet:
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return null

	var tablet := await read_tablet(signature, chain)
	if tablet == null:
		return null
	add(tablet)
	return tablet

#endregion
