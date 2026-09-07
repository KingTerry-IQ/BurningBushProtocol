## The registry: how a sealed covenant becomes findable.
##
## Without one, a witness has to be handed an 88-character signature by some
## channel that must still exist years later — the exact fragility this project
## exists to avoid. A keeper's handle is short, memorable, and can be written
## in a will, a profile, or on paper.
##
## One table, under the protocol's own root, holding every covenant anyone has
## chosen to list. It used to be two — a private one under each keeper's own
## root and a shared commons — but under a single app root those are the same
## table, so the distinction moved from *where* a listing lives to *what it
## says*: every row carries the handle of the keeper who wrote it.
##
##   for_handle()  what one keeper has listed. This is how a witness finds
##                 what they were named in, knowing only the handle.
##   list()        everything anyone has listed. The commons.
##
## Listing never makes anything readable. The tablets were public and permanent
## the moment they were inscribed; a registry only makes them findable. And it
## is genuinely public either way: writing a row here is opting in to being
## browsed by strangers, whichever call reads it back.

class_name Registry
extends RefCounted

const TABLE_NAME := "covenants"
## Carries enough to draw a browse row without fetching every tablet: only the
## flame state needs a further read, and that is free.
##
## `handle` is what makes one table serve as everyone's registry: it is the
## keeper's chosen name for their records, and the only thing distinguishing
## one keeper's listings from another's now that the root is shared.
const COLUMNS := [
	"id", "signature", "title", "keeper", "handle", "chain", "sealed_at", "dark_after"
]
const ID_COLUMN := "id"

## One space for the protocol's root. The chain travels with each call, since
## a covenant chooses its own and one keeper may hold covenants on both.
var space: IQSpace
var chain: String = "sol"
var last_error: String = ""


func _init(iq: IQClient = null, target_chain: String = "sol") -> void:
	chain = target_chain
	space = IQSpace.new(iq, Tablet.APP_ROOT, target_chain)


## Creates the registry table. Once ever per chain, by whoever gets there first.
##
## Deliberately no writer whitelist: every keeper has to be able to list their
## own covenant. A row here is a public claim about a covenant that is already
## public, so a forged one is a nuisance rather than a danger — unlike a flame
## row, which is a claim about whether someone is alive.
func prepare(progress: Callable = Callable()) -> Variant:
	var here := space.on(chain)
	var result = await here.create_table(
		TABLE_NAME, PackedStringArray(COLUMNS), ID_COLUMN, PackedStringArray(), progress
	)
	if result == null:
		last_error = here.last_error
	return result


## Whether the registry table is already on-chain.
##
## Only the first covenant on a chain ever needs to create it; asking for one
## that exists is a transaction that fails, and the keeper pays for the attempt.
## Reads are free, so it is always cheaper to look first.
func stands() -> bool:
	return await space.on(chain).table_exists(TABLE_NAME)


## Lists one covenant so it can be found later.
func publish(
	tablet: Tablet, handle: String = "", progress: Callable = Callable()
) -> Variant:
	var row := {
		"id": tablet.id,
		"signature": tablet.signature,
		"title": tablet.title,
		"keeper": tablet.keeper,
		"handle": handle.strip_edges(),
		"chain": tablet.chain,
		"sealed_at": str(tablet.sealed_at),
		# So a browser can show the deadline without reading the tablet itself.
		"dark_after": str(tablet.days_until_dark()),
	}

	var here := space.on(chain)
	var result = await here.write_row(TABLE_NAME, row, progress)
	if result == null:
		last_error = here.last_error
	return result


## Everything listed, newest first. Costs nothing.
##
## Entries are {id, signature, title, keeper, handle, chain, sealed_at,
## dark_after}. An empty result means no registry or nothing listed, which look
## the same to a reader and are treated the same.
func list(limit: int = 100, progress: Callable = Callable()) -> Array:
	var problem: Array = []
	var rows: Array = await space.on(chain).read_rows(TABLE_NAME, limit, problem, progress)
	if rows.is_empty():
		last_error = (
			str(problem[0]) if not problem.is_empty()
			else "Nothing has been listed yet."
		)
		return []

	var entries: Array = []
	var seen := {}
	for row: Variant in rows:
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
			"handle": str(record.get("handle", "")),
			"chain": str(record.get("chain", chain)),
			"sealed_at": int(str(record.get("sealed_at", "0"))),
			"dark_after": int(str(record.get("dark_after", "90"))),
		})

	entries.sort_custom(_newest_first)
	return entries


## What one keeper has listed, by their handle.
##
## Filtered here rather than on-chain: the table has no index, so every reader
## fetches rows and picks. Fine while a registry is small, and the alternative
## — a table per keeper — is what made the fee go to each keeper instead of the
## protocol.
func for_handle(
	handle: String, limit: int = 100, progress: Callable = Callable()
) -> Array:
	var wanted := handle.strip_edges().to_lower()
	if wanted.is_empty():
		last_error = "No handle given."
		return []

	var everything: Array = await list(limit, progress)
	var mine: Array = []
	for entry: Variant in everything:
		if str((entry as Dictionary).get("handle", "")).strip_edges().to_lower() == wanted:
			mine.append(entry)

	if mine.is_empty() and last_error.is_empty():
		last_error = "Nothing is listed under '%s'." % handle
	return mine


static func _newest_first(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("sealed_at", 0)) > int(b.get("sealed_at", 0))
