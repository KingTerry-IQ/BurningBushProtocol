## What things cost, in the chain's own token.
##
## Kept in one place and stated as numbers rather than comparisons: "more
## expensive" tells nobody whether they can afford it.
##
## These mirror the estimates GodOnChain shows on its approval prompt. Reading
## is always free; only writes cost anything, and a write costs essentially the
## same whatever it carries until the payload gets very large.

class_name Costs
extends RefCounted

## Solana: a base transaction plus a trivial per-chunk fee.
const SOL_BASE := 0.005105
const SOL_PER_CHUNK := 0.000005
const SOL_CHUNK_BYTES := 850

## Monad, from the IQ Labs docs. The fee depends on which call is made and on
## how much data it carries, not on a single flat rate:
##
##   createTable   19.5 MON, always
##   writeRow      6.5 MON inline, 19.5 once the payload exceeds the inline
##                 limit and has to be chunked
##   codeIn        the same inline/chunked split
##
## Testnet is a tenth of each. These are the documented protocol fees and
## exclude gas, so treat every figure here as an estimate.
const MON_BASIC_FEE := 6.5
const MON_LINKED_FEE := 19.5
const MON_CREATE_TABLE := 19.5
## Above this many bytes a payload is chunked and pays the higher fee.
const MON_INLINE_LIMIT := 700
const MON_CHUNK_BYTES := 70656
const MON_PER_CHUNK := 0.415972
const MON_BASE := 6.5

## Robinhood Chain, from the same docs, with the same inline/chunked split:
##
##   createTable   0.00036 ETH, always
##   writeRow      0.00012 ETH inline, 0.00036 chunked
##   codeIn        the same split, per ~96 KB batch
##
## It settles in ETH, which is also its gas token, so these are ETH figures
## rather than a chain-named token. Holders of the IQ token pay a reduced
## inline fee (0.00006); nothing here assumes that discount, because quoting a
## discount the keeper may not have would under-price a write they cannot undo.
const RH_BASIC_FEE := 0.00012
const RH_LINKED_FEE := 0.00036
const RH_CREATE_TABLE := 0.00036
const RH_INLINE_LIMIT := 700
const RH_CHUNK_BYTES := 98_304


static func is_monad(chain: String) -> bool:
	var c := chain.strip_edges().to_lower()
	return c == "mon" or c == "monad"


static func is_robinhood(chain: String) -> bool:
	var c := chain.strip_edges().to_lower()
	return c == "rh" or c == "rhc" or c == "robinhood" or c == "robinhood-chain"


static func token(chain: String) -> String:
	if is_robinhood(chain):
		return "ETH"
	if is_monad(chain):
		return "MON"
	return "SOL"


## What inscribing a short covenant costs.
static func per_write(chain: String) -> float:
	if is_robinhood(chain):
		return RH_BASIC_FEE
	return MON_BASE if is_monad(chain) else SOL_BASE


## Creating one table. On the EVM chains this is a flat protocol fee regardless
## of size.
static func create_table(chain: String) -> float:
	if is_robinhood(chain):
		return RH_CREATE_TABLE
	return MON_CREATE_TABLE if is_monad(chain) else SOL_BASE


## Writing one row of the given size. A check-in row is a few dozen bytes, so
## it pays the inline fee; a large row is chunked and pays three times as much.
static func write_row(chain: String, bytes: int = 64) -> float:
	if is_robinhood(chain):
		return RH_LINKED_FEE if bytes > RH_INLINE_LIMIT else RH_BASIC_FEE
	if is_monad(chain):
		return MON_LINKED_FEE if bytes > MON_INLINE_LIMIT else MON_BASIC_FEE
	return SOL_BASE + SOL_PER_CHUNK * maxi(1, ceili(float(bytes) / SOL_CHUNK_BYTES))


## Kept for callers that just want the cost of an ordinary check-in.
static func per_db_write(chain: String) -> float:
	return write_row(chain)


## What a payload of this size costs to inscribe.
static func for_bytes(chain: String, bytes: int) -> float:
	var payload := maxi(bytes, 0)

	if is_robinhood(chain):
		# Inline below the limit; above it, every ~96 KB batch pays the
		# linked-list fee.
		if payload <= RH_INLINE_LIMIT:
			return RH_BASIC_FEE
		@warning_ignore("integer_division")
		var rh_batches: int = (payload + RH_CHUNK_BYTES - 1) / RH_CHUNK_BYTES
		return RH_LINKED_FEE * maxi(rh_batches, 1)

	if is_monad(chain):
		# Inline below the limit, chunked above it — and the chunked fee is the
		# higher one, plus a little per chunk beyond the first.
		if payload <= MON_INLINE_LIMIT:
			return MON_BASIC_FEE
		@warning_ignore("integer_division")
		var mon_chunks: int = (payload + MON_CHUNK_BYTES - 1) / MON_CHUNK_BYTES
		return MON_LINKED_FEE + maxi(mon_chunks - 1, 0) * MON_PER_CHUNK

	@warning_ignore("integer_division")
	var sol_chunks: int = (payload + SOL_CHUNK_BYTES - 1) / SOL_CHUNK_BYTES
	return SOL_BASE + sol_chunks * SOL_PER_CHUNK


## Keeping one flame alive for a year, at this check-in interval. Checking in
## writes a row, so it is priced as a database write.
static func per_year(chain: String, interval_days: int) -> float:
	var writes := 365.0 / maxf(float(interval_days), 1.0)
	return per_db_write(chain) * writes


## Formats an amount with enough places to be meaningful on that chain: a
## Solana figure needs four, a Monad figure looks absurd with them, and an ETH
## fee on Robinhood Chain rounds away to nothing under five.
static func format(chain: String, amount: float) -> String:
	if is_robinhood(chain):
		return "%.5f ETH" % amount
	if is_monad(chain):
		return "%.1f MON" % amount
	return "%.4f SOL" % amount


## One line comparing the chains, so the choice can be made on numbers.
static func comparison() -> String:
	return (
		(
			"A check-in is about %s on Solana, %s on Monad, or %s on Robinhood Chain. "
			% [
				format("sol", write_row("sol")),
				format("mon", write_row("mon")),
				format("rh", write_row("rh")),
			]
		)
		+ "Bigger writes cost more."
	)
