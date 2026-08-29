## The flame: an on-chain proof of life.
##
## Tending it writes a timestamped row. Its absence is the whole mechanism —
## nobody has to decide whether you are gone, because "no row since March" is a
## public fact anyone can check without asking permission or trusting a host.
##
## Three states, by how long the flame has gone untended:
##   BURNING     within the interval. Nothing to do.
##   GUTTERING   past the interval, inside the grace period. Tend it.
##   DARK        past grace. The covenant may be opened.
##
## The grace period exists because being unreachable is not the same as being
## dead. Make it generous; a false release cannot be undone.

class_name Flame
extends RefCounted

enum State {
	UNKNOWN,     ## Not read yet, or the chain could not be reached.
	NEVER_LIT,   ## No table, or no rows in it.
	BURNING,
	GUTTERING,
	DARK,
}

const TABLE_NAME := "flame"
const COLUMNS := ["id", "ts", "note"]
const ID_COLUMN := "id"

const SECONDS_PER_DAY := 86400

var client: IQClient
var db_root_id: String = ""
var chain: String = "sol"

## How often the keeper must tend the flame.
var interval_days: int = 30
## How long after that before the flame is declared dark.
var grace_days: int = 60

var last_error: String = ""

## tablePda for Solana, resolved once and reused.
var _table_pda: String = ""


func _init(iq: IQClient = null, root: String = "", target_chain: String = "sol") -> void:
	client = iq
	db_root_id = root
	chain = target_chain


## Total days of silence before the covenant may be opened.
func days_until_dark() -> int:
	return interval_days + grace_days


#region Writing

## Creates the flame table. Only needed once per keeper, and it spends.
## Returns the host's result, or null if refused or failed.
func kindle(progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null
	var result = await client.create_table(
		db_root_id, TABLE_NAME, PackedStringArray(COLUMNS), ID_COLUMN, chain, {}, progress
	)
	if result == null:
		last_error = client.last_error
	return result


## Writes one proof-of-life row. This spends, so the keeper is prompted.
func tend(note: String = "", progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null

	var row := {
		"id": str(Time.get_unix_time_from_system()),
		"ts": str(Time.get_unix_time_from_system()),
		"note": note.strip_edges(),
	}

	var result = await client.write_row(db_root_id, TABLE_NAME, row, chain, {}, progress)
	if result == null:
		last_error = client.last_error
	return result

#endregion


#region Reading

## Reads the flame and works out its state. Costs nothing.
##
## Returns {state, last_ts, days_since, days_left, entries}. `days_left` counts
## down to DARK and goes negative once passed.
func read_status(limit: int = 20, progress: Callable = Callable()) -> Dictionary:
	var unknown := {
		"state": State.UNKNOWN,
		"last_ts": 0,
		"days_since": -1,
		"days_left": 0,
		"entries": [],
	}

	if not _ready():
		return unknown

	var rows: Dictionary = {}
	if _normalized_chain() == "mon":
		rows = await client.read_db_table_rows(
			"", db_root_id, TABLE_NAME, chain, limit, "", progress
		)
	else:
		if _table_pda.is_empty() and not await _resolve_table_pda():
			# No table yet is a real answer, not a failure.
			if last_error.contains("not found") or last_error.is_empty():
				var never := unknown.duplicate()
				never["state"] = State.NEVER_LIT
				return never
			return unknown
		rows = await client.read_db_table_rows(
			_table_pda, "", "", chain, limit, "", progress
		)

	if rows.is_empty():
		last_error = client.last_error
		return unknown

	var entries: Array = rows.get("rows", [])
	if entries.is_empty():
		var never := unknown.duplicate()
		never["state"] = State.NEVER_LIT
		never["entries"] = []
		return never

	var newest := 0
	for entry: Variant in entries:
		if entry is Dictionary:
			var ts := int(str((entry as Dictionary).get("ts", "0")))
			newest = maxi(newest, ts)

	if newest <= 0:
		var never2 := unknown.duplicate()
		never2["state"] = State.NEVER_LIT
		never2["entries"] = entries
		return never2

	var now := int(Time.get_unix_time_from_system())
	@warning_ignore("integer_division")
	var days_since: int = (now - newest) / SECONDS_PER_DAY

	var state := State.BURNING
	if days_since >= days_until_dark():
		state = State.DARK
	elif days_since >= interval_days:
		state = State.GUTTERING

	return {
		"state": state,
		"last_ts": newest,
		"days_since": days_since,
		"days_left": days_until_dark() - days_since,
		"entries": entries,
	}


## Solana addresses a table by PDA, which the row reader needs. The table list
## is the only place to get it, so it is looked up once and cached.
func _resolve_table_pda() -> bool:
	var listing: Dictionary = await client.get_db_table_list(db_root_id, chain)
	if listing.is_empty():
		last_error = client.last_error
		return false

	var seeds: Array = listing.get("tableSeeds", [])
	var pdas: Array = listing.get("tablePdas", [])
	var wanted := TABLE_NAME.to_utf8_buffer().hex_encode()

	for i in mini(seeds.size(), pdas.size()):
		var seed := str(seeds[i]).to_lower()
		if seed == wanted or seed == TABLE_NAME:
			_table_pda = str(pdas[i])
			return true

	last_error = "No '%s' table under %s yet." % [TABLE_NAME, db_root_id]
	return false

#endregion


func _normalized_chain() -> String:
	var c := chain.strip_edges().to_lower()
	return "mon" if (c == "mon" or c == "monad") else "sol"


func _ready_check() -> bool:
	return _ready()


func _ready() -> bool:
	if client == null or not client.is_available():
		last_error = "Not connected to a host."
		return false
	if db_root_id.strip_edges().is_empty():
		last_error = "No covenant root is set."
		return false
	return true


## Human-readable state, in the app's voice.
static func state_name(state: State) -> String:
	match state:
		State.BURNING:
			return "BURNING"
		State.GUTTERING:
			return "GUTTERING"
		State.DARK:
			return "DARK"
		State.NEVER_LIT:
			return "UNLIT"
		_:
			return "UNKNOWN"
