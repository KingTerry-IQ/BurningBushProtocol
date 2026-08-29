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

## Each tablet keeps its own flame, so one going dark says nothing about the
## others. Set by Ark from the tablet it belongs to.
var table_name: String = "flame"

var last_error: String = ""


func _init(iq: IQClient = null, root: String = "", target_chain: String = "sol") -> void:
	client = iq
	db_root_id = root
	chain = target_chain


## Total days of silence before the covenant may be opened.
func days_until_dark() -> int:
	return interval_days + grace_days


## Whether a covenant on this flame may actually be released yet.
##
## This is what the grace period is for. Between the interval and the deadline
## the keeper is visibly overdue — nagged, and marked overdue to their
## witnesses — but nothing irreversible may happen, because being late is not
## the same as being gone. Only past the deadline does release arm.
static func releasable(state: State) -> bool:
	return state == State.DARK


#region Writing

## Creates the flame table. Only needed once per keeper, and it spends.
## Returns the host's result, or null if refused or failed.
func kindle(progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null
	var result = await client.create_table(
		db_root_id, table_name, PackedStringArray(COLUMNS), ID_COLUMN, chain, {}, progress
	)
	if result == null:
		last_error = client.last_error
	else:
		ChainTable.forget(db_root_id, table_name, chain)
	return result


## Whether this flame's table can actually be found on-chain.
##
## A write job reporting "completed" only means the host finished its work, not
## that the chain now holds what was asked for — a reverted transaction looks
## the same from here. Anything that claims to have created something should
## check afterwards rather than take its own word for it.
func exists_on_chain() -> bool:
	if client == null or not client.is_available():
		return false
	ChainTable.forget(db_root_id, table_name, chain)
	var problem: Array = []
	var rows: Dictionary = await ChainTable.read_rows(
		client, db_root_id, table_name, chain, 1, problem
	)
	if not rows.is_empty():
		return true
	last_error = str(problem[0]) if not problem.is_empty() else "The table is not there."
	return false


## Writes one proof-of-life row. This spends, so the keeper is prompted.
func tend(note: String = "", progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null

	var row := {
		"id": str(Time.get_unix_time_from_system()),
		"ts": str(Time.get_unix_time_from_system()),
		"note": note.strip_edges(),
	}

	var result = await client.write_row(db_root_id, table_name, row, chain, {}, progress)
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

	var problem: Array = []
	var rows: Dictionary = await ChainTable.read_rows(
		client, db_root_id, table_name, chain, limit, problem, progress
	)

	if rows.is_empty():
		last_error = str(problem[0]) if not problem.is_empty() else "Could not read the flame."
		# We reached the host and it had nothing for us, which in practice means
		# the table has not been created — the flame was never lit. UNKNOWN is
		# reserved for not being able to ask at all, which _ready() has already
		# caught above. Matching on error text was chain-specific and left MON
		# covenants reading as UNKNOWN forever.
		var never := unknown.duplicate()
		never["state"] = State.NEVER_LIT
		return never

	var entries: Array = ChainTable.rows_of(rows)
	if entries.is_empty():
		var never := unknown.duplicate()
		never["state"] = State.NEVER_LIT
		never["entries"] = []
		return never

	var newest := 0
	for entry: Variant in entries:
		var row: Dictionary = entry
		# The timestamp is written as a string; on some paths it arrives as a
		# number, so go through str() either way.
		var ts := int(str(row.get("ts", "0")).split(".")[0])
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


#endregion


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
