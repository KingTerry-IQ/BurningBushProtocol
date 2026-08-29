## Registries: how a sealed covenant becomes findable.
##
## Without one, a witness has to be handed an 88-character signature by some
## channel that must still exist years later — the exact fragility this project
## exists to avoid. A root is short, memorable, and can be written in a will, a
## profile, or on paper.
##
## Two registries, same shape:
##
##   A keeper's own, under their root. Anyone who knows the root sees
##   everything that keeper has sealed. This is the private-ish default.
##
##   The commons, under a root everyone shares. Opting in makes a covenant
##   browsable by strangers, which is the point when the thing is meant to
##   reach the public, and the wrong choice when it is not.
##
## Listing never makes anything readable. The tablets were public and permanent
## the moment they were inscribed; a registry only makes them findable.

class_name Registry
extends RefCounted

## The shared root. Anything listed here is browsable by anyone, forever.
const COMMONS_ROOT := "burning-bush-commons"

const TABLE_NAME := "covenants"
## Carries enough to draw a browse row without fetching every tablet: only the
## flame state needs a further read, and that is free.
const COLUMNS := [
	"id", "signature", "title", "keeper", "root", "chain", "sealed_at", "dark_after"
]
const ID_COLUMN := "id"

var client: IQClient
var db_root_id: String = ""
var chain: String = "sol"
var last_error: String = ""


func _init(iq: IQClient = null, root: String = "", target_chain: String = "sol") -> void:
	client = iq
	db_root_id = root
	chain = target_chain


## The shared registry everyone can browse.
static func commons(iq: IQClient, target_chain: String = "sol") -> Registry:
	return Registry.new(iq, COMMONS_ROOT, target_chain)


func is_commons() -> bool:
	return db_root_id == COMMONS_ROOT


## Creates the registry. Once per root — and for the commons, once ever, by
## whoever gets there first.
func prepare(progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null
	var result = await client.create_table(
		db_root_id, TABLE_NAME, PackedStringArray(COLUMNS), ID_COLUMN, chain, {}, progress
	)
	if result == null:
		last_error = client.last_error
	else:
		ChainTable.forget(db_root_id, TABLE_NAME, chain)
	return result


## Lists one covenant so it can be found later.
func publish(tablet: Tablet, progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null

	var row := {
		"id": tablet.id,
		"signature": tablet.signature,
		"title": tablet.title,
		"keeper": tablet.keeper,
		"root": tablet.db_root_id,
		"chain": tablet.chain,
		"sealed_at": str(tablet.sealed_at),
		# So a browser can show the deadline without reading the tablet itself.
		"dark_after": str(tablet.days_until_dark()),
	}

	var result = await client.write_row(db_root_id, TABLE_NAME, row, chain, {}, progress)
	if result == null:
		last_error = client.last_error
	return result


## Everything listed here, newest first. Costs nothing.
##
## Entries are {id, signature, title, keeper, root, chain, sealed_at,
## dark_after}. An empty result means no registry or nothing listed, which look
## the same to a reader and are treated the same.
func list(limit: int = 100, progress: Callable = Callable()) -> Array:
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return []
	if db_root_id.strip_edges().is_empty():
		last_error = "No root given."
		return []

	var problem: Array = []
	var rows: Dictionary = await ChainTable.read_rows(
		client, db_root_id, TABLE_NAME, chain, limit, problem, progress
	)
	if rows.is_empty():
		if is_commons():
			last_error = "Nothing has been listed publicly yet."
		else:
			last_error = (
				str(problem[0]) if not problem.is_empty()
				else "Nothing is listed under '%s'." % db_root_id
			)
		return []

	var entries: Array = []
	var seen := {}
	for row: Variant in ChainTable.rows_of(rows):
		var record: Dictionary = row
		var signature := str(record.get("signature", "")).strip_edges()
		# The same covenant listed twice is one covenant.
		if signature.is_empty() or seen.has(signature):
			continue
		seen[signature] = true
		entries.append({
			"id": str(record.get("id", "")),
			"signature": signature,
			"title": str(record.get("title", "untitled")),
			"keeper": str(record.get("keeper", "")),
			"root": str(record.get("root", db_root_id)),
			"chain": str(record.get("chain", chain)),
			"sealed_at": int(str(record.get("sealed_at", "0"))),
			"dark_after": int(str(record.get("dark_after", "90"))),
		})

	entries.sort_custom(_newest_first)
	return entries


static func _newest_first(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("sealed_at", 0)) > int(b.get("sealed_at", 0))


func _ready() -> bool:
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return false
	if db_root_id.strip_edges().is_empty():
		last_error = "No root is set."
		return false
	return true
