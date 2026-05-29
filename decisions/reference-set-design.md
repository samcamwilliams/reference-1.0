# Decision: reference-set design & the result-cache question

## Original task (as understood)
Deploy tomorrow a system that uses a **reference set** to manage a large number
of names, each name pointing to **another reference downstream**. Build a test
proving it works end-to-end in normal HyperBEAM eunit style, AO-Core-native, on
the existing `~reference@1.0` device. Read the substrate first. Overnight mode.

## Design chosen: directory-of-pointers
The reference set is itself a `~reference@1.0` reference whose `reference-value`
is a directory map `#{ Name => Pointer }`, where each
`Pointer = #{ <<"device">> => <<"reference@1.0">>, <<"reference-id">> => DownstreamID }`
— a lightweight handle to a downstream reference.

Why this is AO-Core-native and composes:
- `dev_reference:reference_id/2` honours an explicit `reference-id` key, so a
  pointer resolves to its downstream without embedding the (signed) downstream
  message — only its ID. Downstreams live independently in the cache/network.
- AO-Core derives each path step's device from the current message
  (`hb_device:message_to_fun(Base, Key, _)`), so the chain
  `SetRef~reference@1.0/compute/<name>/compute/<key>` flows:
  set → directory map → pointer (device=reference@1.0) → downstream value → key.
- Each downstream reference is independently mutable by *its own* authority;
  the set's authority controls only the directory (which names exist / where
  they point). This gives clean delegation + blast-radius isolation.

Alternatives rejected:
- *Embed each downstream's full signed init in the directory.* Heavier; relies
  on signed sub-messages surviving the set's cache round-trip with a stable
  signed ID. The pointer (ID-only) form avoids that and matches how independent
  references actually exist on the network.
- *Map names → bare ID binaries.* Then `compute/<name>` yields a binary that
  does not chain into the downstream value without the caller re-deriving a
  path. The pointer (device-carrying) form chains natively.

## Bug fixed: missing `excludes` (root cause of `~reference@1.0` paths failing)
`info/0` declared only `default => fun get/4`. That greedy default captured the
structural keys AO-Core uses when binding `~reference@1.0` onto a path
(`set`, `set_path`, ...), routing them to `get/4` → `now` → the real gateway →
`no_viable_responses`. Fixed by excluding them, per the `dev_arweave` /
`dev_location` idiom: `[<<"keys">>,<<"set">>,<<"set-path">>,<<"remove">>]`.
Confirmed: the failing path moved past device-binding after the fix.

## The result-cache question (mutable reference at a constant path)
A reference's value at `RefID~reference@1.0/compute` changes over time, but
AO-Core caches resolution results keyed by `hashpath(Base, Req)` — constant
across updates. So a caching node can serve a STALE reference value.

Findings (evidence in /tmp/ref_probe*.log):
- The device's `compute` is correct: in-process resolves reflect updates
  immediately (`?DEFAULT_STORE_OPT = false`, so nothing is cached by default).
- Over HTTP, a node configured to cache results serves the stale first value.
- The HB idiom for non-cacheable device output (dev_cron, dev_arweave,
  dev_httpsig, dev_delegated_compute) attaches `cache-control` to a *response
  envelope* (`#{status,cache-control,body}`). `compute` returns a *pure value*,
  so adopting that would change its return shape and break `compute/<key>` and
  every existing test — too invasive, and the device logic is already correct.

**Decision:** treat freshness as a resolution/opts concern, not a value-shape
change. A node serving mutable reference-set lookups must resolve them with
`cache_control => [<<"no-store">>, <<"no-cache">>]` (it propagates to every
sub-resolve, including the inner `compute`). This is the correct config for
serving mutable data and keeps `compute` a pure value. **This is a deployment
requirement** for the production reference-set node — surfaced in STATUS.md.
(Pending final confirmation by `cache_staleness_http_probe_test`.)

If the opts-level lever turns out not to propagate, fallback is to have the
name-resolver entry carry the cache directive; device-shape change is last
resort.
