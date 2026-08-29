# Headless checks for the parts that must not be wrong.
#
# Shamir gets the most attention: a splitting bug that still round-trips on the
# happy path would silently produce a covenant nobody can ever open, and there
# is no way to find that out later — the tablet is already permanent.
#
# Run: Godot --headless --path . --script res://tools/bbp_selftest.gd
extends SceneTree

var failures := 0

## The suite's own index, so a real keeper's covenant list is never touched.
const TEST_INDEX := "user://selftest_ark.json"


func _clear_test_index() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_INDEX))


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
	_test_tablet()
	_test_ark()
	_test_registry()
	_test_browse()
	_test_timelock()
	_test_grace()
	_test_release_coherence()

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


func _test_tablet() -> void:
	print("\n--- tablet ---")
	var tablet := Tablet.new()
	tablet.id = "the drawer_112233"
	tablet.title = "the drawer"
	tablet.chain = "mon"
	tablet.db_root_id = "bbp-root"
	tablet.release = Tablet.Release.WITNESSES | Tablet.Release.PUBLIC_BURN
	tablet.threshold = 2
	tablet.witness_count = 4
	tablet.payload_kind = Tablet.Payload.FILE
	tablet.filename = "will.pdf"
	tablet.filetype = "pdf"
	tablet.burn_key_hex = "aabb"
	tablet.iv_hex = "00112233445566778899aabbccddeeff"
	tablet.ciphertext_b64 = "Zm9v"

	check("both release modes register", tablet.has(Tablet.Release.WITNESSES)
		and tablet.has(Tablet.Release.PUBLIC_BURN))
	check("a witnesses-only tablet is not a burn",
		not Tablet.new().has(Tablet.Release.PUBLIC_BURN))
	check("release reads in words", tablet.release_phrase().contains("2 of 4")
		and tablet.release_phrase().contains("anyone"), tablet.release_phrase())
	check("a tablet with no release says so",
		Tablet.from_record({"release": 0}).release_phrase().contains("never"))
	check("the caveat fires for a public burn", tablet.release_caveat().contains("convention"))

	# Table names become on-chain seeds, so they must be safe and stable.
	check("flame table is slugged", tablet.flame_table() == "flame_the_drawer_112233",
		tablet.flame_table())
	check("slug strips punctuation", Tablet.slug("a b/c!d") == "a_b_c_d", Tablet.slug("a b/c!d"))

	var restored := Tablet.from_record(tablet.to_record())
	check("record round-trips the chain", restored.chain == "mon")
	check("  the release mask", restored.release == tablet.release)
	check("  the threshold", restored.threshold == 2 and restored.witness_count == 4)
	check("  the file details", restored.filename == "will.pdf" and restored.filetype == "pdf")
	check("  the payload kind", restored.payload_kind == Tablet.Payload.FILE)
	check("  the burn key", restored.burn_key_hex == "aabb")
	check("  the ciphertext", restored.ciphertext_b64 == "Zm9v")

	# A witnesses-only tablet must not carry a burn key at all.
	var private_tablet := Tablet.new()
	private_tablet.release = Tablet.Release.WITNESSES
	private_tablet.burn_key_hex = "deadbeef"
	check("a non-burn tablet inscribes no key",
		not private_tablet.to_record().has("burn_key"))

	# The local index keeps the signature but not a second copy of the ciphertext.
	tablet.signature = "sig123"
	var index := tablet.to_index()
	check("the index keeps the signature", str(index.get("signature", "")) == "sig123")
	check("  and drops the ciphertext", not index.has("ciphertext"))


func _test_ark() -> void:
	print("\n--- ark ---")
	# A disposable index: the real one lists a keeper's covenants and must never
	# be deleted by a test run.
	var ark := Ark.new(null)
	ark.index_path = TEST_INDEX
	_clear_test_index()
	ark.load_index()
	check("starts empty", ark.tablets.is_empty())

	var ids: Array[String] = []
	for spec: Array in [["drawer", Flame.State.DARK, 94], ["ellen", Flame.State.GUTTERING, 41],
			["source", Flame.State.BURNING, 3], ["draft", Flame.State.NEVER_LIT, -1]]:
		var t := Tablet.new()
		t.id = Ark.mint_id(spec[0])
		t.title = spec[0]
		ark.add(t)
		ark.states[t.id] = {"state": spec[1], "days_since": spec[2], "days_left": 0}
		ids.append(t.id)

	check("holds four", ark.tablets.size() == 4)
	check("ids are unique", ids[0] != ids[1] and ids[1] != ids[2])
	check("finds by id", ark.find(ids[0]) != null)
	check("misses cleanly", ark.find("nope") == null)

	var dark := ark.dark_tablets()
	check("one is dark", dark.size() == 1 and dark[0].title == "drawer")

	# The living list is the triage order: guttering before burning before unlit.
	var living := ark.living_tablets()
	check("three still kept", living.size() == 3)
	check("  guttering leads", living[0].title == "ellen", living[0].title)
	check("  then burning", living[1].title == "source", living[1].title)
	check("  then never lit", living[2].title == "draft", living[2].title)

	ark.save_index()
	var reloaded := Ark.new(null)
	reloaded.index_path = TEST_INDEX
	reloaded.load_index()
	check("the index persists", reloaded.tablets.size() == 4)
	check("  with titles intact", reloaded.find(ids[0]).title == "drawer")

	reloaded.remove(ids[0])
	check("forgetting drops it locally", reloaded.tablets.size() == 3)
	var after := Ark.new(null)
	after.index_path = TEST_INDEX
	after.load_index()
	check("  and that persists too", after.tablets.size() == 3)

	_clear_test_index()


func _test_registry() -> void:
	print("\n--- registry ---")
	check("one table per keeper, not per covenant", Registry.TABLE_NAME == "covenants")
	check("it carries the signature", Registry.COLUMNS.has("signature"))
	check("  and when it was sealed", Registry.COLUMNS.has("sealed_at"))

	# Newest first, so a survey leads with what was sealed most recently.
	var older := {"sealed_at": 100}
	var newer := {"sealed_at": 200}
	check("sorts newest first", Registry._newest_first(newer, older))
	check("  and not the other way", not Registry._newest_first(older, newer))

	# Without a host it must refuse cleanly rather than reaching for the chain.
	var registry := Registry.new(null, "somebody", "sol")
	check("refuses to list with no host", (await registry.list()).is_empty())
	check("  and says why", registry.last_error.contains("host"), registry.last_error)

	var rootless := Registry.new(null, "", "sol")
	check("refuses an empty root", (await rootless.list()).is_empty())

	# A survey needs a host too, and must not pretend otherwise.
	var ark := Ark.new(null)
	check("survey refuses with no host", (await ark.survey("x", "sol", "")).is_empty())
	check("  and says why", ark.last_error.contains("host"), ark.last_error)


func _test_browse() -> void:
	print("\n--- routes and browsing ---")

	# Every combination must state plainly how it can be opened.
	var burn := Tablet.new()
	burn.release = Tablet.Release.PUBLIC_BURN
	var burn_routes := burn.routes()
	check("a public burn offers one route", burn_routes.size() == 1)
	check("  named as open to anyone", str(burn_routes[0]["kind"]) == "public")

	var shared := Tablet.new()
	shared.release = Tablet.Release.WITNESSES
	shared.threshold = 3
	shared.witness_count = 5
	check("witnesses offer their own route", str(shared.routes()[0]["kind"]) == "witnesses")
	check("  spelling out the count", str(shared.routes()[0]["text"]).contains("3 of 5"))

	var both := Tablet.new()
	both.release = Tablet.Release.PUBLIC_BURN | Tablet.Release.WITNESSES
	check("both modes offer both routes", both.routes().size() == 2)

	var neither := Tablet.new()
	neither.release = Tablet.Release.NONE
	check("no release says so outright", str(neither.routes()[0]["kind"]) == "none")

	# Public listing is a separate decision from how it opens, and must survive
	# the round trip so another machine knows whether to re-list it.
	var listed := Tablet.new()
	listed.release = Tablet.Release.WITNESSES
	listed.public_listing = true
	check("listing is recorded", Tablet.from_record(listed.to_record()).public_listing)
	var quiet := Tablet.new()
	check("and defaults to off", not quiet.public_listing)
	check("  leaving no trace when off", not quiet.to_record().has("public_listing"))

	check("the commons has a fixed root", Registry.COMMONS_ROOT == "burning-bush-commons")
	var commons := Registry.commons(null, "sol")
	check("commons registry knows what it is", commons.is_commons())
	check("a keeper's own does not", not Registry.new(null, "mine", "sol").is_commons())
	check("the row carries a deadline", Registry.COLUMNS.has("dark_after"))
	check("  and who kept it", Registry.COLUMNS.has("keeper"))


func _test_timelock() -> void:
	print("\n--- time lock ---")
	var tablet := Tablet.new()
	tablet.release = Tablet.Release.TIME_LOCK
	tablet.timelock = {"n": "ab", "x": "02", "t": "1000", "estimatedSeconds": 2592000}

	check("time lock is its own mode", tablet.has(Tablet.Release.TIME_LOCK))
	check("  and not mistaken for a public burn", not tablet.has(Tablet.Release.PUBLIC_BURN))
	check("  nor for witnesses", not tablet.has(Tablet.Release.WITNESSES))

	# The open panel builds itself from routes(). It once branched only on
	# public-burn-or-not, so a time-locked covenant asked its reader for
	# fragments that had never been issued to anybody.
	var kinds: Array = []
	for route: Dictionary in tablet.routes():
		kinds.append(str(route["kind"]))
	check("it offers exactly one way in", kinds.size() == 1, ", ".join(kinds))
	check("  and that way is the puzzle", kinds.has("timelock"))
	check("  so nothing can ask for fragments", not kinds.has("witnesses"))

	check("duration reads in days", tablet.timelock_duration() == "30 days", tablet.timelock_duration())
	tablet.timelock["estimatedSeconds"] = 7200
	check("  and in hours", tablet.timelock_duration() == "2 hours", tablet.timelock_duration())
	tablet.timelock["estimatedSeconds"] = 300
	check("  and in minutes", tablet.timelock_duration() == "5 minutes", tablet.timelock_duration())
	tablet.timelock["estimatedSeconds"] = 0
	check("  admitting when it does not know", tablet.timelock_duration().contains("unknown"))

	tablet.timelock["estimatedSeconds"] = 2592000
	var routes := tablet.routes()
	check("it offers a route", routes.size() == 1 and str(routes[0]["kind"]) == "timelock")
	check("  described as work", str(routes[0]["text"]).contains("computing"))

	# The caveat must be the honest one, not the public-burn wording.
	var caveat := tablet.release_caveat()
	check("the caveat says the clock starts early", caveat.contains("clock starts"))
	check("  and that it is a floor", caveat.contains("floor"))

	# All three modes together, which is legal and should read cleanly.
	var everything := Tablet.new()
	everything.release = (
		Tablet.Release.WITNESSES | Tablet.Release.PUBLIC_BURN | Tablet.Release.TIME_LOCK
	)
	everything.threshold = 2
	everything.witness_count = 3
	everything.timelock = {"estimatedSeconds": 86400}
	check("three modes give three routes", everything.routes().size() == 3)
	check("  and the phrase mentions all of them",
		everything.release_phrase().contains("witnesses")
		and everything.release_phrase().contains("anyone")
		and everything.release_phrase().contains("work"),
		everything.release_phrase())

	# The puzzle must survive the round trip: it is the only copy.
	var restored := Tablet.from_record(tablet.to_record())
	check("the puzzle round-trips", str(restored.timelock.get("n", "")) == "ab")
	check("  keeping its difficulty", str(restored.timelock.get("t", "")) == "1000")

	var without := Tablet.new()
	without.release = Tablet.Release.WITNESSES
	without.timelock = {"n": "leak"}
	check("a tablet without the mode inscribes no puzzle", not without.to_record().has("timelock"))


func _test_grace() -> void:
	print("\n--- grace ---")
	# The question this answers: what does splitting 90 into 30+60 actually buy?
	check("release is only ever at the deadline",
		Flame.releasable(Flame.State.DARK)
		and not Flame.releasable(Flame.State.GUTTERING)
		and not Flame.releasable(Flame.State.BURNING))
	check("  and never on an unreadable flame",
		not Flame.releasable(Flame.State.UNKNOWN)
		and not Flame.releasable(Flame.State.NEVER_LIT))

	# Both configurations release at the same moment; only the warning differs.
	var split := Flame.new(null, "r", "sol")
	split.interval_days = 30
	split.grace_days = 60
	var blunt := Flame.new(null, "r", "sol")
	blunt.interval_days = 90
	blunt.grace_days = 1
	check("30+60 and 90+1 release within a day of each other",
		absi(split.days_until_dark() - blunt.days_until_dark()) <= 1,
		"%d vs %d" % [split.days_until_dark(), blunt.days_until_dark()])
	check("  but only the split one warns early",
		split.interval_days < split.days_until_dark()
		and blunt.interval_days >= blunt.days_until_dark() - 1)


func _test_release_coherence() -> void:
	print("\n--- release combinations ---")
	var W := Tablet.Release.WITNESSES
	var B := Tablet.Release.PUBLIC_BURN
	var T := Tablet.Release.TIME_LOCK

	# A public burn publishes the key, so anything paired with it guards
	# nothing. Alone it is a deliberate choice; combined it is a mistake.
	check("witnesses alone", Tablet.release_is_coherent(W))
	check("puzzle alone", Tablet.release_is_coherent(T))
	check("open-to-anyone alone", Tablet.release_is_coherent(B))
	check("witnesses and puzzle together", Tablet.release_is_coherent(W | T))

	check("open-to-anyone plus witnesses is refused", not Tablet.release_is_coherent(B | W))
	check("open-to-anyone plus puzzle is refused", not Tablet.release_is_coherent(B | T))
	check("all three is refused", not Tablet.release_is_coherent(B | W | T))
	check("nothing at all is refused", not Tablet.release_is_coherent(Tablet.Release.NONE))
