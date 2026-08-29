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

Each tablet keeps its own flame, so one going dark says nothing about the
others. A keeper may hold many at once; dark ones are listed first, because
that is the only row anyone opens this app to see.

**The covenant** is encrypted the moment you seal it and inscribed as
ciphertext, so it's public and permanent from day one. Nothing about it is
secret because it's hidden — it's secret because the key is split.

**The fragments** come from Shamir's scheme over GF(256). Any *k* of *n*
restore the key; fewer reveal *nothing*, and that's information-theoretic, not
a matter of computing power.

**Fragments travel on-chain.** Give a witness their identity key and their
fragment is encrypted to it and inscribed alongside the tablet — nothing to
hand over, nothing for them to lose, no email to survive. A witness's identity
is derived from their wallet, so it is the same on every machine they sign with
and there is nothing to store. Leave the key blank and you deliver that one by
hand instead; those are shown exactly once and never written down.

**Witnesses testify in public.** A witness holding one fragment cannot open
anything alone, and privately coordinating *k* people is the organisational
fragility this exists to avoid. So once a flame is dark they publish their
fragment instead. When enough have, anyone can reconstruct the key and the word
is out. Testifying *is* the release, not a step towards privately reading it —
the app says so before you do it.

**Release modes combine.** A tablet may use witnesses, a public burn, or both,
in which case whichever happens first opens it.

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
3. **NEW COVENANT** — write the word or choose a file, name your witnesses,
   and say how many fragments are needed to open it.
4. **BUILD ALTAR** — creates that tablet's flame table, and the place its
   witnesses will testify. Once per tablet.
5. **TEND** — writes a proof-of-life row. Do this on schedule.

As a witness: **MY IDENTITY** gives you the key to hand a keeper. **ADOPT**
takes a tablet by its signature. **TESTIFY** opens the fragment addressed to
you and publishes it.

Grace is generous by default (30 + 60 days) because **being unreachable is not
being dead**, and a false release cannot be undone.

## Layout

```
Scripts/
  shamir.gd        Secret sharing over GF(256)
  covenant.gd      Seal, shatter, gather, unseal
  flame.gd         The heartbeat and its three states
  tablet.gd        One switch: payload, terms, release modes
  ark.gd           Every switch this keeper holds
  testimony.gd     Where witnesses publish their fragments
  chain_table.gd   Reading a table on either chain
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

There is also a live check of the part that crosses a process boundary:

```bash
Godot --headless --path . --script res://tools/bbp_witness_check.gd
```

It needs a running GodOnChain host and the `GODONCHAIN_IQ_*` variables set. It
derives a wallet identity, wraps a fragment to it, opens it again, confirms the
recovered fragment still reconstructs the key with a peer, and confirms an
envelope addressed to somebody else stays shut.

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
- **A public burn is not a lock.** Its key rides in the tablet, so anyone
  reading the chain can open it the day it is sealed. The app just doesn't
  offer to until the flame is dark. Use it only for what you mean to become
  public anyway.
- **Testimony is irreversible.** Once enough witnesses publish, the covenant is
  open to everyone, forever.
- **A block time is evidence, not adjudication.** It proves bytes existed by a
  moment. It doesn't execute your will.

---

*Built with Godot. Blessed by our good King Terry. If I suicide myself, I
didn't.*
