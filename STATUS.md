# STATUS — `~reference@1.0` reference-set end-to-end verification

**Mode:** overnight / unattended. Acceptance test (immutable): a reference *set*
managing a large number of names — each name pointing to another reference
downstream — works end-to-end in normal HyperBEAM eunit style.

## What the device is
`dev_reference.erl` grants mutable state to an immutable reference (the ID of a
signed `init` message). Two message types: `init` and `set`. Only the init's
authority may `set`. `compute` reads current value from local cache; `now` polls
the gateway for new `set`s then computes; the `default` handler `get/4` resolves
an arbitrary key through the latest value.

## Design under test: "reference set"
A top-level reference whose `reference-value` is a directory map
`#{ name => Pointer }`, where each `Pointer = #{ device => reference@1.0,
reference-id => DownstreamID }` — a lightweight handle to a *downstream*
reference. Because `dev_reference:reference_id/2` honours an explicit
`reference-id` key, and AO-Core derives each path step's device from the current
message (`hb_device:message_to_fun(Base, Key, _)`), the chain
`SetRef~reference@1.0/compute/<name>/<key>` flows into the downstream reference's
current value. Downstream references update independently of the directory.

## Verified substrate facts (from edge dep `_build/default/lib/hb`)
- `dev_name` binary-path resolver appends the key: `<<Path/binary,"/",Key/binary>>`.
- Per-step device comes from the current message (`hb_ao.erl:534`). → pointer-chaining sound.
- `hb_cache:write/2` → `{ok, ID}`; `hb_cache:read/2` → `{ok,Msg}|not_found|{error,_}`.
- Default HTTP port = env `HB_PORT` (default 8734).

## Environment hazards (do NOT disturb)
- **Port 8734 is owned by PID 95833 (`rebar3 device local`), up 1d16h — NOT mine.**
  eunit's `{start_applications,[prometheus,hb]}` boots the `hb` app, which binds
  the default port. Run eunit with **`HB_PORT=0`**; tests that `start_node` must
  pass `port => 0`. Never kill 95833.

## How to run the tests (normal HyperBEAM style for a forge device)
`HB_PORT=0 rebar3 device test` — the forge provider packages the device into a
preloaded store, installs it as global env, resolves `reference@1.0` via the
high-trust preloaded path, then runs the generated eunit suite. Plain
`rebar3 eunit` does NOT work (device falls through to network → times out).
`HB_PORT=0` is required because `device test` starts the `hb` app (binds the
default port, which the shared node owns). `--test <name>` filters.

## Bugs found & fixed in the device / existing test
1. **Root bug — missing `excludes` in `dev_reference:info/0`.** The greedy
   `default => fun get/4` captured the structural keys (`set`, `set_path`, ...)
   that AO-Core uses when binding `~reference@1.0` to a path, so `get/4` fired
   `now` → real gateway → `no_viable_responses`. Fixed by adding
   `excludes => [<<"keys">>,<<"set">>,<<"set-path">>,<<"remove">>]` (the
   `dev_arweave`/`dev_location` idiom). This is why `~reference@1.0/compute`
   paths never worked. **Confirmed**: failure moved past that point after fix.
2. **Over-specified assertion** in `name_resolves_through_reference_test`:
   compared `compute` result to a bare map, but a cache round-trip materialises
   commitments/priv/links. Fixed to assert the resolved scalar (`foo`→value-1).
   → Lesson for new tests: assert on resolved scalar leaves, never whole msgs.
3. **Port collision**: existing e2e `start_node` used the default port (owned by
   shared node 95833). Fixed with `port => 0`.

## RESOLVED: result-cache staleness → a DEPLOYMENT REQUIREMENT (not a device bug)
A reference is mutable but its resolution path is constant, so AO-Core's
hashpath-keyed result cache can serve a stale value. Findings (evidence in
/tmp/ref_probe*.log):
- The device is correct: **in-process resolution always reflects updates**
  (`?DEFAULT_STORE_OPT = false` → nothing cached in-process).
- Over HTTP the node pins the value because the default `http-extra-opts`
  forces `cache-control => [<<"always">>]` on every request (store+lookup).
- Opts-level cache settings OVERRIDE message-level in `derive_cache_settings`,
  so a device-emitted `cache-control` cannot beat the node's `always`. → This
  is strictly a **node-config** concern, confirming it's not a device fix.

### ⚠️ DEPLOYMENT REQUIREMENT (surface to the production team)
A node serving mutable reference / reference-set lookups MUST override
`http-extra-opts` so reads are not pinned, e.g.:
```
<<"http-extra-opts">> => #{
    <<"force-message">> => true,
    <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
}
```
Without this, name lookups return the first value forever (until cache
eviction) even after the underlying reference is updated. **Verified**: with
the override, an HTTP lookup reflects a downstream update (value-1 → value-2).
The alternative (keep caching, refresh via `now`) does not help — the cache
key is still constant. See `decisions/reference-set-design.md`.

## RESULT — COMPLETE ✅  (All 15 tests pass; verified twice)
`HB_PORT=0 rebar3 device test` → `All 15 tests passed.` (exit 0), confirmed on
two consecutive runs (scale test 45s then 26s — machine-noise variance, well
within its 120s budget). 10 pre-existing tests + 5 new reference-set tests:

- `reference_set_resolves_many_names` — **N=1000** names, each → a distinct
  downstream reference. Asserts every name maps to the right downstream, a
  spread resolves end-to-end to its downstream value, and an absent name does
  not resolve.
- `reference_set_downstream_update_is_independent_test` — updating one
  downstream changes only that name; directory + other downstreams untouched.
- `reference_set_directory_update_adds_name_test` — a total directory snapshot
  adds a name without touching downstreams.
- `reference_set_downstream_authority_is_isolated_test` — the directory owner
  cannot forge a downstream's value; only the downstream's authority can.
- `reference_set_resolves_over_http_test` — full chain over a real node via
  `~name@1.0` + HTTP, including a downstream update reflected live.

## Files changed
- `src/dev_reference.erl` — device fix (`excludes`) + 3 faithful fixes to the
  existing e2e test + the new reference-set suite/helpers. (+262/-5)
- `STATUS.md`, `decisions/reference-set-design.md` — overnight artifacts.
- Nothing committed (not requested). Diff is ready for review.

## Log / progress
- [x] Read device + README + rebar.config + substrate.
- [x] `rebar3 compile` — exit 0.
- [x] Found correct run command: `HB_PORT=0 rebar3 device test`.
- [x] Fixed root `excludes` bug; faithful assertion + port + http-extra-opts.
- [x] Diagnosed cache staleness → node-config deployment requirement (above).
- [x] Wrote reference-set end-to-end suite (many names → downstream refs).
- [x] Full suite green (15/15), verified twice, no warnings.

## Follow-up work (committed fe40f4c, then this)
Two requests, one change — see `decisions/max-age-and-compute.md`.
- **Dropped `/compute` from examples.** `get/4` now serves the cached value
  (`compute`) by default and only revalidates (`now`) when the local view is
  older than the effective `max-age`. Default max-age = `infinity`, so a bare
  path `Set~reference@1.0/<name>/<key>` resolves entirely from cache (AO-Core
  dispatches `get/4` at each hop) — no `compute` segment. All example/test
  paths updated; the only remaining `compute` is the legitimate "give me the
  whole current value" call in the directory-completeness check.
- **`max-age` freshness.** `refresh` records the local wall-clock second at
  `~reference@1.0/<RefID>/refreshed-at`; `get/4` compares it to the effective
  `max-age` = request `max-age` → node `reference-max-age` → `infinity`.
  `max-age: 0` revalidates every read; `only-if-cached`/`infinity` never do.
  Clock overridable via `reference-clock` for deterministic tests.
- 3 new tests: freshness decision (caller max-age), default-from-node-option,
  and serve-from-cache-without-gateway. (18 tests total.)

## Possible follow-ups (not blockers)
- *stale-if-error*: serve the cached value when a finite-max-age refresh hits a
  gateway error (friendly for a name service; deliberately not added yet).
- A live-gateway integration test for `now/3` (network-dependent; the
  application logic it uses — `apply_items`/authority/timestamp ordering — is
  already covered offline).
- If suite speed matters, `N` in the scale test is a one-line dial.
