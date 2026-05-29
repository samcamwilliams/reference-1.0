# Decision: drop `/compute` from paths + add `max-age` freshness

Two requests, one underlying change.

## Why `/compute` was needed
My reference-set examples used `Set~reference@1.0/compute/<name>/compute/<key>`.
The explicit `compute` forced the *cached* read path. Without it, a bare key
(`Set~reference@1.0/<name>`) routes to the device's `default` handler `get/4`,
which previously did `now` (poll the gateway) on every read unless the request
carried `cache-control: only-if-cached`. So offline/tests needed `/compute`, and
production reads would have hit the gateway per key.

## The change: `get/4` serves cache by default, refreshes on `max-age`
`get/4` now chooses between `compute` (serve the local view) and `now` (refresh
from the gateway first) based on freshness:

- Effective `max-age` = request `max-age`, else node `reference-max-age` option,
  else **`infinity`**. `cache-control: only-if-cached` ⇒ `infinity`.
- `infinity` ⇒ never stale ⇒ always `compute` (no gateway).
- Finite `max-age` ⇒ stale when `clock - last-refreshed > max-age` ⇒ `now`,
  otherwise `compute`. A reference never refreshed on this node is stale.

Because the default is `infinity`, `Set~reference@1.0/<name>/<key>` resolves
entirely from cache — **no `/compute`** — and AO-Core dispatches `get/4` at each
hop (set → directory → pointer → downstream). Updates still show up: `compute`
reads the latest applied `set`; the node refreshes via an explicit `now` or a
cron. Operators wanting read-triggered refresh set a finite `reference-max-age`;
callers override per request with `max-age`.

This removes `/compute` from every example (task 1) and is exactly the
`max-age` mechanism (task 2).

## Caching the resolution time
Each successful `refresh` records the local wall-clock second it validated the
reference against the gateway, at `~reference@1.0/<RefID>/refreshed-at` (a raw
`hb_store` value — local metadata, *not* part of the reference's signed state;
it is the device's analogue of HTTP `Age`). `get/4` reads it to compute age.
The clock is `erlang:system_time(second)`, overridable via the `reference-clock`
option so the freshness decision is deterministically testable.

Wall-clock here is deliberate and safe: it drives only a *local* refresh
decision, never the reference's verifiable value (which stays deterministic
given the cache state). Per-reference granularity falls out for free — the set
and each downstream carry their own `refreshed-at`.

## Considered, not taken
- *stale-if-error* (serve the cached value when a refresh fails) — friendly for
  a name service, but adds error-path behaviour beyond the ask. Noted as a
  follow-up; today a finite-`max-age` read that goes stale propagates a gateway
  error exactly as `now` already does.
- *Expressing freshness in the reference's own timestamp domain* — rejected;
  `max-age` is node-local polling cadence, orthogonal to the signed `set`
  ordering.
