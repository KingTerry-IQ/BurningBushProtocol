## Shamir secret sharing over GF(256).
##
## Splits the covenant key into n fragments, of which any k reconstruct it and
## any k-1 reveal nothing at all. That last property is information-theoretic,
## not computational: fewer than k fragments are consistent with every possible
## secret, so no amount of computing power helps.
##
## Used so that no single witness can open a tablet on their own. The key never
## leaves this process — fragments are wrapped for their witnesses afterwards.
##
## Each byte of the secret is split independently. A fragment is one x-coordinate
## byte followed by one y byte per secret byte, so a fragment is always exactly
## one byte longer than the secret.

class_name Shamir
extends RefCounted

## Irreducible polynomial x^8 + x^4 + x^3 + x^2 + 1, with 2 as a generator.
const POLYNOMIAL := 0x11D
const ORDER := 255

## x = 0 is where the secret lives, so fragments are numbered from 1.
const MIN_X := 1
const MAX_X := 255

static var _exp: PackedByteArray = PackedByteArray()
static var _log: PackedByteArray = PackedByteArray()


## Builds the log/antilog tables once. Multiplication in GF(256) is then an
## addition of logarithms, which keeps splitting a large secret cheap.
static func _build_tables() -> void:
	if not _exp.is_empty():
		return

	# Doubled so a log sum up to 508 needs no modulo on the hot path.
	_exp.resize(ORDER * 2)
	_log.resize(256)

	var x := 1
	for i in ORDER:
		_exp[i] = x
		_log[x] = i
		x <<= 1
		if x & 0x100:
			x ^= POLYNOMIAL
	for i in range(ORDER, ORDER * 2):
		_exp[i] = _exp[i - ORDER]


static func _mul(a: int, b: int) -> int:
	if a == 0 or b == 0:
		return 0
	return _exp[_log[a] + _log[b]]


static func _div(a: int, b: int) -> int:
	# Callers never divide by zero: the divisor is always x_j ^ x_i for
	# distinct x, which cannot be zero.
	if a == 0:
		return 0
	return _exp[_log[a] + ORDER - _log[b]]


## Splits `secret` into `count` fragments, any `threshold` of which restore it.
## Returns an empty Array on bad parameters, with the reason in `error`.
static func split(
	secret: PackedByteArray, count: int, threshold: int, error: Array = []
) -> Array[PackedByteArray]:
	var fragments: Array[PackedByteArray] = []

	if secret.is_empty():
		error.append("There is nothing to split.")
		return fragments
	if threshold < 2:
		error.append("A threshold below 2 protects nothing.")
		return fragments
	if count < threshold:
		error.append("Cannot need %d fragments out of only %d." % [threshold, count])
		return fragments
	if count > MAX_X:
		error.append("At most %d fragments." % MAX_X)
		return fragments

	_build_tables()
	var crypto := Crypto.new()

	# One random polynomial per secret byte, with the byte as its constant term.
	# Evaluating at x = 0 therefore returns the byte.
	var coefficients: Array[PackedByteArray] = []
	for i in secret.size():
		var poly := PackedByteArray([secret[i]])
		poly.append_array(crypto.generate_random_bytes(threshold - 1))
		coefficients.append(poly)

	for x in range(MIN_X, MIN_X + count):
		var fragment := PackedByteArray([x])
		for i in secret.size():
			fragment.append(_evaluate(coefficients[i], x))
		fragments.append(fragment)

	return fragments


## Horner evaluation of one polynomial at x.
static func _evaluate(poly: PackedByteArray, x: int) -> int:
	var y := 0
	for i in range(poly.size() - 1, -1, -1):
		y = _mul(y, x) ^ poly[i]
	return y


## Rebuilds the secret from any `threshold` fragments. Returns an empty
## PackedByteArray on failure, with the reason in `error`.
##
## Giving too few fragments does not fail: it returns a wrong secret, because
## every shorter subset is consistent with some secret. That is the security
## property, not a bug, so the caller must know its own threshold.
static func combine(
	fragments: Array[PackedByteArray], error: Array = []
) -> PackedByteArray:
	var secret := PackedByteArray()

	if fragments.size() < 2:
		error.append("At least two fragments are needed.")
		return secret

	var length := fragments[0].size()
	if length < 2:
		error.append("A fragment is malformed.")
		return secret

	var seen := {}
	for fragment: PackedByteArray in fragments:
		if fragment.size() != length:
			error.append("These fragments came from different secrets.")
			return secret
		var x := fragment[0]
		if x < MIN_X:
			error.append("A fragment carries an invalid index.")
			return secret
		if seen.has(x):
			error.append("The same fragment was supplied twice.")
			return secret
		seen[x] = true

	_build_tables()

	# Lagrange interpolation at x = 0. Subtraction is XOR here, so the usual
	# (x_i - x_j) terms are written as (x_i ^ x_j).
	var basis: PackedByteArray = PackedByteArray()
	basis.resize(fragments.size())
	for i in fragments.size():
		var xi: int = fragments[i][0]
		var value := 1
		for j in fragments.size():
			if i == j:
				continue
			var xj: int = fragments[j][0]
			value = _mul(value, _div(xj, xi ^ xj))
		basis[i] = value

	for byte_index in range(1, length):
		var acc := 0
		for i in fragments.size():
			acc ^= _mul(fragments[i][byte_index], basis[i])
		secret.append(acc)

	return secret


## Fragments travel as text, so they are carried as hex with their index first.
static func to_hex(fragment: PackedByteArray) -> String:
	return fragment.hex_encode()


static func from_hex(text: String) -> PackedByteArray:
	var cleaned := text.strip_edges().to_lower()
	if cleaned.length() < 4 or cleaned.length() % 2 != 0:
		return PackedByteArray()
	var out := PackedByteArray()
	for i in range(0, cleaned.length(), 2):
		var pair := cleaned.substr(i, 2)
		if not pair.is_valid_hex_number():
			return PackedByteArray()
		out.append(("0x" + pair).hex_to_int())
	return out
