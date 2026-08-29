# End-to-end check of the witness path against a live host.
#
# The unit suite covers the maths; this covers the part that crosses a process
# boundary: deriving a wallet identity, wrapping a fragment to it, and getting
# that exact fragment back out again. If this passes, a keeper can address a
# fragment to a witness and that witness can open it and nobody else can.
#
# Needs a running GodOnChain host with a Solana signing key. Run with the
# GODONCHAIN_IQ_* environment variables set:
#
#   Godot --headless --path . --script res://tools/bbp_witness_check.gd
extends SceneTree

var failures := 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  PASS  ", label)
	else:
		failures += 1
		print("  FAIL  ", label, "  ", detail)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var iq := IQClient.new()
	root.add_child(iq)
	await process_frame

	print("\n--- host ---")
	var found: bool = await iq.discover()
	check("attached to a host", found, iq.last_error)
	if not found:
		_finish()
		return

	print("\n--- identity ---")
	var identity: String = await iq.crypto_identity()
	check("this wallet has an identity", not identity.is_empty(), iq.last_error)
	check("  it is a 32-byte key in hex", identity.length() == 64, str(identity.length()))

	var again: String = await iq.crypto_identity()
	# Determinism is the whole reason a witness needs nothing stored.
	check("  and it is the same every time", identity == again)
	if identity.is_empty():
		_finish()
		return

	print("\n--- wrapping a fragment ---")
	var key := Crypto.new().generate_random_bytes(32)
	var fragments := Shamir.split(key, 4, 2)
	check("a key splits into fragments", fragments.size() == 4)

	var mine := Shamir.to_hex(fragments[0])
	var envelope: Dictionary = await iq.encrypt_to(PackedStringArray([identity]), mine)
	check("the fragment wraps to the identity", not envelope.is_empty(), iq.last_error)
	if envelope.is_empty():
		_finish()
		return

	check("  the envelope names a recipient", envelope.has("recipients"))
	check(
		"  and the fragment is not sitting in it in the clear",
		not JSON.stringify(envelope).contains(mine),
		"the envelope leaked its contents"
	)

	print("\n--- unwrapping it ---")
	var recovered: String = await iq.decrypt_envelope(envelope)
	check("the envelope opens", not recovered.is_empty(), iq.last_error)
	check("  and returns the same fragment", recovered == mine, recovered)

	var restored := Shamir.from_hex(recovered)
	check("  which still parses as a fragment", restored == fragments[0])

	# Two of the four, one of them the round-tripped fragment, must rebuild the key.
	var pair: Array[PackedByteArray] = [restored, fragments[2]]
	check("  and still reconstructs the key with a peer", Shamir.combine(pair) == key)

	print("\n--- addressed to somebody else ---")
	var stranger := Crypto.new().generate_random_bytes(32).hex_encode()
	var not_ours: Dictionary = await iq.encrypt_to(PackedStringArray([stranger]), "not for you")
	check("wraps to a stranger's key", not not_ours.is_empty(), iq.last_error)
	if not not_ours.is_empty():
		var stolen: String = await iq.decrypt_envelope(not_ours)
		check("  and we cannot open it", stolen.is_empty(), stolen)

	print("\n--- envelope routing ---")
	var tablet := Tablet.new()
	tablet.id = "check_1"
	tablet.witness_envelopes = [
		{"recipient": stranger, "label": "someone else", "envelope": not_ours},
		{"recipient": identity, "label": "us", "envelope": envelope},
	]
	var testimony := Testimony.new(iq, tablet)
	check("finds the envelope addressed to us", testimony.my_envelope(identity) == envelope)
	check("  ignores the others", testimony.my_envelope("00" .repeat(32)).is_empty())
	check("  and the table is named after the tablet", tablet.testimony_table() == "witness_check_1")

	_finish()


func _finish() -> void:
	print("\n%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
