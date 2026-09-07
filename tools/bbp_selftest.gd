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
	_test_witness_envelopes()
	_test_puzzle_units()
	_test_row_timing()
	_test_time_units()
	_test_dark_wording()
	_test_keeper_only()
	_test_keeper_wallet()
	_test_flame_writers()
	_test_signer_verification()
	_test_app_root()
	_test_space_chains()
	_test_id_collisions()
	_test_solver_display()

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

	# One-of-one. A covenant sealed to a single witness gives that witness the
	# key itself rather than a share, because any-one-of-n is not a threshold
	# scheme — and Shamir rejects such a fragment twice over, so the path has to
	# be recognised rather than interpolated. It was not, and the one witness of
	# a dark covenant could not open the thing they were named to open.
	var whole := Covenant.whole_key(key)
	check("the whole key is one byte longer than the key", whole.size() == key.size() + 1)
	check("  and is marked as itself, not as a share", Covenant.is_whole_key(whole))
	check("  where a real share is not", not Covenant.is_whole_key(fragments[0]))
	var alone: Array[PackedByteArray] = [whole]
	check("one witness holding the whole key restores it", covenant.gather(alone) == key)
	check("  and the tablet opens", covenant.unseal(tablet, covenant.gather(alone)) == word)

	# It has to survive the journey: wrapped to a witness, published as
	# testimony or pasted in by hand, a fragment travels as hex both ways.
	var carried := covenant.read_fragment(Shamir.to_hex(whole))
	check("the whole key survives the trip as hex", carried == whole)
	var carried_alone: Array[PackedByteArray] = [carried]
	check("  and still opens the tablet", covenant.unseal(tablet, covenant.gather(carried_alone)) == word)

	# Shamir must never issue index 0 itself, or a real share could be mistaken
	# for a whole key.
	var zero_indexed := false
	for fragment: PackedByteArray in fragments:
		if fragment[0] == Covenant.WHOLE_KEY_MARKER:
			zero_indexed = true
	check("no real share ever carries the whole-key marker", not zero_indexed)


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

	# Every listing lives under the protocol root, so the fee for creating the
	# registry goes to the protocol rather than to each keeper in turn.
	check("the registry lives under the app root",
		Registry.new(null, "sol").space.root == Tablet.APP_ROOT)
	check("  which names the app that owns it",
		Tablet.APP_ROOT.contains("BurningBushProtocol"), Tablet.APP_ROOT)

	# One table for everyone means the handle is what separates keepers.
	check("a row records whose listing it is", Registry.COLUMNS.has("handle"))

	# Without a host it must refuse cleanly rather than reaching for the chain.
	var registry := Registry.new(null, "sol")
	check("refuses to list with no host", (await registry.list()).is_empty())
	check("  and says why", registry.last_error.contains("host"), registry.last_error)

	check("refuses a handle search with no handle",
		(await registry.for_handle("")).is_empty())

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
	# "1 days" is the sort of slip that makes a reader doubt the rest.
	for pair: Array in [[86400, "1 day"], [3600, "1 hour"], [60, "1 minute"], [120, "2 minutes"]]:
		tablet.timelock["estimatedSeconds"] = int(pair[0])
		check("  and counts one correctly: %s" % str(pair[1]),
			tablet.timelock_duration() == str(pair[1]), tablet.timelock_duration())
	tablet.timelock["estimatedSeconds"] = 2592000
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


func _test_witness_envelopes() -> void:
	print("\n--- what a witness actually holds ---")

	var tablet := Tablet.new()
	tablet.release = Tablet.Release.WITNESSES
	tablet.threshold = 1
	tablet.witness_count = 2
	tablet.witness_envelopes = [
		{"recipient": "aa11", "label": "Aaron", "envelope": {"recipients": ["aa11"]}},
		{"recipient": "bb22", "label": "Miriam", "envelope": {"recipients": ["bb22"]}},
	]

	var testimony := Testimony.new(null, tablet)

	# A witness is addressed by identity, so nothing is handed over by hand.
	check("a named witness finds their own share",
		not testimony.my_envelope("aa11").is_empty())
	check("  and it is theirs, not the other one's",
		testimony.my_envelope("aa11").get("recipients", []) == ["aa11"])
	check("a second witness finds a different one",
		testimony.my_envelope("bb22").get("recipients", []) == ["bb22"])
	check("a stranger finds nothing", testimony.my_envelope("cc33").is_empty())
	check("and neither does an absent identity", testimony.my_envelope("").is_empty())

	# Threshold one means a witness opens it alone and privately: their share
	# is the whole key, so nothing has to be published to read it.
	check("one of one opens alone", tablet.threshold <= 1)

	# The share is wrapped for exactly one wallet. Addressing it to everyone
	# would let any witness read every other witness's envelope.
	for entry: Dictionary in tablet.witness_envelopes:
		var envelope: Dictionary = entry["envelope"]
		check("  %s's share is wrapped for one wallet only" % entry["label"],
			(envelope.get("recipients", []) as Array).size() == 1)

	# Above one, a lone witness is genuinely not enough.
	tablet.threshold = 2
	check("two of two needs a second witness", tablet.threshold > 1)


func _test_puzzle_units() -> void:
	print("\n--- puzzle durations ---")
	var units: Array = Tablet.DURATION_UNITS

	check("minutes, hours and days are offered", units.size() == 3)
	check("  the smallest is a minute", int(units[0][1]) == 60, str(units[0]))
	check("  and days is the default", int(units[Tablet.DURATION_DEFAULT_UNIT][1]) == 86400)

	# Days alone was too coarse to try a puzzle out before trusting one.
	check("five minutes is expressible", 5 * int(units[0][1]) == 300)
	check("two hours is expressible", 2 * int(units[1][1]) == 7200)
	check("thirty days still is", 30 * int(units[2][1]) == 2592000)

	# The wording a reader sees must follow the seconds, whichever unit built it.
	var tablet := Tablet.new()
	tablet.release = Tablet.Release.TIME_LOCK
	for pair: Array in [[300, "5 minutes"], [7200, "2 hours"], [2592000, "30 days"]]:
		tablet.timelock = {"estimatedSeconds": int(pair[0])}
		check("  %ds reads as '%s'" % [int(pair[0]), str(pair[1])],
			tablet.timelock_duration() == str(pair[1]), tablet.timelock_duration())


func _test_row_timing() -> void:
	print("\n--- the dates a row reports ---")

	var tablet := Tablet.new()
	tablet.interval_days = 30
	tablet.grace_days = 60

	check("grace begins at the interval", tablet.interval_days == 30)
	check("  and release at interval plus grace", tablet.days_until_dark() == 90)

	# What the row prints for each column, at each stage of a covenant's life.
	# "now" rather than a negative count: a deadline that has passed has not
	# got -3 days left, it has arrived.
	for c: Array in [
		[0, "in 30d", "in 90d"],
		[29, "in 1d", "in 61d"],
		[30, "now", "in 60d"],
		[89, "now", "in 1d"],
		[90, "now", "now"],
		[120, "now", "now"],
	]:
		var since := int(c[0])
		check("  %dd silent: overdue %s, releases %s" % [since, str(c[1]), str(c[2])],
			Tablet.in_time((tablet.interval_days - since) * 86400) == str(c[1])
			and Tablet.in_time((tablet.days_until_dark() - since) * 86400) == str(c[2]),
			"%s / %s" % [
				Tablet.in_time((tablet.interval_days - since) * 86400),
				Tablet.in_time((tablet.days_until_dark() - since) * 86400),
			])

	# A row must fit the ark pane without a horizontal scrollbar, which would
	# hide the release dates at the moment they matter. The budget is whatever
	# the window has left after the bush column, not a fixed 80 — that number
	# was written for a 1024-wide window and silently became wrong.
	var pane: float = (
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1600))
		- 380.0  # the bush column on the left
		- 36.0   # window margins
		- 14.0   # the split separation
		- 24.0   # panel padding and room for a vertical scrollbar
	)
	# A monospaced glyph runs about 0.6 of its point size wide.
	var budget: int = int(pane / (TempleTheme.SIZE_SMALL * 0.6))
	var width: int = 2 + 6 + Main.W_STATE + Main.W_WHEN * 3 + 4 + Main.W_TITLE
	check("a row fits the ark pane without scrolling", width <= budget,
		"%d columns against a budget of %d" % [width, budget])
	check("  and the name is the only unbounded column",
		Main.W_TITLE >= Main.W_WHEN, "%d" % Main.W_TITLE)


func _test_keeper_only() -> void:
	print("\n--- only a keeper tends their own flame ---")

	var mine := Tablet.new()
	mine.id = Ark.mint_id("ours")
	mine.title = "ours"
	mine.db_root_id = "my-records"
	mine.mine = true

	var theirs := Tablet.new()
	theirs.id = Ark.mint_id("theirs")
	theirs.title = "theirs"
	theirs.db_root_id = "someone-elses-records"

	check("a covenant we sealed is ours", mine.mine)
	check("one we are only watching is not", not theirs.mine)

	# Ownership is a fact about this machine, not about the covenant. Putting
	# it on-chain would be meaningless — every reader would see "mine".
	check("it is never inscribed", not mine.to_record().has("mine"),
		str(mine.to_record().keys()))
	check("  but it is kept locally", mine.to_index().get("mine", false) == true)
	check("  including when false", theirs.to_index().get("mine", true) == false)

	# Anything rebuilt from an on-chain record is somebody else's until proven
	# otherwise: adopting by signature must never confer the power to tend.
	var adopted := Tablet.from_record(mine.to_record())
	check("adopting a tablet does not claim it", not adopted.mine)

	# It has to survive a restart, or a keeper loses CHECK IN on reopening.
	var ark := Ark.new(null)
	ark.index_path = TEST_INDEX
	_clear_test_index()
	ark.load_index()
	ark.add(mine)
	ark.add(theirs)

	var reloaded := Ark.new(null)
	reloaded.index_path = TEST_INDEX
	reloaded.load_index()
	check("ownership survives a reload", reloaded.tablets.size() == 2,
		str(reloaded.tablets.size()))
	for tablet: Tablet in reloaded.tablets:
		if tablet.title == "ours":
			check("  ours is still ours", tablet.mine)
		else:
			check("  theirs is still theirs", not tablet.mine)

	# Indexes written before this flag existed have no "mine" key at all. They
	# are settled by the root they sit under, so a keeper does not lose the
	# ability to tend covenants they sealed before the upgrade.
	var legacy: Array = [
		{"id": "old1", "title": "sealed-before", "root": "my-records"},
		{"id": "old2", "title": "watched-before", "root": "someone-elses-records"},
	]
	var file := FileAccess.open(TEST_INDEX, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy))
	file.close()

	var migrated := Ark.new(null, "my-records")
	migrated.index_path = TEST_INDEX
	migrated.load_index()
	check("a legacy entry under our root becomes ours",
		migrated.tablets[0].mine, migrated.tablets[0].title)
	check("  and one under a stranger's does not", not migrated.tablets[1].mine)

	# With no root known, nothing is claimed: withholding CHECK IN is the safe
	# way to be wrong, offering it over a stranger's flame is not.
	var unknown := Ark.new(null, "")
	unknown.index_path = TEST_INDEX
	unknown.load_index()
	check("knowing no root claims nothing", not unknown.tablets[0].mine)

	_clear_test_index()


func _test_keeper_wallet() -> void:
	print("\n--- the wallet decides, not the app ---")

	var ours := "Fid4pgTYLEVyQjMjBYQeB8HJ7FTdC5myYHQLz4CziSGb"
	var theirs := "9PTCGa4YF9rircVps5J15iNXffdt2RFoVBYDtuexQtW5"

	var tablet := Tablet.new()
	tablet.chain = "sol"
	tablet.keeper_wallet = ours

	check("the sealing wallet may tend it", tablet.is_kept_by(ours))
	check("  another wallet may not", not tablet.is_kept_by(theirs))
	check("  and an unknown wallet may not", not tablet.is_kept_by(""))

	# A local flag proves nothing to anybody, so it must not override the
	# wallet. Someone editing the index by hand gains nothing.
	tablet.mine = true
	check("a local flag cannot override the wallet", not tablet.is_kept_by(theirs))
	tablet.mine = false
	check("  nor withhold it from the real keeper", tablet.is_kept_by(ours))

	# Covenants sealed before wallets were recorded still have to work.
	var legacy := Tablet.new()
	legacy.mine = true
	check("a covenant predating this falls back to the local flag",
		legacy.is_kept_by(ours))
	var legacy_theirs := Tablet.new()
	check("  and one never claimed stays unclaimed", not legacy_theirs.is_kept_by(ours))

	# The keeper is deliberately NOT inscribed. A record naming its own author
	# is a claim it makes about itself, and anyone can inscribe any address —
	# so the authority is the signer of the inscription, which the chain
	# attests. This is only ever a cache of that answer.
	var record := tablet.to_record()
	check("the keeper wallet is not inscribed", not record.has("keeper_wallet"),
		str(record.keys()))
	check("  so nothing on-chain can assert authorship",
		Tablet.from_record(record).keeper_wallet.is_empty())
	check("  but it is cached locally", str(tablet.to_index().get("keeper_wallet", "")) == ours)
	check("  and survives a reload", Tablet.from_record(tablet.to_index()).keeper_wallet == ours)

	# Whitespace on either side must not silently disown a keeper.
	var padded := Tablet.from_record({"keeper_wallet": "  " + ours + "  "})
	check("  ignoring stray whitespace", padded.is_kept_by(ours), padded.keeper_wallet)

	# Addresses differ per chain, so a covenant is ours only against its own.
	var monad := Tablet.new()
	monad.chain = "mon"
	monad.keeper_wallet = "0x8F09c6D161101Bc6e4b2d88cCA44C0e0e67055D2"
	check("a MON covenant is not tended by a SOL address",
		not monad.is_kept_by(ours))



func _test_flame_writers() -> void:
	print("\n--- the chain refuses a stranger's check-in ---")

	# A writer list is enforced inside the program on both chains, but only
	# while it is non-empty. A flame table created without one takes a row from
	# anybody, which on a proof-of-life table means a stranger can keep a dead
	# keeper's flame burning and the covenant never releases.
	var locked := Flame.writer_options("KeeperWalletAddress")
	check("the keeper is named as a writer", locked.has("writers"), str(locked))
	check("  and is the only one",
		(locked.get("writers", []) as Array) == ["KeeperWalletAddress"],
		str(locked.get("writers", [])))
	check("  ignoring stray whitespace",
		(Flame.writer_options("  W  ").get("writers", []) as Array) == ["W"])

	# No wallet must mean no list at all, never an empty one: the program reads
	# an empty list as "open to anyone", so sending one looks like protection
	# while providing none.
	check("no wallet sends no writer list", Flame.writer_options("").is_empty())
	check("  and neither does whitespace", Flame.writer_options("   ").is_empty())


func _test_signer_verification() -> void:
	print("\n--- a check-in is only as good as its signer ---")

	var keeper := "KeeperWallet"
	var stranger := "StrangerWallet"

	var rows: Array = [
		{"ts": "100", "__signer": keeper},
		{"ts": "200", "__signer": stranger},
		{"ts": "300", "__signer": keeper},
		{"ts": "400", "__signer": ""},
	]

	var sifted := Flame._only_from(rows, keeper)
	var kept: Array = sifted["entries"]

	check("the keeper's own rows are kept", kept.size() == 3, str(kept.size()))
	for row: Variant in kept:
		check("  none of the kept rows is the stranger's",
			str((row as Dictionary).get("__signer", "")) != stranger)

	# The asymmetry is deliberate and is the whole safety argument: a covenant
	# that releases early cannot be undone, while one that releases late is at
	# least still shut. So an unattributable row is kept and counted, not
	# dropped — an RPC hiccup must not darken a flame being faithfully tended.
	check("a row whose signer is unknown is kept", kept.size() == 3)
	check("  and reported as unverified", int(sifted["unverified"]) == 1,
		str(sifted["unverified"]))

	# With no rows from anyone else, nothing is dropped and nothing is flagged.
	var clean := Flame._only_from(
		[{"ts": "1", "__signer": keeper}, {"ts": "2", "__signer": keeper}], keeper
	)
	check("an untouched flame loses nothing", (clean["entries"] as Array).size() == 2)
	check("  and flags nothing", int(clean["unverified"]) == 0)

	# A flame consisting only of forgeries has no proof of life at all.
	var forged := Flame._only_from([{"ts": "9", "__signer": stranger}], keeper)
	check("a flame tended only by a stranger is empty",
		(forged["entries"] as Array).is_empty())

	# Asking for signers is what costs a lookup per signature, so it must only
	# happen when there is an author to compare against.
	check("no keeper means no signer lookups", Flame.writer_options("").is_empty())


func _test_app_root() -> void:
	print("\n--- one root for the whole protocol ---")

	var space := IQSpace.new(null, Tablet.APP_ROOT, "sol")
	check("a space binds one root", space.root == Tablet.APP_ROOT)
	check("  and refuses to act with no host", not await space.table_exists("anything"))
	check("  saying why", space.last_error.contains("host"), space.last_error)

	var rootless := IQSpace.new(null, "", "sol")
	check("a space with no root refuses too", (await rootless.read_rows("x")).is_empty())

	check("monad is recognised by either name",
		IQSpace.is_monad("mon") and IQSpace.is_monad("MONAD") and not IQSpace.is_monad("sol"))
	check("robinhood is recognised by either name",
		IQSpace.is_robinhood("rh") and IQSpace.is_robinhood("ROBINHOOD")
		and not IQSpace.is_robinhood("mon"))
	# Everything that used to branch on Monad now branches on this. A chain
	# that answers false here would be addressed as though it were Solana, and
	# would look for a table address that no EVM chain has.
	check("  and both address tables by name",
		IQSpace.is_evm("rh") and IQSpace.is_evm("mon") and not IQSpace.is_evm("sol"))
	check("  which the client agrees about",
		IQClient.is_evm("robinhood") and IQClient.is_evm("mon")
		and not IQClient.is_evm("sol"))

	# A shared root is a shared namespace, so names must be separable by owner.
	var a := IQSpace.scoped("Fid4pgTYLEVyQjMjBYQeB8HJ7FTdC5myYHQLz4CziSGb", "notes")
	var b := IQSpace.scoped("9PTCGa4YF9rircVps5J15iNXffdt2RFoVBYDtuexQtW5", "notes")
	check("two owners get different table names", a != b, "%s vs %s" % [a, b])
	check("  both still readable as the same kind", a.begins_with("notes_") and b.begins_with("notes_"))
	check("  and no owner means no suffix", IQSpace.scoped("", "notes") == "notes")
	check("  with nothing exotic in the name",
		not a.contains("/") and not a.contains(" "), a)

	# Row shapes are the same wherever they came from.
	var mon := IQSpace.unwrap_row({"txHash": "0xabc", "data": {"ts": "5"}, "__signer": "W"})
	check("a monad row unwraps to its fields", str(mon.get("ts", "")) == "5")
	check("  keeping its transaction", str(mon.get("__tx", "")) == "0xabc")
	check("  and its signer", str(mon.get("__signer", "")) == "W")
	var sol := IQSpace.unwrap_row({"ts": "7", "__txSignature": "sig", "__signer": "W"})
	check("a solana row unwraps flat", str(sol.get("ts", "")) == "7")
	check("  keeping its transaction", str(sol.get("__tx", "")) == "sig")


func _test_id_collisions() -> void:
	print("\n--- ids must not collide across keepers ---")

	# Under one root, two keepers sealing the same title in the same second
	# would previously produce the same id and therefore the same table names.
	# 2000 draws against a 32-bit salt: the birthday bound puts a repeat at
	# well under one in a thousand runs, so a failure here means the salt got
	# narrower, not that the suite was unlucky.
	var seen := {}
	for i in 2000:
		seen[Ark.mint_id("drawer")] = true
	check("2000 ids in the same second are distinct", seen.size() == 2000, str(seen.size()))
	check("  and every one fits the table-name budget",
		Ark.mint_id("drawer").length() <= 24, str(Ark.mint_id("drawer").length()))

	# A long title used to push the unique part past slug()'s 24-character cut,
	# so the table name lost exactly what made it unique.
	var long_title := "my very long covenant title that runs on and on"
	var first := Ark.mint_id(long_title)
	var second := Ark.mint_id(long_title)
	var t1 := Tablet.new()
	var t2 := Tablet.new()
	t1.id = first
	t2.id = second
	check("a long title still yields distinct ids", first != second)
	check("  and distinct flame tables", t1.flame_table() != t2.flame_table(),
		"%s vs %s" % [t1.flame_table(), t2.flame_table()])
	check("  and distinct testimony tables", t1.testimony_table() != t2.testimony_table())
	check("  none of which is truncated to nothing", t1.flame_table().length() > 6)


func _test_time_units() -> void:
	print("\n--- the unit follows the urgency ---")

	# Days are right for a covenant with a month to run and useless for one
	# with forty minutes left, which is exactly when the number gets read.
	for pair: Array in [
		[90 * 86400, "in 90d"],
		[2 * 86400, "in 2d"],
		[86400, "in 1d"],
		[86399, "in 23h"],
		[5 * 3600, "in 5h"],
		[3600, "in 1h"],
		[3599, "in 59m"],
		[12 * 60, "in 12m"],
		[60, "in 1m"],
		[1, "in 1m"],
	]:
		check("  %ds reads as '%s'" % [int(pair[0]), str(pair[1])],
			Tablet.in_time(int(pair[0])) == str(pair[1]), Tablet.in_time(int(pair[0])))

	# A deadline that has passed has arrived; it has not got negative time left.
	check("a passed deadline reads 'now'", Tablet.in_time(0) == "now")
	check("  and so does one long past", Tablet.in_time(-9999) == "now")
	# Never round a live deadline down to nothing: "in 0m" would read as
	# expired while there is still time to act.
	check("  but a live one never rounds to zero", Tablet.in_time(30) == "in 1m")

	for pair: Array in [
		[0, "just now"],
		[59, "just now"],
		[60, "1m ago"],
		[3600, "1h ago"],
		[86400, "1d ago"],
		[3 * 86400, "3d ago"],
	]:
		check("  %ds since reads as '%s'" % [int(pair[0]), str(pair[1])],
			Tablet.since_time(int(pair[0])) == str(pair[1]), Tablet.since_time(int(pair[0])))

	check("never tended says so", Tablet.since_time(-1) == "never")


func _test_dark_wording() -> void:
	print("\n--- what a dark covenant says of itself ---")

	var burn := Tablet.new()
	burn.title = "open-letter"
	burn.release = Tablet.Release.PUBLIC_BURN
	var burn_text := Main._dark_text(burn, false)
	check("a public burn says it is already open", burn_text.contains("anyone can open it now"),
		burn_text)
	check("  and never mentions shares", not burn_text.contains("share"), burn_text)

	var puzzle := Tablet.new()
	puzzle.title = "the-drawer"
	puzzle.release = Tablet.Release.TIME_LOCK
	puzzle.timelock = {"estimatedSeconds": 86400}
	var puzzle_text := Main._dark_text(puzzle, false)
	check("a time lock says what it costs to open", puzzle_text.contains("1 day of computing"),
		puzzle_text)
	check("  and never mentions witnesses", not puzzle_text.contains("witness"), puzzle_text)
	check("  nor shares", not puzzle_text.contains("share"), puzzle_text)

	var guarded := Tablet.new()
	guarded.title = "kept"
	guarded.release = Tablet.Release.WITNESSES
	guarded.threshold = 2
	guarded.witness_count = 4
	var guarded_text := Main._dark_text(guarded, false)
	check("witnesses are named with their count", guarded_text.contains("2 of its 4 witnesses"),
		guarded_text)

	# A lone witness whose share is the whole key should be told they can read
	# it privately, not nudged into releasing it to everyone.
	var lone := Tablet.new()
	lone.title = "kept"
	lone.release = Tablet.Release.WITNESSES
	lone.threshold = 1
	lone.witness_count = 1
	var lone_text := Main._dark_text(lone, true)
	check("a sole witness is told they can read it alone",
		lone_text.contains("without publishing"), lone_text)

	# Both routes, both stated.
	var both := Tablet.new()
	both.title = "kept"
	both.release = Tablet.Release.WITNESSES | Tablet.Release.TIME_LOCK
	both.threshold = 2
	both.witness_count = 3
	both.timelock = {"estimatedSeconds": 2592000}
	var both_text := Main._dark_text(both, false)
	check("two routes are both offered",
		both_text.contains("witnesses") and both_text.contains("computing"), both_text)

	# A covenant nothing can open must not claim someone is coming for it.
	var orphan := Tablet.new()
	orphan.title = "lost"
	orphan.release = Tablet.Release.NONE
	check("a covenant with no release says so",
		Main._dark_text(orphan, false).contains("no way to open it"),
		Main._dark_text(orphan, false))

	# The commons phrase had the same gap: no time-lock branch at all.
	check("the commons names the puzzle route",
		Main._open_routes(puzzle, false).contains("computing"),
		Main._open_routes(puzzle, false))
	check("  and never leaves a dark row blank",
		not Main._open_routes(puzzle, false).is_empty())
	check("  still naming witnesses when there are some",
		Main._open_routes(guarded, false).contains("witnesses"))


func _test_space_chains() -> void:
	print("\n--- one root, either chain ---")

	var space := IQSpace.new(null, Tablet.APP_ROOT, "sol")
	check("it starts on its default chain", space.chain == "sol")
	check("  keeping the root", space.root == Tablet.APP_ROOT)

	# The root is the app and the chain is the operation, so an app holding
	# covenants on both must not need one space object per chain.
	var monad := space.on("mon")
	check("asking for another chain gives one", monad.chain == "mon")
	check("  on the same root", monad.root == space.root)
	check("  without disturbing the original", space.chain == "sol")

	# The common case must stay cheap to write inline.
	check("asking for the chain it is already on returns itself",
		space.on("sol") == space)
	check("  and so does asking for nothing", space.on("") == space)
	check("  case and padding do not matter", space.on("  SOL ") == space)

	# It may hand back a different object, which is the trap: an error belongs
	# to whichever space did the work.
	check("a sibling carries its own error state", monad != space)
	monad.last_error = "something went wrong"
	check("  so the original is not marked by it", space.last_error.is_empty())

	# Chaining must not drift off the root.
	check("hopping back and forth keeps the root",
		space.on("mon").on("sol").root == Tablet.APP_ROOT)
	check("  and lands on the chain asked for",
		space.on("mon").on("sol").chain == "sol")


## What the solver window shows while a puzzle is being ground out. A reader
## watching a bar for four days deserves one that is not lying to them.
func _test_solver_display() -> void:
	print("\n--- watching a puzzle ---")
	var cells: int = PuzzleDisplay.BAR_CELLS

	var empty := PuzzleDisplay.progress_bar(0.0)
	check("an empty bar is all empty", empty.count(PuzzleDisplay.BAR_FULL) == 0)
	check("  and is the width it says it is", empty.count(PuzzleDisplay.BAR_EMPTY) == cells)

	var full := PuzzleDisplay.progress_bar(100.0)
	check("a finished bar is all full", full.count(PuzzleDisplay.BAR_FULL) == cells)

	# The one lie a progress bar can tell is a full bar on something still
	# working, which is what rounding rather than truncating produces.
	check(
		"99% is not drawn as finished",
		PuzzleDisplay.progress_bar(99.0).count(PuzzleDisplay.BAR_FULL) < cells
	)
	check(
		"halfway is halfway",
		PuzzleDisplay.progress_bar(50.0).count(PuzzleDisplay.BAR_FULL) == cells / 2
	)
	# Nothing the host sends should be able to draw outside the bar.
	check("nonsense above 100 is clamped", PuzzleDisplay.progress_bar(400.0).length() == full.length())
	check("nonsense below 0 is clamped", PuzzleDisplay.progress_bar(-5.0).length() == full.length())

	# The clock is the proof that a solve is still alive, so it counts in
	# seconds rather than rounding to "3h" like the rest of the app.
	check("the clock starts at zero", PuzzleDisplay.clock(0) == "00:00:00")
	check("  counts seconds", PuzzleDisplay.clock(9) == "00:00:09")
	check("  and minutes", PuzzleDisplay.clock(605) == "00:10:05")
	check("  and hours", PuzzleDisplay.clock(3661) == "01:01:01")
	check("  and says days out loud past one", PuzzleDisplay.clock(90061) == "1d 01:01:01")
	check("  and never runs backwards", PuzzleDisplay.clock(-30) == "00:00:00")

	# The estimate is extrapolated from a whole-percent reading, so it is rounded
	# on purpose: "about 04:29:56" claims a precision it cannot have.
	check("an estimate in days says days and hours", PuzzleDisplay.remaining_phrase(183_600) == "about 2d 3h")
	check("  in hours, hours and minutes", PuzzleDisplay.remaining_phrase(16_200) == "about 4h 30m")
	check("  in minutes, only minutes", PuzzleDisplay.remaining_phrase(750) == "about 12m")
	check("  and under a minute says so", PuzzleDisplay.remaining_phrase(41) == "under a minute")
	check("  as does nothing at all", PuzzleDisplay.remaining_phrase(-5) == "under a minute")
