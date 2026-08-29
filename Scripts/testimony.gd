## Testimony: where witnesses bring their fragments once a flame is dark.
##
## A witness holding one fragment cannot open anything alone, and coordinating
## k people privately is exactly the organisational fragility this is meant to
## avoid. So they testify in public instead: each contributes their fragment as
## a row, and once `threshold` of them have, anyone can reconstruct the key and
## the word is out.
##
## That is deliberately irreversible. Testifying is the act of releasing the
## covenant, not a step towards privately reading it, and a witness should be
## told as much before they do it.

class_name Testimony
extends RefCounted

const COLUMNS := ["id", "fragment", "witness"]
const ID_COLUMN := "id"

var client: IQClient
var tablet: Tablet
var last_error: String = ""


func _init(iq: IQClient = null, for_tablet: Tablet = null) -> void:
	client = iq
	tablet = for_tablet


func table_name() -> String:
	return tablet.testimony_table()


## Creates the table witnesses will testify into. The keeper does this when
## building the altar, so it stands ready long before it is needed.
func prepare(progress: Callable = Callable()) -> Variant:
	if not _ready():
		return null
	var result = await client.create_table(
		tablet.db_root_id,
		table_name(),
		PackedStringArray(COLUMNS),
		ID_COLUMN,
		tablet.chain,
		{},
		progress
	)
	if result == null:
		last_error = client.last_error
	else:
		ChainTable.forget(tablet.db_root_id, table_name(), tablet.chain)
	return result


## Publishes one fragment. This is a release, not a read: once enough are here,
## the covenant is open to everyone forever.
func testify(
	fragment_hex: String, witness_label: String = "", progress: Callable = Callable()
) -> Variant:
	if not _ready():
		return null
	if fragment_hex.strip_edges().is_empty():
		last_error = "There is no fragment to give."
		return null

	var row := {
		"id": str(Time.get_unix_time_from_system()),
		"fragment": fragment_hex.strip_edges(),
		"witness": witness_label.strip_edges(),
	}

	var result = await client.write_row(
		tablet.db_root_id, table_name(), row, tablet.chain, {}, progress
	)
	if result == null:
		last_error = client.last_error
	return result


## Everything witnesses have testified so far, as fragments.
##
## Returns {fragments, witnesses, enough}: `enough` is true once the threshold
## is met, at which point the key can be rebuilt by anyone.
func gather(progress: Callable = Callable()) -> Dictionary:
	var empty := {"fragments": [] as Array[PackedByteArray], "witnesses": [], "enough": false}
	if not _ready():
		return empty

	var problem: Array = []
	var rows: Dictionary = await ChainTable.read_rows(
		client, tablet.db_root_id, table_name(), tablet.chain, 64, problem, progress
	)
	if rows.is_empty():
		# No table and no rows are both just "nobody has testified".
		last_error = str(problem[0]) if not problem.is_empty() else ""
		return empty

	var fragments: Array[PackedByteArray] = []
	var witnesses: Array = []
	var seen := {}

	for entry: Variant in ChainTable.rows_of(rows):
		var record: Dictionary = entry
		var hex := str(record.get("fragment", "")).strip_edges()
		var fragment := Shamir.from_hex(hex)
		if fragment.is_empty():
			continue
		# One witness testifying twice must not count twice; the x-coordinate
		# is the fragment's identity, and duplicates break interpolation.
		var index: int = fragment[0]
		if seen.has(index):
			continue
		seen[index] = true
		fragments.append(fragment)
		witnesses.append(str(record.get("witness", "")))

	return {
		"fragments": fragments,
		"witnesses": witnesses,
		"enough": fragments.size() >= tablet.threshold,
	}


## The envelope addressed to this wallet, if this tablet has one for us.
## Returns {} when we are not a witness to it.
func my_envelope(identity: String) -> Dictionary:
	if identity.is_empty():
		return {}
	for entry: Variant in tablet.witness_envelopes:
		if not entry is Dictionary:
			continue
		if str((entry as Dictionary).get("recipient", "")) == identity:
			var envelope: Variant = (entry as Dictionary).get("envelope", {})
			return envelope if envelope is Dictionary else {}
	return {}


func _ready() -> bool:
	if client == null or not client.is_available():
		last_error = "Not attached to a host."
		return false
	if tablet == null or tablet.db_root_id.strip_edges().is_empty():
		last_error = "This tablet has no root."
		return false
	return true
