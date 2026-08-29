## Reading a database table on either chain.
##
## The two chains disagree about how a table is addressed: Monad takes a name,
## Solana takes a program-derived address that only the table listing can give
## you. Flames and testimony both need this, so the awkwardness lives here once.

class_name ChainTable
extends RefCounted

## table key -> resolved Solana PDA. Resolution costs a round trip and the
## answer never changes, so it is worth keeping for the session.
static var _pda_cache: Dictionary = {}


## Reads one row, whichever chain it came from.
##
## The two SDKs disagree about shape: Solana's readTableRows hands back the
## row's own fields at the top level, while Monad's wraps them as
## {txHash, data}. Reading Monad rows as though they were flat found no fields
## at all, which is why a tended flame still read as never lit.
##
## The transaction id is normalised onto "__tx" so callers need not care.
static func unwrap_row(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {}
	var row: Dictionary = entry

	if row.has("data"):
		var payload: Variant = row["data"]
		# Some paths hand the row back as a JSON string rather than an object.
		if payload is String:
			payload = JSON.parse_string(str(payload))
		if payload is Dictionary:
			var inner: Dictionary = (payload as Dictionary).duplicate()
			inner["__tx"] = str(row.get("txHash", row.get("signature", "")))
			return inner

	var flat := row.duplicate()
	flat["__tx"] = str(
		row.get("__txSignature", row.get("signature", row.get("txHash", "")))
	)
	return flat


## All rows from a result, already unwrapped.
static func rows_of(result: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in result.get("rows", []):
		var row := unwrap_row(entry)
		if not row.is_empty():
			out.append(row)
	return out


static func is_monad(chain: String) -> bool:
	var c := chain.strip_edges().to_lower()
	return c == "mon" or c == "monad"


## Reads rows from a table on either chain. Returns {} and sets `error` when it
## cannot, including the ordinary case of the table not existing yet.
static func read_rows(
	client: IQClient,
	db_root_id: String,
	table_name: String,
	chain: String,
	limit: int = 20,
	error: Array = [],
	progress: Callable = Callable()
) -> Dictionary:
	if client == null or not client.is_available():
		error.append("Not attached to a host.")
		return {}

	if is_monad(chain):
		var rows: Dictionary = await client.read_db_table_rows(
			"", db_root_id, table_name, chain, limit, "", progress
		)
		if rows.is_empty():
			error.append(client.last_error)
		return rows

	var pda: String = await resolve_pda(client, db_root_id, table_name, chain, error)
	if pda.is_empty():
		return {}

	var sol_rows: Dictionary = await client.read_db_table_rows(
		pda, "", "", chain, limit, "", progress
	)
	if sol_rows.is_empty():
		error.append(client.last_error)
	return sol_rows


## Finds a Solana table's address by matching its seed in the root's listing.
## Returns "" when the table has not been created yet.
static func resolve_pda(
	client: IQClient,
	db_root_id: String,
	table_name: String,
	chain: String,
	error: Array = []
) -> String:
	var key := "%s/%s/%s" % [chain, db_root_id, table_name]
	if _pda_cache.has(key):
		return str(_pda_cache[key])

	var listing: Dictionary = await client.get_db_table_list(db_root_id, chain)
	if listing.is_empty():
		error.append(client.last_error)
		return ""

	var seeds: Array = listing.get("tableSeeds", [])
	var pdas: Array = listing.get("tablePdas", [])
	# The listing reports seeds hex-encoded, so compare in that form.
	var wanted := table_name.to_utf8_buffer().hex_encode()

	for i in mini(seeds.size(), pdas.size()):
		var seed := str(seeds[i]).to_lower()
		if seed == wanted or seed == table_name:
			_pda_cache[key] = str(pdas[i])
			return str(pdas[i])

	error.append("No '%s' table under %s yet." % [table_name, db_root_id])
	return ""


## Forgets a cached address, for when a table has just been created.
static func forget(db_root_id: String, table_name: String, chain: String) -> void:
	_pda_cache.erase("%s/%s/%s" % [chain, db_root_id, table_name])
