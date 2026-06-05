%%% @doc A simple device that grants a mutable state to an immutable
%%% reference: The ID of the `~reference@1.0' `init' message. This mechanism
%%% is useful in circumstances where the values at a hashpath must be able to
%%% change periodically but where each update is total and not dependent on
%%% the previous state. In contrast to messages of the `~process@1.0'-type,
%%% the unitary update semantics of references mean that calculating the
%%% present state at any point does not require knowledge of any previous
%%% inputs or states.
%%%
%%% A reference has a single, immutable authority -- the address that signed
%%% the `init' message (or, optionally, an explicit `authority' Address
%%% declared by the init). Only that address may publish `set' messages on
%%% the reference; ownership cannot be transferred.
%%%
%%% The `~reference@1.0' schema has two message types:
%%%
%%% ```
%%% init:
%%%     device:           reference@1.0
%%%     authority?:       Address     If not set, the authority defaults to
%%%                                   the address of the signer.
%%%     reference-value?: MessageID   The ID of a foreign message whose keys
%%%                                   should be deemed to be imported to the
%%%                                   reference at initialization.
%%%     timestamp?:       UnixTime    The signer-determined timestamp that
%%%                                   should initialize the monotonic clock.
%%%
%%% set:                              Must be signed by the authority.
%%%     reference-id:     MessageID   The ID of the `init' message of the
%%%                                   reference being updated.
%%%     reference-value?:             A new message that the reference should
%%%                                   resolve to. If not set, the reference
%%%                                   inherits the keys and values of the
%%%                                   `set' message itself.
%%%     timestamp:        UnixTime    The signer-determined timestamp; used
%%%                                   as the tie-breaker for update ordering.
%%% '''
%%%
%%% When two `set' messages have the same `timestamp', the one with the
%%% earlier Arweave offset (equivalently: Arweave block height and TX
%%% ordering) is deemed valid. A `set' is otherwise valid when it is signed
%%% by the reference's authority and its timestamp is strictly higher than
%%% any prior `set' for the reference.
%%%
%%% Network lookups for new `set' messages use GraphQL only as an index of
%%% candidate transaction IDs. Each candidate is then loaded through the normal
%%% cache/store path before signature validation.
-module(dev_reference).
-export([info/0, compute/3, now/3, request/3]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hb/include/hb.hrl").

%% @doc Default key lookup falls through to the latest incarnation of the
%% reference's keys and values, so that `GET /ReferenceID/Key' resolves the
%% mutable data underlying the reference. The `excludes' list keeps the
%% message-manipulation keys (`set', `keys', etc.) bound to `message@1.0' so
%% that operations like setting the `~reference@1.0' device on a path are not
%% captured by `get/4' (which would otherwise trigger a network refresh).
info() ->
    #{
        default => fun get/4,
        excludes => [<<"keys">>, <<"set">>, <<"set-path">>, <<"remove">>]
    }.

%%%-------------------------------------------------------------------
%%% AO-Core entry points
%%%-------------------------------------------------------------------

%% @doc Resolve the current value of the reference using only locally cached
%% state. The current value is the `reference-value' of the latest applied
%% `set' message, falling back to the `init' message itself when no `set'
%% has been applied (or to the keys of the latest `set' when it carries no
%% `reference-value').
compute(Base, _Req, Opts) ->
    case current_message(Base, Opts) of
        undefined -> {error, <<"not-found">>};
        Msg -> {ok, effective_value(Msg, Opts)}
    end.

%% @doc Recompute the latest value by polling the gateway for new `set'
%% messages, validating each is signed by the reference's authority, folding
%% them into local state in Arweave order, and then resolving the result via
%% `compute/3'.
now(Base, Req, Opts) ->
    case refresh(Base, Opts) of
        ok -> compute(Base, Req, Opts);
        {error, _} = Err -> Err
    end.

%% @doc Request hook that dereferences a reference when it is the base message
%% selected by an earlier hook, such as `name@1.0' host resolution.
request(_Base, Req, Opts) ->
    maybe
        {ok, [Ref | Rest]} ?= hb_maps:find(<<"body">>, Req, Opts),
        true ?= is_map(Ref),
        <<"reference@1.0">> ?= hb_maps:get(<<"device">>, Ref, undefined, Opts),
        {ok, Value} ?=
            case stale(Ref, Req, Opts) of
                true -> now(Ref, Req, Opts);
                false -> compute(Ref, Req, Opts)
            end,
        {ok, Req#{ <<"body">> => [value_base(Value, Opts) | Rest] }}
    else
        _ -> {ok, Req}
    end.

%% @doc Default key resolver, so that `GET /ReferenceID/Key' yields the
%% mutable data underlying the reference. The current value is served from the
%% local cache (`compute'); the reference is revalidated against the gateway
%% (`now') first only when its local view is older than the effective
%% `max-age' (see {@link stale/3}). With the default `max-age' of `infinity'
%% this is a pure cache read, so no explicit `compute' step is needed in a
%% path and reads never touch the gateway.
get(Key, Base, Req, Opts) ->
    Stage =
        case stale(Base, Req, Opts) of
            true -> <<"now">>;
            false -> <<"compute">>
        end,
    case hb_ao:resolve(Base, Stage, Opts) of
        {ok, Value} ->
            hb_ao:resolve(value_base(Value, Opts), Req#{ <<"path">> => Key }, Opts);
        {error, _} = Err -> Err
    end.

value_base(ID, Opts) when ?IS_ID(ID) ->
    case hb_cache:read(ID, reference_opts(Opts)) of
        {ok, Msg} -> Msg;
        _ -> ID
    end;
value_base(Link, Opts) when ?IS_LINK(Link) ->
    try hb_cache:ensure_loaded(Link, reference_opts(Opts))
    catch _:_ -> Link
    end;
value_base(Value, _Opts) ->
    Value.

%%%-------------------------------------------------------------------
%%% Reference identity / current state
%%%-------------------------------------------------------------------

%% @doc Find the reference ID given either the reference's `init' message
%% or any later message that carries an explicit `reference-id' key.
reference_id(Base, Opts) ->
    case hb_maps:find(<<"reference-id">>, Base, Opts) of
        {ok, RefID} -> RefID;
        _ -> hb_message:id(Base, signed, Opts)
    end.

%% @doc Decide whether `Msg' is itself an `init' message (it has no
%% `reference-id' key).
is_init(Msg, Opts) ->
    not hb_maps:is_key(<<"reference-id">>, Msg, Opts).

%% @doc Return the latest known message defining the reference (the most
%% recently applied `set', or the `init' if none). Returns `undefined' when
%% the reference is unknown to this node.
current_message(Base, Opts) ->
    RefID = reference_id(Base, Opts),
    case cache_read(latest_path(RefID), Opts) of
        {ok, Latest} -> Latest;
        _ -> init_message(Base, RefID, Opts)
    end.

%% @doc Return the `init' message for the reference. If `Base' is itself
%% the init we return it directly; otherwise we look it up in the local
%% cache.
init_message(Base, RefID, Opts) ->
    case is_init(Base, Opts) of
        true -> Base;
        false ->
            case cache_read(init_path(RefID), Opts) of
                {ok, Init} -> Init;
                _ -> undefined
            end
    end.

%% @doc Resolve the underlying value the reference points at. If the
%% message carries a `reference-value', that is the value; otherwise the
%% message itself acts as the value.
effective_value(Msg, Opts) ->
    case hb_maps:find(<<"reference-value">>, Msg, Opts) of
        {ok, Val} -> Val;
        _ -> Msg
    end.

%%%-------------------------------------------------------------------
%%% Network refresh
%%%-------------------------------------------------------------------

%% @doc Pull new `set' messages from the gateway, validate each against the
%% reference's authority, and apply them in Arweave order. Returns `ok'
%% regardless of whether any new messages were applied; `{error, Reason}'
%% is returned only when the underlying gateway request fails.
refresh(Base, Opts) ->
    RefID = reference_id(Base, Opts),
    ok = ensure_init_cached(Base, RefID, Opts),
    case init_authority(Base, RefID, Opts) of
        undefined ->
            {error, <<"unknown-reference">>};
        Authority ->
            MinBlock = max(0, last_seen_block(RefID, Base, Opts) - 1),
            case fetch_reference_heads(RefID, Authority, MinBlock, Opts) of
                {ok, Items} ->
                    apply_items(RefID, Authority, Items, Opts),
                    ok = mark_refreshed(RefID, Opts),
                    ok;
                {error, _} = Err -> Err
            end
    end.

%% @doc Persist the init message under its canonical path so subsequent
%% lookups can locate it.
ensure_init_cached(Base, RefID, Opts) ->
    case cache_read(init_path(RefID), Opts) of
        {ok, _} -> ok;
        _ ->
            case is_init(Base, Opts) of
                true ->
                    RefOpts = reference_opts(Opts),
                    {ok, _} = hb_cache:write(Base, RefOpts),
                    SignedID = hb_message:id(Base, signed, Opts),
                    ok =
                        hb_store:link(
                            #{ init_path(RefID) => SignedID }, RefOpts);
                false -> ok
            end
    end.

%% @doc Resolve the authority declared by the reference's `init' message,
%% defaulting to the init's signer when the `authority' field is absent.
init_authority(Base, RefID, Opts) ->
    case init_message(Base, RefID, Opts) of
        undefined -> undefined;
        Init ->
            case hb_maps:find(<<"authority">>, Init, Opts) of
                {ok, A} when is_binary(A) -> A;
                _ ->
                    case hb_message:signers(Init, Opts) of
                        [Single | _] -> Single;
                        _ -> undefined
                    end
            end
    end.

%% @doc Highest block height we've already folded in for this reference.
last_seen_block(RefID, Base, Opts) ->
    case cache_read(latest_path(RefID), Opts) of
        {ok, Latest} -> meta_block(Latest, Opts);
        _ ->
            case init_message(Base, RefID, Opts) of
                undefined -> 0;
                Init -> meta_block(Init, Opts)
            end
    end.

%% @doc Fold validated `set' messages into local state. Items must arrive
%% in Arweave order (block ascending, then natural GQL order within a
%% block). The gateway query enforces this via `sort: HEIGHT_ASC'.
apply_items(RefID, Authority, Items, Opts) ->
    {LastTs, _} = last_set_state(RefID, Opts),
    State0 = #{ authority => Authority, last_set_ts => LastTs },
    lists:foldl(
        fun(Item, S) -> maybe_apply_item(RefID, Item, S, Opts) end,
        State0,
        Items).

%% @doc Timestamp + block height of the most-recently-applied set.
last_set_state(RefID, Opts) ->
    case cache_read(latest_path(RefID), Opts) of
        {ok, Latest} ->
            {
                ts_int(hb_maps:get(<<"timestamp">>, Latest, 0, Opts)),
                meta_block(Latest, Opts)
            };
        _ -> {0, 0}
    end.

maybe_apply_item(RefID, Item, State, Opts) ->
    Authority = maps:get(authority, State),
    case signed_by(Item, Authority, Opts) of
        true ->
            Ts = ts_int(hb_maps:get(<<"timestamp">>, Item, 0, Opts)),
            case Ts > maps:get(last_set_ts, State) of
                true ->
                    ok = store_set(RefID, Item, Opts),
                    State#{ last_set_ts => Ts };
                false ->
                    ?event(reference,
                        {rejected,
                            {ref, RefID},
                            {reason, stale_timestamp}}),
                    State
            end;
        false ->
            ?event(reference,
                {rejected, {ref, RefID}, {reason, bad_authority}}),
            State
    end.

signed_by(_Msg, undefined, _Opts) -> false;
signed_by(Msg, Authority, Opts) when is_binary(Authority) ->
    lists:member(Authority, hb_message:signers(Msg, Opts))
        andalso hb_message:verify(Msg, Authority, Opts).

%%%-------------------------------------------------------------------
%%% Cache writes
%%%-------------------------------------------------------------------

store_set(RefID, Set, Opts) ->
    RefOpts = reference_opts(Opts),
    {ok, _} = hb_cache:write(Set, RefOpts),
    SignedID = hb_message:id(Set, signed, Opts),
    Ts = hb_util:bin(ts_int(hb_maps:get(<<"timestamp">>, Set, 0, Opts))),
    Base = base_path(RefID),
    ok =
        hb_store:link(
            #{ <<Base/binary, "/sets/", Ts/binary>> => SignedID }, RefOpts),
    update_latest_if_newer(RefID, Set, SignedID, Opts).

update_latest_if_newer(RefID, NewSet, SignedID, Opts) ->
    NewTs = ts_int(hb_maps:get(<<"timestamp">>, NewSet, 0, Opts)),
    Latest = latest_path(RefID),
    Update =
        case cache_read(Latest, Opts) of
            {ok, Curr} ->
                NewTs > ts_int(hb_maps:get(<<"timestamp">>, Curr, 0, Opts));
            _ -> true
        end,
    case Update of
        true -> hb_store:link(#{ Latest => SignedID }, reference_opts(Opts));
        _ -> ok
    end.

%%%-------------------------------------------------------------------
%%% Gateway lookup (self-contained; built on hb_client_gateway primitives)
%%%-------------------------------------------------------------------

%% @doc Fetch the latest `set' heads for the reference from the gateway,
%% filtering by:
%%   * owner address (the reference's authority), so that messages signed
%%     by anyone else are dropped at the gateway and not paid for.
%%   * the `reference-id' tag, so only messages targeting this reference
%%     are returned.
%%   * a lower bound on Arweave block height. We pass
%%     `min-block = (last-applied-block - 1)' so messages at the boundary
%%     block are not skipped when ties are resolved by Arweave offset;
%%     this keeps the query off the full transactions table.
%%
%% Results come back in `HEIGHT_ASC' order. The query only asks for candidate
%% IDs; each ID is loaded through `hb_cache:read/2' before being decorated with
%% `priv.reference.block-height' (and the GQL cursor) for downstream ordering
%% and pagination.
fetch_reference_heads(RefID, Authority, MinBlock, Opts) ->
    Query = build_reference_query(Authority, RefID, MinBlock, 100),
    fetch_reference_heads(RefID, Query, #{}, [], Opts).

fetch_reference_heads(RefID, Query, Vars, Pages, Opts) ->
    case hb_client_gateway:query(Query, Vars, Opts) of
        {error, Reason} ->
            case empty_reference_query_result(Reason, Opts) of
                true ->
                    {ok, lists:append(lists:reverse(Pages))};
                false ->
                    ?event(reference,
                        {gateway_error, {ref, RefID}, {reason, Reason}}),
                    {error, Reason}
            end;
        {ok, GqlMsg} ->
            Tx = hb_util:deep_get(<<"data/transactions">>, GqlMsg, #{}, Opts),
            Edges = hb_maps:get(<<"edges">>, Tx, [], Opts),
            Items = edges_to_messages(Edges, Opts),
            case hb_util:deep_get(<<"pageInfo/hasNextPage">>, Tx, false, Opts) of
                true ->
                    case last_cursor(Edges, Opts) of
                        {ok, Cursor} ->
                            fetch_reference_heads(
                                RefID,
                                Query,
                                Vars#{ <<"after">> => Cursor },
                                [Items | Pages],
                                Opts);
                        error ->
                            {error, <<"missing-page-cursor">>}
                    end;
                false ->
                    {ok, lists:append(lists:reverse([Items | Pages]))}
            end
    end.

empty_reference_query_result({no_viable_responses, Responses}, Opts) ->
    Responses =/= []
        andalso
            lists:all(
                fun(Response) -> empty_reference_query_response(Response, Opts) end,
                Responses);
empty_reference_query_result(_, _Opts) ->
    false.

empty_reference_query_response({ok, #{ <<"body">> := Body }}, Opts) ->
    try
        [] =
            hb_ao:get(
                <<"data/transactions/edges">>,
                hb_json:decode(Body),
                Opts),
        true
    catch
        _:_ -> false
    end;
empty_reference_query_response(_, _Opts) ->
    false.

build_reference_query(Authority, RefID, MinBlock, Limit) ->
    OwnerJSON =
        json_string_array(
            case Authority of
                Bin when is_binary(Bin) -> [Bin];
                List when is_list(List) -> List
            end),
    RefIDJSON = json_string_array([RefID]),
    LimitBin = integer_to_binary(Limit),
    MinBlockBin = integer_to_binary(MinBlock),
    <<
        "query($after: String) { ",
            "transactions(",
                "owners: ", OwnerJSON/binary, ", ",
                "tags: [",
                    "{ name: \"reference-id\" values: ",
                        RefIDJSON/binary,
                    " }",
                "], ",
                "block: { min: ", MinBlockBin/binary, " }, ",
                "sort: HEIGHT_ASC, ",
                "first: ", LimitBin/binary,
                ", after: $after",
            "){ ",
                "pageInfo { hasNextPage } ",
                "edges { ",
                    "node { ",
                        "id ",
                        "block { id height timestamp } ",
                    "} ",
                    "cursor ",
                "} ",
            "} ",
        "}"
    >>.

json_string_array(Values) ->
    Quoted =
        [<<"\"", V/binary, "\"">> || V <- Values, is_binary(V)],
    iolist_to_binary([<<"[">>, lists:join($,, Quoted), <<"]">>]).

edges_to_messages(Edges, Opts) ->
    lists:filtermap(
        fun(Edge) -> edge_to_message(Edge, Opts) end,
        Edges).

last_cursor([], _Opts) -> error;
last_cursor(Edges, Opts) ->
    hb_maps:find(<<"cursor">>, lists:last(Edges), Opts).

edge_to_message(Edge, Opts) ->
    Node = hb_maps:get(<<"node">>, Edge, #{}, Opts),
    case hb_maps:get(<<"id">>, Node, undefined, Opts) of
        ID when is_binary(ID) ->
            try cache_read(ID, Opts) of
                {ok, Msg} -> {true, decorate_with_block(Msg, Node, Edge, Opts)};
                _ -> false
            catch
                _:_ -> false
            end;
        _ -> false
    end.

decorate_with_block(Msg, Node, Edge, Opts) ->
    BlockHeight =
        hb_util:deep_get([<<"block">>, <<"height">>], Node, 0, Opts),
    Cursor = hb_maps:get(<<"cursor">>, Edge, undefined, Opts),
    Existing = hb_maps:get(<<"priv">>, Msg, #{}, Opts),
    ExistingRef = hb_maps:get(<<"reference">>, Existing, #{}, Opts),
    Msg#{
        <<"priv">> =>
            Existing#{
                <<"reference">> =>
                    ExistingRef#{
                        <<"block-height">> => BlockHeight,
                        <<"cursor">> => Cursor
                    }
            }
    }.

%%%-------------------------------------------------------------------
%%% Freshness / max-age
%%%
%%% Each successful `refresh' records the local wall-clock second at which the
%%% reference was last validated against the gateway. `get/4' uses that time
%%% and an effective `max-age' to decide whether to serve the cached value
%%% (`compute') or revalidate first (`now'). The recorded time is local cache
%%% metadata -- not part of the reference's signed state -- and is the device's
%%% analogue of an HTTP `Age'.
%%%-------------------------------------------------------------------

%% @doc Is the reference's local view older than the effective `max-age'? An
%% `infinity' max-age (the default, or `cache-control: only-if-cached') is
%% never stale; a finite max-age with no recorded refresh is always stale.
stale(Base, Req, Opts) ->
    case effective_max_age(Req, Opts) of
        infinity -> false;
        MaxAge ->
            case reference_age(reference_id(Base, Opts), Opts) of
                undefined -> true;
                Age -> Age > MaxAge
            end
    end.

%% @doc The `max-age' (seconds) to honour: the request's `max-age', else the
%% node's `reference-max-age', else `infinity'. `cache-control: only-if-cached'
%% forces `infinity' (resolve purely from the cache).
effective_max_age(Req, Opts) ->
    case hb_maps:get(<<"cache-control">>, Req, undefined, Opts) of
        <<"only-if-cached">> -> infinity;
        _ ->
            case hb_maps:find(<<"max-age">>, Req, Opts) of
                {ok, Raw} -> normalize_max_age(Raw);
                _ ->
                    normalize_max_age(
                        hb_opts:get(<<"reference-max-age">>, infinity, Opts))
            end
    end.

normalize_max_age(infinity) -> infinity;
normalize_max_age(<<"infinity">>) -> infinity;
normalize_max_age(MaxAge) -> ts_int(MaxAge).

%% @doc Seconds since the reference was last refreshed on this node, or
%% `undefined' if it never has been.
reference_age(RefID, Opts) ->
    case read_refreshed_at(RefID, Opts) of
        undefined -> undefined;
        RefreshedAt -> max(0, clock(Opts) - RefreshedAt)
    end.

%% @doc Record that the reference was validated against the gateway now.
mark_refreshed(RefID, Opts) ->
    _ = hb_store:write(
        #{ refreshed_path(RefID) => hb_util:bin(clock(Opts)) },
        reference_opts(Opts)),
    ok.

read_refreshed_at(RefID, Opts) ->
    case hb_store:read(refreshed_path(RefID), reference_opts(Opts)) of
        {ok, Bin} -> ts_int(Bin);
        _ -> undefined
    end.

%% @doc Local wall-clock seconds, overridable via the `reference-clock' option
%% so freshness decisions are deterministically testable.
clock(Opts) ->
    case hb_opts:get(<<"reference-clock">>, undefined, Opts) of
        undefined -> erlang:system_time(second);
        Time -> ts_int(Time)
    end.

%%%-------------------------------------------------------------------
%%% Path helpers
%%%-------------------------------------------------------------------

base_path(RefID) ->
    <<"~reference@1.0/", RefID/binary>>.

init_path(RefID) ->
    <<(base_path(RefID))/binary, "/init">>.

latest_path(RefID) ->
    <<(base_path(RefID))/binary, "/latest">>.

refreshed_path(RefID) ->
    <<(base_path(RefID))/binary, "/refreshed-at">>.

%%%-------------------------------------------------------------------
%%% Type helpers
%%%-------------------------------------------------------------------

ts_int(undefined) -> 0;
ts_int(0) -> 0;
ts_int(<<>>) -> 0;
ts_int(V) -> hb_util:int(V).

%% @doc Read the gateway-derived block height attached to a message by
%% `fetch_reference_heads/4'. Returns `0' when missing.
meta_block(Msg, Opts) ->
    Priv = hb_maps:get(<<"priv">>, Msg, #{}, Opts),
    Ref = hb_maps:get(<<"reference">>, Priv, #{}, Opts),
    ts_int(hb_maps:get(<<"block-height">>, Ref, 0, Opts)).

cache_read(Path, Opts) ->
    case hb_cache:read(Path, reference_opts(Opts)) of
        {ok, _} = Ok -> Ok;
        not_found -> not_found;
        {error, _} = Err -> Err
    end.

reference_opts(Opts) ->
    case hb_opts:get(<<"reference-store">>, undefined, Opts) of
        undefined -> Opts;
        RefStore ->
            RefOpts = Opts#{ <<"cache-control">> => [<<"always">>] },
            RefOpts#{
                <<"store">> =>
                    normalize_store(RefStore)
                        ++ normalize_store(hb_opts:get(<<"store">>, [], RefOpts))
            }
    end.

normalize_store(Stores) when is_list(Stores) -> Stores;
normalize_store(Store) -> [Store].

%%%-------------------------------------------------------------------
%%% Tests
%%%-------------------------------------------------------------------

-ifdef(TEST).

addr(Wallet) -> hb_util:human_id(Wallet).

%% Each test allocates a fresh store and wallet so cases don't bleed.
fresh_opts() ->
    #{ <<"store">> => hb_test_utils:test_store() }.

opts_with_wallet(BaseOpts, Wallet) ->
    BaseOpts#{ <<"priv-wallet">> => Wallet }.

build_init(Wallet, BaseOpts) ->
    Opts = opts_with_wallet(BaseOpts, Wallet),
    Init =
        hb_message:commit(
            #{
                <<"device">> => <<"reference@1.0">>,
                <<"timestamp">> => 1
            },
            Opts),
    RefID = hb_message:id(Init, signed, Opts),
    {RefID, Init}.

build_set(Wallet, RefID, Ts, Value, BaseOpts) ->
    hb_message:commit(
        #{
            <<"device">> => <<"reference@1.0">>,
            <<"reference-id">> => RefID,
            <<"timestamp">> => Ts,
            <<"reference-value">> => Value
        },
        opts_with_wallet(BaseOpts, Wallet)).

decorate(Msg, Block) ->
    Msg#{
        <<"priv">> =>
            #{ <<"reference">> => #{ <<"block-height">> => Block } }
    }.

prime_init(RefID, Init, Opts) ->
    {ok, _} = hb_cache:write(Init, Opts),
    InitID = hb_message:id(Init, signed, Opts),
    ok = hb_store:link(#{ init_path(RefID) => InitID }, Opts).

prime_set(RefID, Init, SetMsg, Block, Opts) ->
    prime_init(RefID, Init, Opts),
    Decorated = decorate(SetMsg, Block),
    {ok, _} = hb_cache:write(Decorated, Opts),
    SignedID = hb_message:id(Decorated, signed, Opts),
    ok = hb_store:link(#{ latest_path(RefID) => SignedID }, Opts),
    Decorated.

reference_id_from_init_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, Init} = build_init(Wallet, Opts),
    ?assertEqual(RefID, reference_id(Init, Opts)).

reference_id_from_set_message_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, _} = build_init(Wallet, Opts),
    Set = build_set(Wallet, RefID, 2, #{ <<"value">> => 1 }, Opts),
    ?assertEqual(RefID, reference_id(Set, Opts)).

is_init_classification_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, Init} = build_init(Wallet, Opts),
    Set = build_set(Wallet, RefID, 2, #{}, Opts),
    ?assert(is_init(Init, Opts)),
    ?assertNot(is_init(Set, Opts)).

effective_value_falls_back_to_message_test() ->
    Msg = #{ <<"foo">> => <<"bar">> },
    ?assertEqual(Msg, effective_value(Msg, #{})),
    Msg2 = Msg#{ <<"reference-value">> => #{ <<"baz">> => 1 } },
    ?assertEqual(#{ <<"baz">> => 1 }, effective_value(Msg2, #{})).

compute_returns_init_when_no_set_applied_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, Init} = build_init(Wallet, Opts),
    prime_init(RefID, Init, Opts),
    {ok, Got} = compute(Init, #{}, Opts),
    ?assertEqual(
        hb_message:id(Init, signed, Opts),
        hb_message:id(Got, signed, Opts)).

compute_returns_latest_set_value_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, Init} = build_init(Wallet, Opts),
    Set = build_set(Wallet, RefID, 2, #{ <<"x">> => 42 }, Opts),
    _ = prime_set(RefID, Init, Set, 100, Opts),
    {ok, Value} = compute(Init, #{}, Opts),
    ?assertEqual(42, hb_ao:get(<<"x">>, Value, Opts)).

get_resolves_key_through_latest_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, Init} = build_init(Wallet, Opts),
    Set = build_set(Wallet, RefID, 2, #{ <<"x">> => 7 }, Opts),
    _ = prime_set(RefID, Init, Set, 100, Opts),
    Req = #{ <<"cache-control">> => <<"only-if-cached">> },
    {ok, Value} = get(<<"x">>, Init, Req, Opts),
    ?assertEqual(7, Value).

stale_set_is_ignored_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    {RefID, Init} = build_init(Wallet, Opts),
    Set5 = build_set(Wallet, RefID, 5, #{ <<"x">> => <<"new">> }, Opts),
    Set3 = build_set(Wallet, RefID, 3, #{ <<"x">> => <<"old">> }, Opts),
    _ = prime_set(RefID, Init, Set5, 100, Opts),
    State =
        apply_items(
            RefID,
            addr(Wallet),
            [decorate(Set3, 101)],
            Opts),
    ?assertEqual(5, maps:get(last_set_ts, State)),
    {ok, Value} = compute(Init, #{}, Opts),
    ?assertEqual(<<"new">>, hb_ao:get(<<"x">>, Value, Opts)).

set_from_wrong_authority_is_ignored_test() ->
    Opts = fresh_opts(),
    Authority = ar_wallet:new(),
    Imposter = ar_wallet:new(),
    {RefID, Init} = build_init(Authority, Opts),
    prime_init(RefID, Init, Opts),
    Bogus =
        build_set(
            Imposter, RefID, 99, #{ <<"x">> => <<"hax">> }, Opts),
    State =
        apply_items(
            RefID,
            addr(Authority),
            [decorate(Bogus, 100)],
            Opts),
    ?assertEqual(0, maps:get(last_set_ts, State)),
    ?assertNotMatch({ok, _}, cache_read(latest_path(RefID), Opts)).

tampered_set_from_authority_is_ignored_test() ->
    Opts = fresh_opts(),
    Authority = ar_wallet:new(),
    {RefID, _Init} = build_init(Authority, Opts),
    Set = build_set(Authority, RefID, 2, #{ <<"x">> => <<"ok">> }, Opts),
    Tampered = Set#{ <<"reference-value">> => #{ <<"x">> => <<"hax">> } },
    ?assert(signed_by(Set, addr(Authority), Opts)),
    ?assertNot(signed_by(Tampered, addr(Authority), Opts)).

reference_query_paginates_without_device_filter_test() ->
    Query = build_reference_query(<<"AUTH">>, <<"REF">>, 10, 100),
    ?assertNotEqual(nomatch, binary:match(Query, <<"query($after: String)">>)),
    ?assertNotEqual(nomatch, binary:match(Query, <<", after: $after">>)),
    ?assertNotEqual(nomatch, binary:match(Query, <<"pageInfo { hasNextPage }">>)),
    ?assertEqual(nomatch, binary:match(Query, <<"device">>)),
    ?assertEqual(nomatch, binary:match(Query, <<"signature">>)),
    ?assertEqual(nomatch, binary:match(Query, <<"owner { key }">>)),
    ?assertNotEqual(nomatch, binary:match(Query, <<"node { id block">>)),
    ?assertNotEqual(nomatch, binary:match(Query, <<"reference-id">>)).

%% @doc End-to-end: a `name-resolvers' entry pointing at a reference makes
%% name lookups read the reference's current value, and updating the
%% reference (locally) changes what the name resolves to without touching
%% the node's config.
name_resolves_through_reference_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    OptsW = opts_with_wallet(Opts, Wallet),
    %% 1. Init the reference with reference-value = {foo => value-1}.
    Init =
        hb_message:commit(
            #{
                <<"device">> => <<"reference@1.0">>,
                <<"timestamp">> => 1,
                <<"reference-value">> => #{ <<"foo">> => <<"value-1">> }
            },
            OptsW),
    RefID = hb_message:id(Init, signed, OptsW),
    prime_init(RefID, Init, OptsW),
    %% 2a. Sanity-check resolution in-process before any HTTP. The bare key
    %%     path serves the reference's current value from the cache; no
    %%     explicit `compute' step is needed.
    RefPath = <<RefID/binary, "~reference@1.0">>,
    {ok, DirectFoo} = hb_ao:resolve(<<RefPath/binary, "/foo">>, OptsW),
    ?event({direct_foo, DirectFoo}),
    ?assertEqual(<<"value-1">>, DirectFoo),
    %% 2b. Start a node with a name-resolver pointing at the reference, so
    %%     lookups never reach the gateway. Bind an ephemeral port (`0') so the
    %%     test never contends for the default. A reference is mutable but its
    %%     resolution path is constant, so the node's default
    %%     `cache-control: always' would pin the first value and mask later
    %%     updates; override `http-extra-opts' so reads stay fresh -- the
    %%     required configuration for any node serving mutable references.
    NodeOpts =
        OptsW#{
            <<"name-resolvers">> => [RefPath],
            <<"port">> => 0,
            <<"http-extra-opts">> =>
                #{
                    <<"force-message">> => true,
                    <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
                }
        },
    Node = hb_http_server:start_node(NodeOpts),
    %% 3a. HTTP-direct: confirm the reference device is loaded by the node.
    {ok, DirectV1} =
        hb_http:get(
            Node,
            <<"/", RefID/binary, "~reference@1.0/foo">>,
            NodeOpts),
    ?assertEqual(<<"value-1">>, DirectV1),
    %% 3b. Through name@1.0 -- should return value-1.
    {ok, V1} = hb_http:get(Node, <<"/~name@1.0/foo&load=false">>, NodeOpts),
    ?assertEqual(<<"value-1">>, V1),
    %% 4. Update the reference locally with a new set at a higher timestamp.
    Set =
        hb_message:commit(
            #{
                <<"device">> => <<"reference@1.0">>,
                <<"reference-id">> => RefID,
                <<"timestamp">> => 2,
                <<"reference-value">> => #{ <<"foo">> => <<"value-2">> }
            },
            OptsW),
    _ = apply_items(RefID, addr(Wallet), [decorate(Set, 100)], NodeOpts),
    %% 5. Resolve `foo' again -- name-resolvers unchanged, value is new.
    {ok, V2} = hb_http:get(Node, <<"/~name@1.0/foo&load=false">>, NodeOpts),
    ?assertEqual(<<"value-2">>, V2).

%%%-------------------------------------------------------------------
%%% Reference-set tests
%%%
%%% A reference *set* is a `~reference@1.0' reference whose value is a
%%% directory mapping a (large) number of names to *pointers* at other,
%%% downstream references. A pointer is the minimal handle
%%% `#{ device => reference@1.0, reference-id => DownstreamID }'. Because
%%% `reference_id/2' honours an explicit `reference-id', and AO-Core derives
%%% each path step's device from the current message, the chain
%%% `SetID~reference@1.0/compute/<name>/compute/<key>' flows from the
%%% directory into the downstream reference's current value. Each downstream
%%% reference is governed by its own authority and updates independently of
%%% the directory and of every other downstream.
%%%-------------------------------------------------------------------

ref_name(I) -> <<"name-", (integer_to_binary(I))/binary>>.

ref_value(I) -> <<"value-", (integer_to_binary(I))/binary>>.

%% @doc The minimal downstream-reference handle stored in a set's directory.
reference_pointer(DownstreamID) ->
    #{
        <<"device">> => <<"reference@1.0">>,
        <<"reference-id">> => DownstreamID
    }.

%% @doc Commit a `~reference@1.0' init carrying the given `reference-value'.
commit_reference(Wallet, ReferenceValue, BaseOpts) ->
    hb_message:commit(
        #{
            <<"device">> => <<"reference@1.0">>,
            <<"timestamp">> => 1,
            <<"reference-value">> => ReferenceValue
        },
        opts_with_wallet(BaseOpts, Wallet)).

%% @doc Create one downstream reference per `#{ Name => Value }' entry,
%% priming each into the cache. Returns `#{ Name => DownstreamID }'.
build_downstreams(Wallet, NameValues, BaseOpts) ->
    Opts = opts_with_wallet(BaseOpts, Wallet),
    maps:map(
        fun(_Name, Value) ->
            Init = commit_reference(Wallet, #{ <<"value">> => Value }, BaseOpts),
            DownstreamID = hb_message:id(Init, signed, Opts),
            prime_init(DownstreamID, Init, Opts),
            DownstreamID
        end,
        NameValues).

%% @doc Build a reference set over `NameValues': one downstream reference per
%% name, plus a directory reference mapping each name to a pointer at its
%% downstream. Returns `{SetID, #{ Name => DownstreamID }}'.
build_reference_set(Wallet, NameValues, BaseOpts) ->
    Opts = opts_with_wallet(BaseOpts, Wallet),
    Downstreams = build_downstreams(Wallet, NameValues, BaseOpts),
    Directory =
        maps:map(
            fun(_Name, DownstreamID) -> reference_pointer(DownstreamID) end,
            Downstreams),
    SetInit = commit_reference(Wallet, Directory, BaseOpts),
    SetID = hb_message:id(SetInit, signed, Opts),
    prime_init(SetID, SetInit, Opts),
    {SetID, Downstreams}.

%% @doc Resolve a name through the set and into its downstream reference's
%% current `value'. Each hop is the device's default key resolver, which
%% serves from the local cache under the default `infinity' max-age -- no
%% explicit `compute' step is required.
resolve_through_set(SetID, Name, Opts) ->
    hb_ao:resolve(
        <<SetID/binary, "~reference@1.0/", Name/binary, "/value">>,
        Opts).

%% @doc Read the downstream ID a directory pointer points at, loading it from
%% the cache if it is stored as a link.
pointer_target(Pointer, Opts) ->
    hb_cache:ensure_loaded(
        hb_maps:get(<<"reference-id">>, Pointer, not_found, Opts), Opts).

%% @doc Scale: a set managing a large number of names, each pointing to a
%% distinct downstream reference. Every name maps to the right downstream,
%% and a spread of names resolves end-to-end to its downstream's value.
reference_set_resolves_many_names_test_() ->
    {timeout, 120, fun reference_set_resolves_many_names/0}.

reference_set_resolves_many_names() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    OptsW = opts_with_wallet(Opts, Wallet),
    N = 1000,
    NameValues =
        maps:from_list([ {ref_name(I), ref_value(I)} || I <- lists:seq(1, N) ]),
    {SetID, Downstreams} = build_reference_set(Wallet, NameValues, Opts),
    %% Directory: every one of the N names maps to the pointer at its own
    %% downstream reference.
    {ok, Directory} =
        hb_ao:resolve(<<SetID/binary, "~reference@1.0/compute">>, OptsW),
    lists:foreach(
        fun(I) ->
            Name = ref_name(I),
            Pointer = hb_maps:get(Name, Directory, not_found, OptsW),
            ?assertEqual(
                maps:get(Name, Downstreams),
                pointer_target(Pointer, OptsW))
        end,
        lists:seq(1, N)),
    %% Transitive: a spread of names resolves through the directory into its
    %% downstream reference's current value.
    lists:foreach(
        fun(I) ->
            ?assertEqual(
                {ok, ref_value(I)},
                resolve_through_set(SetID, ref_name(I), OptsW))
        end,
        sample_indices(N)),
    %% A name absent from the directory does not resolve.
    ?assertNotMatch(
        {ok, _},
        resolve_through_set(SetID, <<"name-absent">>, OptsW)).

%% @doc A spread of indices across `[1, N]' for sampling at scale.
sample_indices(N) ->
    lists:usort(
        [1, 2, N - 1, N | [ max(1, (I * N) div 16) || I <- lists:seq(1, 15) ]]).

%% @doc Updating one downstream reference changes only that name's resolved
%% value; the directory and the other downstreams are untouched.
reference_set_downstream_update_is_independent_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    OptsW = opts_with_wallet(Opts, Wallet),
    NameValues = #{ <<"alice">> => <<"alice-1">>, <<"bob">> => <<"bob-1">> },
    {SetID, Downstreams} = build_reference_set(Wallet, NameValues, Opts),
    AliceID = maps:get(<<"alice">>, Downstreams),
    ?assertEqual({ok, <<"alice-1">>}, resolve_through_set(SetID, <<"alice">>, OptsW)),
    ?assertEqual({ok, <<"bob-1">>}, resolve_through_set(SetID, <<"bob">>, OptsW)),
    %% Publish a higher-timestamp set to alice's downstream only.
    AliceSet =
        build_set(Wallet, AliceID, 2, #{ <<"value">> => <<"alice-2">> }, Opts),
    _ = apply_items(AliceID, addr(Wallet), [decorate(AliceSet, 100)], OptsW),
    %% alice reflects the update; bob and the directory are untouched.
    ?assertEqual({ok, <<"alice-2">>}, resolve_through_set(SetID, <<"alice">>, OptsW)),
    ?assertEqual({ok, <<"bob-1">>}, resolve_through_set(SetID, <<"bob">>, OptsW)).

%% @doc Updating the *set* reference (a total directory snapshot) adds a name
%% without minting or touching any other downstream reference.
reference_set_directory_update_adds_name_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    OptsW = opts_with_wallet(Opts, Wallet),
    {SetID, Downstreams} =
        build_reference_set(Wallet, #{ <<"alice">> => <<"alice-1">> }, Opts),
    %% `carol' is not in the directory yet.
    ?assertNotMatch({ok, _}, resolve_through_set(SetID, <<"carol">>, OptsW)),
    %% Mint carol's downstream reference and republish the directory with it.
    CarolInit = commit_reference(Wallet, #{ <<"value">> => <<"carol-1">> }, Opts),
    CarolID = hb_message:id(CarolInit, signed, OptsW),
    prime_init(CarolID, CarolInit, OptsW),
    NewDirectory =
        #{
            <<"alice">> => reference_pointer(maps:get(<<"alice">>, Downstreams)),
            <<"carol">> => reference_pointer(CarolID)
        },
    DirectorySet = build_set(Wallet, SetID, 2, NewDirectory, Opts),
    _ = apply_items(SetID, addr(Wallet), [decorate(DirectorySet, 100)], OptsW),
    %% carol now resolves; alice still resolves to its (unchanged) downstream.
    ?assertEqual({ok, <<"carol-1">>}, resolve_through_set(SetID, <<"carol">>, OptsW)),
    ?assertEqual({ok, <<"alice-1">>}, resolve_through_set(SetID, <<"alice">>, OptsW)).

%% @doc Each downstream reference is governed by its own authority: the set's
%% (directory) owner cannot forge a downstream's value, and only the
%% downstream's authority can update it.
reference_set_downstream_authority_is_isolated_test() ->
    Opts = fresh_opts(),
    SetOwner = ar_wallet:new(),
    AliceOwner = ar_wallet:new(),
    OwnerOpts = opts_with_wallet(Opts, AliceOwner),
    %% alice's downstream is governed by AliceOwner; the directory by SetOwner.
    AliceInit = commit_reference(AliceOwner, #{ <<"value">> => <<"alice-1">> }, Opts),
    AliceID = hb_message:id(AliceInit, signed, OwnerOpts),
    prime_init(AliceID, AliceInit, OwnerOpts),
    SetInit =
        commit_reference(
            SetOwner, #{ <<"alice">> => reference_pointer(AliceID) }, Opts),
    SetID = hb_message:id(SetInit, signed, opts_with_wallet(Opts, SetOwner)),
    prime_init(SetID, SetInit, opts_with_wallet(Opts, SetOwner)),
    ?assertEqual({ok, <<"alice-1">>}, resolve_through_set(SetID, <<"alice">>, Opts)),
    %% The directory owner cannot forge alice's value: alice's authority is
    %% AliceOwner, not SetOwner, so the set is rejected.
    Forged = build_set(SetOwner, AliceID, 2, #{ <<"value">> => <<"hax">> }, Opts),
    _ = apply_items(AliceID, addr(AliceOwner), [decorate(Forged, 100)], Opts),
    ?assertEqual({ok, <<"alice-1">>}, resolve_through_set(SetID, <<"alice">>, Opts)),
    %% alice's own authority can update it.
    Legit = build_set(AliceOwner, AliceID, 2, #{ <<"value">> => <<"alice-2">> }, Opts),
    _ = apply_items(AliceID, addr(AliceOwner), [decorate(Legit, 100)], Opts),
    ?assertEqual({ok, <<"alice-2">>}, resolve_through_set(SetID, <<"alice">>, Opts)).

%% @doc End-to-end over HTTP: a node with the set as a `name-resolver'
%% resolves names to downstream pointers (via `~name@1.0'), resolves the full
%% chain to downstream values, and reflects a downstream update. The node
%% overrides `http-extra-opts' so mutable reads are not pinned by the default
%% `cache-control: always' -- the required config for serving references.
reference_set_resolves_over_http_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    OptsW = opts_with_wallet(Opts, Wallet),
    NameValues = #{ <<"alice">> => <<"alice-1">>, <<"bob">> => <<"bob-1">> },
    {SetID, Downstreams} = build_reference_set(Wallet, NameValues, Opts),
    AliceID = maps:get(<<"alice">>, Downstreams),
    ResolverPath = <<SetID/binary, "~reference@1.0">>,
    NodeOpts =
        OptsW#{
            <<"name-resolvers">> => [ResolverPath],
            <<"port">> => 0,
            <<"http-extra-opts">> =>
                #{
                    <<"force-message">> => true,
                    <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
                }
        },
    Node = hb_http_server:start_node(NodeOpts),
    ChainPath =
        fun(Name) ->
            <<"/", SetID/binary, "~reference@1.0/", Name/binary, "/value">>
        end,
    %% Directory through name@1.0: alice resolves to her downstream pointer.
    {ok, AlicePointer} =
        hb_http:get(Node, <<"/~name@1.0/alice&load=false">>, NodeOpts),
    ?assertEqual(AliceID, pointer_target(AlicePointer, NodeOpts)),
    %% Full chain over HTTP into each downstream's current value.
    ?assertEqual({ok, <<"alice-1">>}, hb_http:get(Node, ChainPath(<<"alice">>), NodeOpts)),
    ?assertEqual({ok, <<"bob-1">>}, hb_http:get(Node, ChainPath(<<"bob">>), NodeOpts)),
    %% A downstream update is reflected through the same path; bob is unaffected.
    AliceSet =
        build_set(Wallet, AliceID, 2, #{ <<"value">> => <<"alice-2">> }, Opts),
    _ = apply_items(AliceID, addr(Wallet), [decorate(AliceSet, 100)], NodeOpts),
    ?assertEqual({ok, <<"alice-2">>}, hb_http:get(Node, ChainPath(<<"alice">>), NodeOpts)),
    ?assertEqual({ok, <<"bob-1">>}, hb_http:get(Node, ChainPath(<<"bob">>), NodeOpts)).

%%%-------------------------------------------------------------------
%%% Freshness / max-age tests
%%%-------------------------------------------------------------------

%% @doc The freshness decision honours a caller-supplied `max-age' (seconds)
%% against the recorded refresh time: within the window the reference is fresh
%% (served from cache), beyond it stale (revalidated). `infinity' and
%% `only-if-cached' are never stale; an unrefreshed reference is always stale
%% under a finite max-age.
reference_max_age_freshness_decision_test() ->
    Opts = fresh_opts(),
    {RefID, Init} = build_init(ar_wallet:new(), Opts),
    prime_init(RefID, Init, Opts),
    ok = mark_refreshed(RefID, Opts#{ <<"reference-clock">> => 100 }),
    Stale =
        fun(Clock, Req) ->
            stale(Init, Req, Opts#{ <<"reference-clock">> => Clock })
        end,
    ?assertNot(Stale(150, #{ <<"max-age">> => 60 })),  % age 50 =< 60
    ?assert(Stale(200, #{ <<"max-age">> => 60 })),     % age 100 > 60
    ?assertNot(Stale(100, #{ <<"max-age">> => 0 })),   % age 0
    ?assert(Stale(101, #{ <<"max-age">> => 0 })),      % any elapsed time
    ?assertNot(Stale(99999, #{ <<"max-age">> => <<"infinity">> })),
    ?assertNot(Stale(99999, #{ <<"cache-control">> => <<"only-if-cached">> })),
    %% A reference never refreshed on this node is stale under a finite age.
    {RefID2, Init2} = build_init(ar_wallet:new(), Opts),
    prime_init(RefID2, Init2, Opts),
    ?assert(
        stale(Init2, #{ <<"max-age">> => 60 }, Opts#{ <<"reference-clock">> => 100 })).

%% @doc Absent a request `max-age', the node's `reference-max-age' option is
%% the default; absent both, the reference is never refreshed on a read.
reference_max_age_default_from_node_option_test() ->
    Opts = fresh_opts(),
    {RefID, Init} = build_init(ar_wallet:new(), Opts),
    prime_init(RefID, Init, Opts),
    ok = mark_refreshed(RefID, Opts#{ <<"reference-clock">> => 100 }),
    Defaulted = Opts#{ <<"reference-max-age">> => 60 },
    ?assertNot(stale(Init, #{}, Defaulted#{ <<"reference-clock">> => 150 })),
    ?assert(stale(Init, #{}, Defaulted#{ <<"reference-clock">> => 200 })),
    %% No request max-age and no node default -> infinity -> never stale.
    ?assertNot(stale(Init, #{}, Opts#{ <<"reference-clock">> => 99999 })).

%% @doc Within max-age, the value is served straight from the cache: the bare
%% key path needs no `compute' segment, and a request `max-age' inside the
%% window resolves without reaching the gateway (the test store has none).
reference_max_age_serves_cache_without_gateway_test() ->
    Opts = fresh_opts(),
    Wallet = ar_wallet:new(),
    OptsW = opts_with_wallet(Opts, Wallet),
    Init = commit_reference(Wallet, #{ <<"x">> => 42 }, Opts),
    RefID = hb_message:id(Init, signed, OptsW),
    prime_init(RefID, Init, OptsW),
    ok = mark_refreshed(RefID, OptsW#{ <<"reference-clock">> => 100 }),
    %% Bare key path, default `infinity' max-age -> pure cache read.
    ?assertEqual(
        {ok, 42},
        hb_ao:resolve(<<RefID/binary, "~reference@1.0/x">>, OptsW)),
    %% Caller `max-age' within the window -> still a cache read (age 50 =< 60).
    ?assertEqual(
        {ok, 42},
        get(<<"x">>, Init, #{ <<"max-age">> => 60 },
            OptsW#{ <<"reference-clock">> => 150 })).

-endif.
