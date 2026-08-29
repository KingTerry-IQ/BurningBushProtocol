# Headless checks for the parts that must not be wrong.
#
# Shamir gets the most attention: a splitting bug that still round-trips on the
# happy path would silently produce a covenant nobody can ever open, and there
# is no way to find that out later — the tablet is already permanent.
#
# Run: Godot --headless --path . --script res://tools/bbp_selftest.gd
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
	_test_field()
	_test_split_combine()
	_test_subsets()
	_test_below_threshold()
	_test_rejections()
	_test_hex()
	_test_covenant()
	_test_flame_states()

	print("\n%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)


func _test_field() -> void:
	print("\n--- GF(256) ---")
	# Round-tripping every non-zero element through the tables catches a bad
	# polynomial or generator, which would otherwise only show up as a rare
	# wrong byte.
	var secret := PackedByteArray()
	for i in range(1, 256):
		secret.append(i)
	var fragments := Shamir.split(secret, 3, 2)
	check("splits all 255 non-zero byte values", fragments.size() == 3)
	var restored := Shamir.combine([fragments[0], fragments[2]])
	check("  and restores every one of them", restored == secret)


func _test_split_combine() -> void:
	print("\n--- split / combine ---")
	var secret := "THE WORD KEEPS. THE KEEPER DOES NOT.".to_utf8_buffer()

	for pair: Array in [[2, 2], [3, 2], [5, 3], [10, 7], [16, 16]]:
		var n: int = pair[0]
		var k: int = pair[1]
		var fragments := Shamir.split(secret, n, k)
		if fragments.size() != n:
			check("%d-of-%d splits" % [k, n], false, "got %d fragments" % fragments.size())
			continue
		var chosen: Array[PackedByteArray] = []
		for i in k:
			chosen.append(fragments[i])
		check("%d-of-%d round-trips" % [k, n], Shamir.combine(chosen) == secret)

	var fragments2 := Shamir.split(secret, 4, 2)
	check(
		"a fragment is one byte longer than the secret",
		fragments2[0].size() == secret.size() + 1,
		str(fragments2[0].size())
	)
	check("fragments are numbered from 1", fragments2[0][0] == 1 and fragments2[3][0] == 4)


func _test_subsets() -> void:
	print("\n--- any k of n, not just the first k ---")
	var secret := "I AM THAT I AM".to_utf8_buffer()
	var fragments := Shamir.split(secret, 5, 3)

	# Every 3-subset of 5 must work, not merely the convenient one.
	var ok := true
	var tried := 0
	for a in 5:
		for b in range(a + 1, 5):
			for c in range(b + 1, 5):
				tried += 1
				var chosen: Array[PackedByteArray] = [
					fragments[a], fragments[b], fragments[c]
				]
				if Shamir.combine(chosen) != secret:
					ok = false
	check("all %d subsets of 3-of-5 restore the secret" % tried, ok and tried == 10)

	# Order must not matter either.
	var reversed: Array[PackedByteArray] = [fragments[4], fragments[1], fragments[0]]
	check("fragment order does not matter", Shamir.combine(reversed) == secret)


func _test_below_threshold() -> void:
	print("\n--- below the threshold ---")
	var secret := "LET MY PEOPLE GO".to_utf8_buffer()
	var fragments := Shamir.split(secret, 5, 3)

	# Two of three must not reveal the secret. It returns *a* value — that is
	# the point of the scheme, not a defect — but it must not be the right one.
	var short: Array[PackedByteArray] = [fragments[0], fragments[1]]
	var wrong := Shamir.combine(short)
	check("two of three does not yield the secret", wrong != secret)
	check("  and still returns something the same length", wrong.size() == secret.size())

	var leaks := 0
	for i in secret.size():
		if i < wrong.size() and wrong[i] == secret[i]:
			leaks += 1
	# A handful of coincidental byte matches is expected; wholesale agreement
	# would mean the fragments were leaking the secret directly.
	check(
		"  and does not leak most of the plaintext",
		leaks < secret.size() / 2,
		"%d of %d bytes matched" % [leaks, secret.size()]
	)


func _test_rejections() -> void:
	print("\n--- bad input ---")
	var secret := "x".to_utf8_buffer()

	var e1: Array = []
	check("threshold below 2 rejected", Shamir.split(secret, 5, 1, e1).is_empty())
	check("  with a reason", not e1.is_empty(), str(e1))

	var e2: Array = []
	check("threshold above count rejected", Shamir.split(secret, 2, 3, e2).is_empty())
	check("empty secret rejected", Shamir.split(PackedByteArray(), 3, 2).is_empty())
	check("too many fragments rejected", Shamir.split(secret, 300, 2).is_empty())

	var fragments := Shamir.split("hello".to_utf8_buffer(), 3, 2)
	var e3: Array = []
	var duplicated: Array[PackedByteArray] = [fragments[0], fragments[0]]
	check("duplicate fragments rejected", Shamir.combine(duplicated, e3).is_empty())
	check("  with a reason", not e3.is_empty(), str(e3))

	var e4: Array = []
	var mismatched: Array[PackedByteArray] = [
		fragments[0], Shamir.split("longer secret".to_utf8_buffer(), 3, 2)[1]
	]
	check("fragments from different secrets rejected", Shamir.combine(mismatched, e4).is_empty())

	var e5: Array = []
	var lonely: Array[PackedByteArray] = [fragments[0]]
	check("a single fragment rejected", Shamir.combine(lonely, e5).is_empty())


func _test_hex() -> void:
	print("\n--- fragment transport ---")
	var fragments := Shamir.split("covenant".to_utf8_buffer(), 3, 2)
	var text := Shamir.to_hex(fragments[0])
	check("a fragment encodes to hex", text.length() == fragments[0].size() * 2)
	check("  and decodes back", Shamir.from_hex(text) == fragments[0])
	check("  tolerating whitespace and case", Shamir.from_hex("  " + text.to_upper() + " ") == fragments[0])
	check("garbage rejected", Shamir.from_hex("not hex at all").is_empty())
	check("odd length rejected", Shamir.from_hex("abc").is_empty())


func _test_covenant() -> void:
	print("\n--- covenant ---")
	var covenant := Covenant.new()
	var word := "If I suicide myself, I didn't.\n\nThe rest is in the drawer."

	var sealed := covenant.seal(word, {"threshold": 2, "witnesses": 3})
	check("seals", not sealed.is_empty(), covenant.last_error)
	if sealed.is_empty():
		return

	var tablet: Dictionary = sealed["tablet"]
	var key: PackedByteArray = sealed["key"]

	check("the tablet declares its protocol", str(tablet.get("protocol", "")) == Covenant.PROTOCOL)
	check("the tablet carries its terms", int(tablet.get("threshold", 0)) == 2)
	check("the key is 256-bit", key.size() == 32)
	check(
		"the plaintext is not in the tablet",
		not JSON.stringify(tablet).contains("suicide"),
		"the ciphertext leaked the plaintext"
	)

	check("unseals with the right key", covenant.unseal(tablet, key) == word)

	var wrong := Crypto.new().generate_random_bytes(32)
	check("refuses a wrong key", covenant.unseal(tablet, wrong) == "")
	check("  with a reason", not covenant.last_error.is_empty())
	check("refuses a short key", covenant.unseal(tablet, PackedByteArray([1, 2, 3])) == "")

	# The whole flow, as a witness would actually perform it.
	var fragments := covenant.shatter(key, 4, 2)
	check("shatters into 4", fragments.size() == 4)
	var gathered := covenant.gather([fragments[1], fragments[3]])
	check("two witnesses restore the key", gathered == key)
	check("and the tablet opens", covenant.unseal(tablet, gathered) == word)

	var one: Array[PackedByteArray] = [fragments[0], fragments[0]]
	check("one witness cannot", covenant.gather(one).is_empty())


func _test_flame_states() -> void:
	print("\n--- flame ---")
	var flame := Flame.new(null, "test-root", "sol")
	flame.interval_days = 30
	flame.grace_days = 60
	check("dark after interval plus grace", flame.days_until_dark() == 90)
	check("state names read in the app's voice", Flame.state_name(Flame.State.GUTTERING) == "GUTTERING")

	# Without a host it must refuse cleanly rather than reaching for the chain.
	var status := await flame.read_status()
	check("refuses to read with no host", int(status.get("state", -1)) == Flame.State.UNKNOWN)
	check("  and says why", flame.last_error.contains("host"), flame.last_error)
