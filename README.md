# Burning Bush Protocol

**Tend the flame. Or don't.**

A dead man's switch built on an inscribed proof of life. The keeper tends a
flame on-chain; its absence is a public, timestamped fact that needs no host to
adjudicate and no organisation to remember. When the flame goes dark, the
witnesses bring their fragments together and open what was sealed.

*And the bush burned with fire, and the bush was not consumed.* — Exodus 3:2

---

## Why this shape

A dead man's switch has one genuinely hard problem, and it isn't cryptography.
It's answering **"is he actually gone?"** without a company deciding for you.

That question turns out to be free on a permanent ledger. "No row since March"
is checkable by anyone, forever, without permission. So the trigger is solved
here and the release is delegated to people, which is the one part that can't
be automated away honestly.

There's an impossibility worth stating plainly, because it rules out the design
most people reach for first:

> If release depends only on data published **before** you died, the clock
> necessarily starts at **publication**, not at death.

Everything you'll ever emit is fixed by the time you stop. The only remaining
variable is computation on already-public data — which anyone could have begun
the day you published. Time-lock puzzles, hash chains, "the heartbeat reseeds
the puzzle": all of them founder on the same rock, because permanence means you
can never retract a countdown once it starts.

So: the chain proves you're gone. Witnesses hold the key. Neither half pretends
to be the other.

## How it works

**The flame** is a row written to an on-chain table on a schedule you choose.
Tending it costs roughly a dollar and takes one approval. Three states:

| State | Meaning |
|---|---|
| `BURNING` | Tended within the interval. Nothing to do. |
| `GUTTERING` | Past the interval, inside grace. Tend it. |
| `DARK` | Past grace. The covenant may be opened. |

**The covenant** is encrypted the moment you seal it and inscribed as
ciphertext, so it's public and permanent from day one. Nothing about it is
secret because it's hidden — it's secret because the key is split.

**The fragments** come from Shamir's scheme over GF(256). Any *k* of *n*
restore the key; fewer reveal *nothing*, and that's information-theoretic, not
a matter of computing power. The key never leaves the app and the fragments are
shown exactly once. Nothing writes them down: putting every fragment in one
file would undo the entire point.

## Requirements

Burning Bush Protocol **holds no keys**. It's a client of
[GodOnChain](../GodOnChain), which owns the signing keys and prompts you before
anything is spent. Launch it from there, or run GodOnChain alongside it.

With no host it says so and stays usable — on-chain access is an optional
capability, not a requirement.

## Getting started

1. Open `project.godot` in Godot 4.7+ and press **F5**.
2. **SETTINGS** — name a covenant root (the `dbRootId` your flame lives under),
   pick a chain, and set the interval and grace period.
3. **BUILD THE ALTAR** — creates the flame table. Once per keeper.
4. **TEND THE FLAME** — writes a proof-of-life row. Do this on schedule.
5. **SEAL A COVENANT** — write the word, choose how many witnesses and how many
   are needed, and hand out the fragments.

Grace is generous by default (30 + 60 days) because **being unreachable is not
being dead**, and a false release cannot be undone.

## Layout

```
Scripts/
  shamir.gd        Secret sharing over GF(256)
  covenant.gd      Seal, shatter, gather, unseal
  flame.gd         The heartbeat and its three states
  scripture.gd     Everything the app says out loud
  temple_theme.gd  Sixteen colours on black
Scenes/
  main.gd          The app
  bush.gd          The bush, drawn in text and set on fire
addons/iq_client/  Drop-in client for the GodOnChain host
tools/
  bbp_selftest.gd  Headless checks
```

## Testing

```bash
Godot --headless --path . --script res://tools/bbp_selftest.gd
```

Shamir gets the most attention, because a splitting bug that still round-trips
on the happy path would silently produce a covenant nobody can ever open — and
there is no finding that out later. The suite checks every one of the 255
non-zero field elements, all ten 3-of-5 subsets rather than the convenient one,
that fragment order doesn't matter, that below-threshold reconstruction returns
a *wrong* answer without leaking the plaintext, and the full seal → shatter →
gather → unseal path.

## Read this before you seal anything

- **There is no unpublish.** Ever. Not by you, not by anyone.
- **Never seal another person's private matters.** A right to erasure and an
  immutable public ledger are incompatible, and the mistake is unrecoverable.
- **Encryption is not a fix for that.** Today's ciphertext is already public
  and is tomorrow's plaintext.
- **A stolen signing key keeps the flame alive forever**, suppressing release
  indefinitely. It's the sharpest attack on this design.
- **Witnesses can collude early.** A threshold raises the bar; it doesn't
  remove it. Choose people who don't share a dinner table.
- **A block time is evidence, not adjudication.** It proves bytes existed by a
  moment. It doesn't execute your will.

---

*Built with Godot. Blessed by our good King Terry. If I suicide myself, I
didn't.*
