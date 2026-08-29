## The covenant: a tablet sealed now, opened only when the flame goes dark.
##
## The tablet is inscribed as ciphertext on the day it is sealed, so it is
## public and permanent from the start. Nothing about the content is secret
## because it is hidden; it is secret because the key is split.
##
## The key is never inscribed. It is broken into fragments by [Shamir], each
## fragment going to one witness. Any `threshold` of them restore it; fewer
## reveal nothing whatsoever.
##
## Sealing is deliberately one-way. There is no unsealing, no editing and no
## deleting — the tablet outlives its author, which is the entire point and
## also the danger.

class_name Covenant
extends RefCounted

## Written into every tablet so a reader years from now knows the shape.
const PROTOCOL := "burning-bush/1"
const CIPHER := "AES-256-CBC"

const KEY_BYTES := 32
const IV_BYTES := 16
const BLOCK_BYTES := 16

var client: IQClient
var last_error: String = ""


func _init(iq: IQClient = null) -> void:
	client = iq


#region Sealing

## Encrypts `plaintext` under a fresh random key.
## Returns {tablet, key}: the tablet is inscribable, the key must be split and
## then forgotten. Returns {} on failure.
func seal(plaintext: String, terms: Dictionary = {}) -> Dictionary:
	if plaintext.strip_edges().is_empty():
		last_error = "There is nothing to seal."
		return {}

	var crypto := Crypto.new()
	var key := crypto.generate_random_bytes(KEY_BYTES)
	var iv := crypto.generate_random_bytes(IV_BYTES)

	var aes := AESContext.new()
	if aes.start(AESContext.MODE_CBC_ENCRYPT, key, iv) != OK:
		last_error = "The cipher would not start."
		return {}
	var ciphertext := aes.update(_pad(plaintext.to_utf8_buffer()))
	aes.finish()

	var tablet := {
		"protocol": PROTOCOL,
		"cipher": CIPHER,
		"sealed_at": int(Time.get_unix_time_from_system()),
		"iv": iv.hex_encode(),
		"ciphertext": Marshalls.raw_to_base64(ciphertext),
	}
	# Terms travel with the tablet so a witness needs nothing but this record:
	# which root to watch, how many fragments, how long the silence must run.
	for field: String in terms:
		tablet[field] = terms[field]

	return {"tablet": tablet, "key": key}


## Reverses seal() once the key has been restored from fragments.
## Returns "" on failure, which usually means the wrong fragments.
func unseal(tablet: Dictionary, key: PackedByteArray) -> String:
	if key.size() != KEY_BYTES:
		last_error = "That key is the wrong size — the fragments may not match."
		return ""

	var iv := _hex_to_bytes(str(tablet.get("iv", "")))
	if iv.size() != IV_BYTES:
		last_error = "The tablet is missing its initialisation vector."
		return ""

	var ciphertext := Marshalls.base64_to_raw(str(tablet.get("ciphertext", "")))
	if ciphertext.is_empty() or ciphertext.size() % BLOCK_BYTES != 0:
		last_error = "The tablet's ciphertext is malformed."
		return ""

	var aes := AESContext.new()
	if aes.start(AESContext.MODE_CBC_DECRYPT, key, iv) != OK:
		last_error = "The cipher would not start."
		return ""
	var padded := aes.update(ciphertext)
	aes.finish()

	var plain := _unpad(padded)
	if plain.is_empty():
		last_error = "Those fragments do not open this tablet."
		return ""

	var text := plain.get_string_from_utf8()
	if text.is_empty():
		last_error = "Those fragments do not open this tablet."
		return ""
	return text

#endregion


#region Fragments

## Breaks the key into fragments, one per witness.
func shatter(
	key: PackedByteArray, witnesses: int, threshold: int
) -> Array[PackedByteArray]:
	var problem: Array = []
	var fragments := Shamir.split(key, witnesses, threshold, problem)
	if fragments.is_empty():
		last_error = str(problem[0]) if not problem.is_empty() else "Could not split the key."
	return fragments


## Rebuilds the key from fragments handed back by witnesses.
func gather(fragments: Array[PackedByteArray]) -> PackedByteArray:
	var problem: Array = []
	var key := Shamir.combine(fragments, problem)
	if key.is_empty():
		last_error = str(problem[0]) if not problem.is_empty() else "Could not restore the key."
	return key


## Parses a fragment a witness has pasted in. Returns an empty array if it is
## not a fragment at all.
func read_fragment(text: String) -> PackedByteArray:
	var fragment := Shamir.from_hex(text)
	if fragment.is_empty():
		last_error = "That does not look like a fragment."
	return fragment

#endregion


#region Chain

## Inscribes the tablet. Spends, so the keeper is prompted.
## Returns the transaction signature, or null.
func inscribe(
	tablet: Dictionary, chain: String = "sol", progress: Callable = Callable()
) -> Variant:
	if client == null or not client.is_available():
		last_error = "Not connected to a host."
		return null

	var result = await client.write_code_in(
		JSON.stringify(tablet), "covenant.json", "json", chain, progress
	)
	if result == null:
		last_error = client.last_error
	return result


## Fetches a tablet by its signature. Costs nothing, and needs no key —
## anyone may read a sealed tablet, they simply cannot open it.
func fetch(
	signature: String, chain: String = "sol", progress: Callable = Callable()
) -> Dictionary:
	if client == null or not client.is_available():
		last_error = "Not connected to a host."
		return {}

	var document = await client.read_code_in(signature, chain, progress)
	if document == null:
		last_error = client.last_error
		return {}

	var raw = document.data if document is Dictionary else document
	var parsed: Variant = JSON.parse_string(str(raw))
	if not parsed is Dictionary:
		last_error = "That inscription is not a covenant."
		return {}

	var tablet: Dictionary = parsed
	if str(tablet.get("protocol", "")) != PROTOCOL:
		last_error = "That inscription is not a %s covenant." % PROTOCOL
		return {}
	return tablet

#endregion


#region Bytes

## PKCS#7. AES needs whole blocks, and the padding records its own length so
## unpadding is unambiguous.
static func _pad(data: PackedByteArray) -> PackedByteArray:
	var padding := BLOCK_BYTES - (data.size() % BLOCK_BYTES)
	var out := data.duplicate()
	for i in padding:
		out.append(padding)
	return out


static func _unpad(data: PackedByteArray) -> PackedByteArray:
	if data.is_empty() or data.size() % BLOCK_BYTES != 0:
		return PackedByteArray()
	var padding := data[data.size() - 1]
	if padding < 1 or padding > BLOCK_BYTES or padding > data.size():
		return PackedByteArray()
	# Every padding byte must carry the same value, which is what makes a wrong
	# key almost always fail here rather than returning nonsense.
	for i in padding:
		if data[data.size() - 1 - i] != padding:
			return PackedByteArray()
	return data.slice(0, data.size() - padding)


static func _hex_to_bytes(text: String) -> PackedByteArray:
	var cleaned := text.strip_edges().to_lower()
	if cleaned.is_empty() or cleaned.length() % 2 != 0:
		return PackedByteArray()
	var out := PackedByteArray()
	for i in range(0, cleaned.length(), 2):
		var pair := cleaned.substr(i, 2)
		if not pair.is_valid_hex_number():
			return PackedByteArray()
		out.append(("0x" + pair).hex_to_int())
	return out

#endregion
