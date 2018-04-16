-module(component_helper).

% API
-export([connect_component/1,
         connect_component/2,
         disconnect_component/2,
         disconnect_components/2,
         connect_component_subdomain/1
        ]).

-export([component_start_stream/2,
         component_stream_start/2,
         component_handshake/2,
         component_start_stream_subdomain/2
        ]).

-include_lib("escalus/include/escalus.hrl").
-include_lib("exml/include/exml_stream.hrl").

connect_component(Component) ->
    connect_component(Component, component_start_stream).

connect_component(ComponentOpts, StartStep) ->
    Res = escalus_connection:start(ComponentOpts,
                                   [{?MODULE, StartStep},
                                    {?MODULE, component_handshake}]),
    case Res of
        {ok, Component, _} ->
            {component, ComponentName} = lists:keyfind(component, 1, ComponentOpts),
            {server, ComponentServer} = lists:keyfind(server, 1, ComponentOpts),
            ComponentAddr = <<ComponentName/binary, ".", ComponentServer/binary>>,
            {Component, ComponentAddr, ComponentName};
        {error, E} ->
            throw(cook_connection_step_error(E))
    end.

disconnect_component(Component, Addr) ->
    disconnect_components([Component], Addr).

disconnect_components(Components, Addr) ->
    %% TODO replace 'kill' with 'stop' when server supports stream closing
    [escalus_connection:kill(Component) || Component <- Components],
    mongoose_helper:wait_until(fun() -> rpc(ejabberd_router, lookup_component, [Addr]) =:= [] end, 5, 200).

rpc(M, F, A) ->
    Node = ct:get_config({hosts, mim, node}),
    Cookie = escalus_ct:get_config(ejabberd_cookie),
    escalus_ct:rpc_call(Node, M, F, A, 10000, Cookie).

cook_connection_step_error(E) ->
    {connection_step_failed, Step, Reason} = E,
    {StepDef, _, _} = Step,
    {EDef, _} = Reason,
    {EDef, StepDef}.

component_start_stream(Conn = #client{props = Props}, []) ->
    {server, Server} = lists:keyfind(server, 1, Props),
    {component, Component} = lists:keyfind(component, 1, Props),

    ComponentHost = <<Component/binary, ".", Server/binary>>,
    StreamStart = component_stream_start(ComponentHost, false),
    ok = escalus_connection:send(Conn, StreamStart),
    StreamStartRep = escalus_connection:get_stanza(Conn, wait_for_stream),

    #xmlstreamstart{attrs = Attrs} = StreamStartRep,
    Id = proplists:get_value(<<"id">>, Attrs),

    {Conn#client{props = [{sid, Id}|Props]}, []}.

component_stream_start(Component, IsSubdomain) ->
    Attrs1 = [{<<"to">>, Component},
              {<<"xmlns">>, <<"jabber:component:accept">>},
              {<<"xmlns:stream">>,
               <<"http://etherx.jabber.org/streams">>}],
    Attrs2 = case IsSubdomain of
                 false ->
                     Attrs1;
                 true ->
                     [{<<"is_subdomain">>, <<"true">>}|Attrs1]
             end,
    #xmlstreamstart{name = <<"stream:stream">>, attrs = Attrs2}.

component_handshake(Conn = #client{props = Props}, []) ->
    {password, Password} = lists:keyfind(password, 1, Props),
    {sid, SID} = lists:keyfind(sid, 1, Props),

    Handshake = component_handshake_el(SID, Password),
    ok = escalus_connection:send(Conn, Handshake),

    HandshakeRep = escalus_connection:get_stanza(Conn, handshake),
    case HandshakeRep of
        #xmlel{name = <<"handshake">>, children = []} ->
            {Conn, []};
        #xmlel{name = <<"stream:error">>} ->
            throw({stream_error, HandshakeRep})
    end.

component_handshake_el(SID, Password) ->
    Handshake = crypto:hash(sha, <<SID/binary, Password/binary>>),
    #xmlel{name = <<"handshake">>,
           children = [#xmlcdata{content = base16:encode(Handshake)}]}.

component_start_stream_subdomain(Conn = #client{props = Props}, []) ->
    {component, Component} = lists:keyfind(component, 1, Props),

    StreamStart = component_stream_start(Component, true),
    ok = escalus_connection:send(Conn, StreamStart),
    StreamStartRep = escalus_connection:get_stanza(Conn, wait_for_stream),

    #xmlstreamstart{attrs = Attrs} = StreamStartRep,
    Id = proplists:get_value(<<"id">>, Attrs),

    {Conn#client{props = [{sid, Id}|Props]}, []}.

connect_component_subdomain(Component) ->
    connect_component(Component, component_start_stream_subdomain).
