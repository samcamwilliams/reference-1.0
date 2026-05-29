# `reference@1.0` — AO-Core Device Specification

Status: Validated by independent reimplementation (see below). Specifies an **AO-Core device**, independent of any node
implementation. MUST, MUST NOT, SHOULD, MAY per RFC 2119.

## 0. AO-Core context (informative)

A **message** is a map of binary keys to values (binaries or nested messages).
A **device** (`name@version`) interprets a message: resolving a **key**
dispatches to the device named by the message's `device` key. **Paths** chain —
`Message/k1/k2` resolves `k1` (via the message's device), then `k2` against the
result. A segment MAY bind a device: `<id>~reference@1.0/<key>` loads `<id>`,
treats it as a `reference@1.0` message, and resolves `<key>`. A message MAY
carry **commitments** (signatures) by **committer** addresses; a committed
message has a content-addressed **ID** over its contents and commitments, and
MAY be published to a public, append-only data layer (Arweave) and discovered
there by committer, tag, and block range.

## 1. Overview

`reference@1.0` binds a **mutable value** to an **immutable identifier** — the
committed ID of a signed `init` message. Updates are **total**: each `set`
replaces the value outright, so the current value is a pure function of the
single latest valid `set` (or the `init` if none). A reference has exactly one
**authority**, fixed for its life; only the authority may publish `set`s.

## 2. Identity and authority

- A **reference** is identified by its **reference ID**: the committed ID of
  its signed `init`.
- The **authority** is the `init`'s `authority` key if present (a binary
  address), else the `init`'s sole committer.
- A message's reference ID is its `reference-id` key if present, else its own
  committed ID. An `init` MUST NOT carry a `reference-id` (it identifies its own
  reference); a `set` and a pointer (§9) MUST carry one.

## 3. Messages

Both types MUST set `device = "reference@1.0"` and MUST be committed. Keys are
binary.

**`init`** — `authority?` (address; default = committer), `reference-value?`
(message; the initial value, default = the `init` message itself), `timestamp?`
(integer; seeds the update clock, default `0`).

**`set`** — `reference-id` (the target reference; REQUIRED), `reference-value?`
(the new value; default = the `set` message itself), `timestamp` (integer; the
ordering key; REQUIRED).

The **effective value** of a message is its `reference-value` if present, else
the message itself.

## 4. Validity and ordering of `set`s

A `set` `S` for reference `R` becomes `R`'s current state iff BOTH:
1. `S` is committed by `R`'s authority (otherwise ignored); and
2. `S.timestamp` is **strictly greater** than the current state's timestamp
   (the latest applied `set`, or the `init` if none).

For equal timestamps, the `set` at the **earlier data-layer position** (block
height, then position within block) wins; later equals are ignored.
Equivalently: fold candidates in ascending data-layer order under the
strictly-greater rule. Because the data layer is append-only, this incremental
fold yields the same result as evaluating all candidates globally.

## 5. Resolved keys

- **`compute`** → the current **effective value**, from the **local view only**
  (no data-layer access): the effective value of the latest applied `set`, else
  of the `init`. Errors (`not-found`) if the reference is unknown locally.
- **`now`** → revalidate against the data layer (§6), then `compute`.
  Propagates a data-layer error.
- **any other key `k`** → the **default resolver**: pick the current value by
  freshness (§7) — `compute` if fresh, else `now` — then resolve `k` against
  that value. When `reference-value` was present, `k` resolves against it
  normally, so a `reference-value` that is itself a pointer (§9) chains
  downstream. When the value is the reference message itself (no
  `reference-value`), `k` MUST be resolved against it as a **plain message**
  (the base message device, not `reference@1.0`); resolving via `reference@1.0`
  would re-enter this resolver and never terminate.

`compute` and `now` yield the **bare** effective value; the default resolver
yields a key *within* it (requesting a key the value does not have is
`not-found`).

The default resolver MUST NOT capture the structural keys a node uses to
manipulate a message (e.g. `keys`, `set`, `set-path`, `remove`); those resolve
with the base message device, so path-binding and message operations keep
working.

## 6. Revalidation

To revalidate `R`: discover candidate `set`s (§8), apply the valid ones in
order (§4) to the local view (which persists, so a later `compute` reflects
them), and record `R`'s **refresh time** = the local wall-clock second of this
revalidation — on **every** successful revalidation, including when no new
`set`s are found. The refresh time is local metadata, not committed state.

## 7. Freshness (`max-age`)

The default resolver chooses cache vs revalidation:
- **Effective max-age** (seconds), in precedence: the request's `max-age`
  field; else the node's configured default; else `infinity`. A request
  `cache-control` of `only-if-cached` forces `infinity`. (`max-age` is a
  request field of its own; `only-if-cached` is read from `cache-control`.)
- `R` is **stale** iff the effective max-age is finite AND (`R` has no refresh
  time OR `now − refresh_time > max-age`). `infinity` ⇒ never stale;
  `max-age = 0` ⇒ stale once any time has passed since the last revalidation.
- A stale read revalidates (`now`); a fresh read serves the cache (`compute`).
  The default SHOULD be `infinity`, so `<RefID>~reference@1.0/<k>` resolves from
  cache without data-layer access.

## 8. Discovery (data layer)

Revalidation discovers candidate `set`s by querying for committed messages
where `device` tag = `reference@1.0` AND `reference-id` tag = `<RefID>`, ordered
by data-layer position **ascending**, bounded below by
`max(0, last_applied_block − 1)` (the `−1` so boundary-block ties are not
skipped). The query MUST return each result's block height (used to order and
to advance the lower bound); the "position within a block" of §4 is the order in
which the data layer returns results at that height. A node SHOULD also restrict
the query to the **authority's** commitments (so non-authority messages are
never fetched). Regardless of the query, the node MUST apply only `set`s
satisfying §4.

## 9. Reference sets

A **reference set** is a reference whose value is a **directory**: a map from
names to **pointers**, a pointer being
`{ "device": "reference@1.0", "reference-id": "<DownstreamID>" }`. Because a
pointer's reference ID is its explicit `reference-id` (§2) and each path step's
device comes from the current message, the path
`<SetID>~reference@1.0/<name>/<key>` resolves: set → directory → pointer (a
reference) → downstream effective value → `key`. Each downstream is updated
independently under its own authority; the set's authority controls only the
directory (a total snapshot, §4). For a pointer to resolve, the downstream's
`init`/`set`s MUST be locatable in the node's local view — in particular, a
reference's `init`, addressed by the reference ID, locatable from the message
store satisfies this. This is the pattern for managing many names that each
point to another reference downstream.

## 10. Security

Authority is enforced on every `set` (§4), is non-transferable, and stale or
non-authority `set`s are rejected. Restricting discovery to the authority's
commitments avoids fetching non-authority messages. A node that caches
resolution results by request identity will pin a reference's value (its request
path is constant across updates); a node serving mutable references MUST disable
result caching for these resolutions, or reads stay stale until the cache
evicts.

## 11. Conformance

For the same `init` and the same candidate `set`s, a conforming implementation:
1. derives the same reference ID (§2);
2. accepts/rejects each `set` and selects the same current state (§4);
3. yields the same effective value from `compute` (§4–5);
4. resolves `<RefID>~reference@1.0/<key>` to the same value (including the
   self-value and reference-set cases, §5/§9) and makes new valid `set`s
   observable via `now`;
5. selects cache vs revalidation per `max-age`/`only-if-cached` (§7);
6. discovers the same candidate `set`s (§8).

Local storage representation is an implementation detail, not a conformance
requirement; only the observable behaviour above is.
