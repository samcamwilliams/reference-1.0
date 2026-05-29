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
%%% Network lookups for new `set' messages are performed via GraphQL using
%%% only the public {@link hb_client_gateway} primitives (`query/3' and
%%% `result_to_message/2'); the gateway-specific query is constructed inline
%%% so the device is self-contained and does not require any HyperBEAM core
%%% changes to operate.
-module(dev_reference).
-export([info/0, compute/3, now/3]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hb/include/hb.hrl").

%% @doc Default key lookup falls through to the latest incarnation of the
%% reference's keys and values, so that `GET /ReferenceID/Key' resolves the
%% mutable data underlying the reference.
info() ->
    #{
        default => fun get/4
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

%% @doc Default key resolver. Setting `cache-control: only-if-cached' will
%% cause the request to skip recomputing the latest message and fail if it
%% is not already cached locally.
get(Key, Base, Req, Opts) ->
    Path =
        case hb_maps:get(<<"cache-control">>, Req, undefined, Opts) of
            <<"only-if-cached">> -> <<"compute">>;
            _ -> <<"now">>
        end,
    case hb_ao:resolve(Base, Path, Opts) of
        {ok, Value} ->
            hb_ao:resolve(Value, Req#{ <<"path">> => Key }, Opts);
        {error, _} = Err -> Err
    end.

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
                    {ok, _} = hb_cache:write(Base, Opts),
                    SignedID = hb_message:id(Base, signed, Opts),
                    ok =
                        hb_store:link(
                            #{ init_path(RefID) => SignedID }, Opts);
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
    lists:member(Authority, hb_message:signers(Msg, Opts)).

%%%-------------------------------------------------------------------
%%% Cache writes
%%%-------------------------------------------------------------------

store_set(RefID, Set, Opts) ->
    {ok, _} = hb_cache:write(Set, Opts),
    SignedID = hb_message:id(Set, signed, Opts),
    Ts = hb_util:bin(ts_int(hb_maps:get(<<"timestamp">>, Set, 0, Opts))),
    Base = base_path(RefID),
    ok =
        hb_store:link(
            #{ <<Base/binary, "/sets/", Ts/binary>> => SignedID }, Opts),
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
        true -> hb_store:link(#{ Latest => SignedID }, Opts);
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
%% Results come back in `HEIGHT_ASC' order and are decorated with
%% `priv.reference.block-height' (and the GQL cursor) for downstream
%% ordering and pagination.
fetch_reference_heads(RefID, Authority, MinBlock, Opts) ->
    Query = build_reference_query(Authority, RefID, MinBlock, 100),
    case hb_client_gateway:query(Query, undefined, Opts) of
        {error, Reason} ->
            ?event(reference,
                {gateway_error, {ref, RefID}, {reason, Reason}}),
            {error, Reason};
        {ok, GqlMsg} ->
            Edges =
                hb_ao:get(
                    <<"data/transactions/edges">>, GqlMsg, [], Opts),
            {ok, edges_to_messages(Edges, Opts)}
    end.

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
        "query { ",
            "transactions(",
                "owners: ", OwnerJSON/binary, ", ",
                "tags: [",
                    "{ name: \"device\" values: [\"reference@1.0\"] }, ",
                    "{ name: \"reference-id\" values: ",
                        RefIDJSON/binary,
                    " }",
                "], ",
                "block: { min: ", MinBlockBin/binary, " }, ",
                "sort: HEIGHT_ASC, ",
                "first: ", LimitBin/binary,
            "){ ",
                "edges { ",
                    "node { ",
                        "id ",
                        "anchor ",
                        "signature ",
                        "recipient ",
                        "owner { key } ",
                        "fee { winston } ",
                        "quantity { winston } ",
                        "tags { name value } ",
                        "data { size } ",
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

edge_to_message(Edge, Opts) ->
    Node = hb_maps:get(<<"node">>, Edge, #{}, Opts),
    case hb_maps:get(<<"id">>, Node, undefined, Opts) of
        ID when is_binary(ID) ->
            case hb_client_gateway:result_to_message(Node, Opts) of
                {ok, Msg} ->
                    {true, decorate_with_block(Msg, Node, Edge, Opts)};
                _ -> false
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
%%% Path helpers
%%%-------------------------------------------------------------------

base_path(RefID) ->
    <<"~reference@1.0/", RefID/binary>>.

init_path(RefID) ->
    <<(base_path(RefID))/binary, "/init">>.

latest_path(RefID) ->
    <<(base_path(RefID))/binary, "/latest">>.

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
    case hb_cache:read(Path, Opts) of
        {ok, _} = Ok -> Ok;
        not_found -> not_found;
        {error, _} = Err -> Err
    end.

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
    %% 2a. Sanity-check the resolver path in-process before any HTTP.
    ResolverPath = <<RefID/binary, "~reference@1.0/compute">>,
    {ok, ComputeRes} = hb_ao:resolve(ResolverPath, OptsW),
    ?event({direct_compute, ComputeRes}),
    ?assertEqual(#{ <<"foo">> => <<"value-1">> }, ComputeRes),
    {ok, DirectFoo} =
        hb_ao:resolve(
            <<ResolverPath/binary, "/foo">>, OptsW),
    ?event({direct_foo, DirectFoo}),
    ?assertEqual(<<"value-1">>, DirectFoo),
    %% 2b. Start a node with a name-resolver pointing at the reference's
    %%     `compute' path, so lookups never reach the gateway.
    NodeOpts = OptsW#{ <<"name-resolvers">> => [ResolverPath] },
    Node = hb_http_server:start_node(NodeOpts),
    %% 3a. HTTP-direct: confirm the reference device is loaded by the node.
    {ok, DirectV1} =
        hb_http:get(
            Node,
            <<"/", RefID/binary, "~reference@1.0/compute/foo">>,
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

-endif.
