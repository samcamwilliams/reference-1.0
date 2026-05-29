# `~reference@1.0`

A HyperBEAM (AO-Core) device that gives an **immutable identifier a mutable
value**.

A reference is named by the ID of a signed `init` message — that ID never
changes. Its value, however, can be updated by publishing `set` messages. Each
update is **total**: a `set` replaces the value outright, so the reference's
current value is simply the latest valid `set` (or the `init` if there are
none). There is no accumulated state to replay — unlike `~process@1.0`,
computing the present value never depends on previous values.

Every reference has exactly one **authority**: the address that signed the
`init` (or an explicit `authority` it names). Only that address may publish
`set`s, and it is fixed for the life of the reference — ownership cannot be
transferred.

## At a glance

```
# Create a reference (sign an init):
init  = { device: "reference@1.0", reference-value: { greeting: "hello" } }
# its ID, e.g. b6X...Q4, is the reference's permanent name.

# Read it:
GET /b6X...Q4~reference@1.0/greeting           -> "hello"

# Update it (the authority signs a set with a newer timestamp):
set   = { device: "reference@1.0", reference-id: "b6X...Q4",
          timestamp: 2, reference-value: { greeting: "hi there" } }

GET /b6X...Q4~reference@1.0/greeting            -> "hi there"
```

A read resolves the reference's current value from the node's local cache; the
node refreshes from the data layer (Arweave) on demand or on a schedule. A
caller can bound staleness with `max-age` (see the spec).

## Reference sets — many names, one directory

The headline pattern: a reference whose value is a **directory** mapping names
to **pointers** at *other* references downstream.

```
set-of-names = { device: "reference@1.0", reference-value: {
    alice: { device: "reference@1.0", reference-id: "<alice's ref>" },
    bob:   { device: "reference@1.0", reference-id: "<bob's ref>"   },
    ...                                          # thousands of names
}}

GET /<set>~reference@1.0/alice/balance          # set -> alice's ref -> balance
```

Resolution chains straight through: the set resolves `alice` to her pointer,
the pointer is itself a reference, and the next key resolves against *its*
current value. Each downstream reference is owned and updated independently by
its own authority; the set's authority controls only the directory (which names
exist and where they point). This is how you manage a large, evolving namespace
where each entry is independently mutable.

## Specification

[`SPEC.md`](SPEC.md) is the normative, implementation-independent (AO-Core)
specification: identity, the `init`/`set` schemas, validity and ordering of
`set`s, the `compute`/`now`/default-key resolution interface, `max-age`
freshness, data-layer discovery, reference sets, and a conformance checklist.
It was validated by having independent agents reimplement the device from the
spec alone and confirming they converge.

## Build, test, deploy

```sh
rebar3 compile

# Run the device's EUnit suite (packages + registers the device first).
# Set a free HB_PORT; never use 8734. Judge success by the EUnit summary line.
HB_PORT=0 rebar3 device test

rebar3 device package        # build the signed device archive
rebar3 device verify
rebar3 device publish --key wallet.json
```

### Deployment note

A reference is mutable but addressed at a constant path, so a node that caches
resolution results will pin the first value and mask later updates. A node
serving reference lookups over HTTP **must** disable result caching for them,
e.g.:

```erlang
http-extra-opts => #{
    <<"force-message">> => true,
    <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
}
```

Otherwise lookups return a stale value until the result cache evicts.
