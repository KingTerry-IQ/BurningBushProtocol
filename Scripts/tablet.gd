## One dead man's switch: a sealed payload, its terms, and how it is released.
##
## A keeper may hold many at once — different words for different people, on
## different clocks. Each is an independent tablet with its own flame table,
## and the Ark keeps the list.
##
## The record here is exactly what gets inscribed, so it is self-describing:
## a witness years from now needs nothing but the tablet to know which root to
## watch, how long the silence must run, and what to do with their fragment.

class_name Tablet
extends RefCounted

const PROTOCOL := "burning-bush/1"
const CIPHER := "AES-256-CBC"

## How the key comes back. These combine: a tablet may do both, in which case
## whichever happens first opens it.
enum Release {
	NONE = 0,
	## The key travels in the tablet. Anyone reading the chain has it from day
	## one — only this app's prompting is gated on the flame. See the warning
	## in `release_caveat()`; do not use it for anything that must stay shut.
	PUBLIC_BURN = 1,
	## The key is split, and each fragment is encrypted to one witness's wallet
	## identity. Nothing opens until `threshold` of them cooperate.
	WITNESSES = 2,
	## The key is sealed behind sequential work anyone may do. Unlike a public
	## burn this costs something real to open — but its clock starts when the
	## puzzle is built, not when the flame goes out, so it is a floor on effort
	## rather than a release date.
	TIME_LOCK = 4,
}

enum Payload { TEXT, FILE }

# Identity and terms
var id: String = ""
var title: String = ""
var keeper: String = ""
var chain: String = "sol"
var db_root_id: String = ""
var interval_days: int = 30
var grace_days: int = 60

# Content
var payload_kind: Payload = Payload.TEXT
var filename: String = ""
var filetype: String = ""

# Release
var release: int = Release.WITNESSES
var threshold: int = 2
var witness_count: int = 4
## Only present for PUBLIC_BURN, and public by construction.
var burn_key_hex: String = ""
## One entry per witness: {recipient: <identity hex>, envelope: {...}}.
var witness_envelopes: Array = []
## The RSW puzzle holding the key, when TIME_LOCK is set. Public by design:
## everything needed to solve it is here, and only the work is missing.
var timelock: Dictionary = {}

## Whether this was listed in the shared commons for anyone to browse. Listing
## never makes it readable, only findable — but findable is a real choice.
var public_listing: bool = false

# Chain state
var signature: String = ""
var sealed_at: int = 0

# Ciphertext
var iv_hex: String = ""
var ciphertext_b64: String = ""


func days_until_dark() -> int:
	return interval_days + grace_days


func has(mode: Release) -> bool:
	return (release & mode) != 0


## The flame table for this tablet. Each switch gets its own, so one going dark
## says nothing about the others.
func flame_table() -> String:
	return "flame_" + slug(id)


## Where witnesses publish their fragments once the flame is dark. Separate
## from the flame so that reading one says nothing about the other.
func testimony_table() -> String:
	return "witness_" + slug(id)


static func slug(text: String) -> String:
	var out := ""
	for i in text.length():
		var c := text[i].to_lower()
		out += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	return out.substr(0, 24)


## What the keeper must be told before choosing this release mode. Returns ""
## when there is nothing to warn about.
func release_caveat() -> String:
	if has(Release.PUBLIC_BURN):
		return (
			"A public burn carries its own key. Anyone reading the chain can "
			+ "open it the day it is sealed — this app simply does not offer to "
			+ "until the flame goes dark. It is a convention, not a lock. Use it "
			+ "for things you intend to become public anyway."
		)
	if has(Release.TIME_LOCK):
		return (
			"A time lock costs real work to open, but its clock starts the day "
			+ "it is built, not the day you stop checking in. Faster hardware "
			+ "gets there sooner. Treat the duration as a floor, not a date."
		)
	return ""


## Whether the chosen release modes make sense together.
##
## A public burn carries the key in the tablet, so anyone can open it from the
## day it is sealed. Combining it with witnesses or a puzzle does not add a
## safeguard — it silently cancels one, because the covenant is already open to
## everybody. It is therefore exclusive: on its own, or not at all.
static func release_is_coherent(mask: int) -> bool:
	if (mask & Release.PUBLIC_BURN) == 0:
		return mask != Release.NONE
	return mask == Release.PUBLIC_BURN


## Every route by which this could ever be opened, whoever is asking.
## Returns entries of {kind, text}.
func routes() -> Array:
	var out: Array = []
	if has(Release.PUBLIC_BURN):
		out.append({
			"kind": "public",
			"text": "Anyone at all, once the flame is dark. Its key rides in the tablet.",
		})
	if has(Release.WITNESSES):
		out.append({
			"kind": "witnesses",
			"text": "Any %d of %d witnesses, by publishing their fragments." % [
				threshold, witness_count
			],
		})
	if has(Release.TIME_LOCK):
		out.append({
			"kind": "timelock",
			"text": "Anyone willing to do about %s of computing." % timelock_duration(),
		})
	if out.is_empty():
		out.append({"kind": "none", "text": "Nothing can open this. No release was set."})
	return out


## How long the puzzle was calibrated to take, in words.
func timelock_duration() -> String:
	var seconds := int(timelock.get("estimatedSeconds", 0))
	if seconds <= 0:
		return "an unknown amount"
	if seconds < 3600:
		return "%d minutes" % maxi(1, seconds / 60)
	if seconds < 86400:
		return "%d hours" % (seconds / 3600)
	return "%d days" % (seconds / 86400)


## Human summary of how this one opens.
func release_phrase() -> String:
	var parts: PackedStringArray = []
	if has(Release.WITNESSES):
		parts.append("any %d of %d witnesses" % [threshold, witness_count])
	if has(Release.PUBLIC_BURN):
		parts.append("anyone, once the flame is dark")
	if has(Release.TIME_LOCK):
		parts.append("anyone who solves ~%s of work" % timelock_duration())
	if parts.is_empty():
		return "no release is configured — this can never be opened"
	return " or ".join(parts)


#region Serialisation

## The inscribed form. This is permanent, so every field a future reader needs
## has to be here — there is no schema to look up later.
func to_record() -> Dictionary:
	var record := {
		"protocol": PROTOCOL,
		"cipher": CIPHER,
		"id": id,
		"title": title,
		"keeper": keeper,
		"chain": chain,
		"root": db_root_id,
		"table": flame_table(),
		"interval_days": interval_days,
		"grace_days": grace_days,
		"sealed_at": sealed_at,
		"payload_kind": "file" if payload_kind == Payload.FILE else "text",
		"release": release,
		"iv": iv_hex,
		"ciphertext": ciphertext_b64,
	}

	if payload_kind == Payload.FILE:
		record["filename"] = filename
		record["filetype"] = filetype

	if has(Release.WITNESSES):
		record["threshold"] = threshold
		record["witnesses"] = witness_count
		record["witness_envelopes"] = witness_envelopes

	if has(Release.PUBLIC_BURN):
		record["burn_key"] = burn_key_hex

	if has(Release.TIME_LOCK):
		record["timelock"] = timelock

	if public_listing:
		record["public_listing"] = true

	return record


static func from_record(record: Dictionary) -> Tablet:
	var tablet := Tablet.new()
	tablet.id = str(record.get("id", ""))
	tablet.title = str(record.get("title", "untitled"))
	tablet.keeper = str(record.get("keeper", ""))
	tablet.chain = str(record.get("chain", "sol"))
	tablet.db_root_id = str(record.get("root", ""))
	tablet.interval_days = int(record.get("interval_days", 30))
	tablet.grace_days = int(record.get("grace_days", 60))
	tablet.sealed_at = int(record.get("sealed_at", 0))
	tablet.payload_kind = (
		Payload.FILE if str(record.get("payload_kind", "text")) == "file" else Payload.TEXT
	)
	tablet.filename = str(record.get("filename", ""))
	tablet.filetype = str(record.get("filetype", ""))
	tablet.release = int(record.get("release", Release.WITNESSES))
	tablet.threshold = int(record.get("threshold", 2))
	tablet.witness_count = int(record.get("witnesses", 0))
	tablet.burn_key_hex = str(record.get("burn_key", ""))
	tablet.public_listing = bool(record.get("public_listing", false))
	var puzzle: Variant = record.get("timelock", {})
	tablet.timelock = puzzle if puzzle is Dictionary else {}
	tablet.witness_envelopes = record.get("witness_envelopes", [])
	tablet.iv_hex = str(record.get("iv", ""))
	tablet.ciphertext_b64 = str(record.get("ciphertext", ""))
	tablet.signature = str(record.get("signature", ""))
	return tablet


## The local index entry. Keeps the signature and terms so the list can be
## drawn without fetching every tablet from the chain on every launch.
func to_index() -> Dictionary:
	var entry := to_record()
	entry["signature"] = signature
	# The ciphertext is already on-chain; no reason to keep a second copy.
	entry.erase("ciphertext")
	return entry

#endregion
