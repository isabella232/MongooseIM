-module(push_SUITE).
-compile(export_all).
-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("exml/include/exml.hrl").
-include("push_helper.hrl").

-import(muc_light_helper,
    [
        room_bin_jid/1,
        create_room/6
    ]).
-import(escalus_ejabberd, [rpc/3]).
-import(push_helper, [
    enable_stanza/2, enable_stanza/3, enable_stanza/4,
    disable_stanza/1, disable_stanza/2, become_unavailable/1
]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [
        {group, disco},
        {group, toggling},
        {group, pubsub_ful},
        {group, pubsub_less}
    ].

groups() ->
    G = [
         {disco, [], [
                      push_notifications_listed_disco_when_available,
                      push_notifications_not_listed_disco_when_not_available
                     ]},
         {toggling, [parallel], [
                                 enable_should_fail_with_missing_attributes,
                                 enable_should_fail_with_invalid_attributes,
                                 enable_should_succeed_without_form,
                                 enable_with_form_should_fail_with_incorrect_from,
                                 enable_should_accept_correct_from,
                                 disable_should_fail_with_missing_attributes,
                                 disable_should_fail_with_invalid_attributes,
                                 disable_all,
                                 disable_node
                                ]},
         {pubsub_ful, [], notification_groups()},
         {pubsub_less, [], notification_groups()},
         {pm_msg_notifications, [parallel], [
                                             pm_no_msg_notifications_if_not_enabled,
                                             pm_no_msg_notifications_if_user_online,
                                             pm_msg_notify_if_user_offline,
                                             pm_msg_notify_if_user_offline_with_publish_options,
                                             pm_msg_notify_stops_after_disabling
                                            ]},
         {muclight_msg_notifications, [parallel], [
                                                   muclight_no_msg_notifications_if_not_enabled,
                                                   muclight_no_msg_notifications_if_user_online,
                                                   muclight_msg_notify_if_user_offline,
                                                   muclight_msg_notify_if_user_offline_with_publish_options,
                                                   muclight_msg_notify_stops_after_disabling
                                                  ]}
        ],
    ct_helper:repeat_all_until_all_ok(G).

notification_groups() ->
    [
     {group, pm_msg_notifications},
     {group, muclight_msg_notifications}
    ].

suite() ->
    escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

%% --------------------- Callbacks ------------------------

init_per_suite(Config) ->
    %% For mocking with unnamed functions
    mongoose_helper:inject_module(?MODULE),
    escalus:init_per_suite(Config).
end_per_suite(Config) ->
    escalus_fresh:clean(),
    escalus:end_per_suite(Config).

init_per_group(disco, Config) ->
    escalus:create_users(Config, escalus:get_users([alice]));
init_per_group(pubsub_ful, Config) ->
    [{pubsub_host, real} | Config];
init_per_group(pubsub_less, Config) ->
    [{pubsub_host, virtual} | Config];
init_per_group(muclight_msg_notifications, Config0) ->
    Host = ct:get_config({hosts, mim, domain}),
    Config = ensure_pusher_module_and_save_old_mods(Config0),
    dynamic_modules:ensure_modules(Host, [{mod_muc_light,
                                           [{host, binary_to_list(?MUCHOST)},
                                            {backend, mongoose_helper:mnesia_or_rdbms_backend()},
                                            {rooms_in_rosters, true}]}]),
    rpc(mod_muc_light_db_backend, force_clear, []),
    Config;
init_per_group(_, Config) ->
    ensure_pusher_module_and_save_old_mods(Config).

end_per_group(disco, Config) ->
    escalus:delete_users(Config),
    Config;
end_per_group(ComplexGroup, Config) when ComplexGroup == pubsub_ful;
                                         ComplexGroup == pubsub_less ->
    Config;
end_per_group(_, Config) ->
    restore_modules(Config),
    Config.

init_per_testcase(CaseName = push_notifications_listed_disco_when_available, Config1) ->
    Config2 = ensure_pusher_module_and_save_old_mods(Config1),
    escalus:init_per_testcase(CaseName, Config2);
init_per_testcase(CaseName = push_notifications_not_listed_disco_when_not_available, Config) ->
    escalus:init_per_testcase(CaseName, Config);
init_per_testcase(CaseName, Config0) ->
    Config1 = escalus_fresh:create_users(Config0, [{bob, 1}, {alice, 1}, {kate, 1}]),
    Config = [{case_name, CaseName} | Config1],

    case ?config(pubsub_host, Config0) of
        virtual ->
            add_virtual_host_to_pusher(pubsub_jid(Config)),
            start_hook_listener();
        _ ->
            start_route_listener(CaseName)
    end,

    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName = push_notifications_listed_disco_when_available, Config) ->
    restore_modules(Config),
    escalus:end_per_testcase(CaseName, Config);
end_per_testcase(CaseName = push_notifications_not_listed_disco_when_not_available, Config) ->
    escalus:end_per_testcase(CaseName, Config);
end_per_testcase(CaseName, Config) ->
    rpc(ejabberd_router, unregister_route, [atom_to_binary(CaseName, utf8)]),
    escalus:end_per_testcase(CaseName, Config).

%% --------------------- Helpers ------------------------

add_virtual_host_to_pusher(VirtualHost) ->
    rpc(mod_event_pusher_push, add_virtual_pubsub_host, [<<"localhost">>, VirtualHost]).

ensure_pusher_module_and_save_old_mods(Config) ->
    PushOpts = [{backend, mongoose_helper:mnesia_or_rdbms_backend()}],
    Host = ct:get_config({hosts, mim, domain}),
    Config1 = dynamic_modules:save_modules(Host, Config),
    PusherMod = {mod_event_pusher, [{backends, [{push, PushOpts}]}]},
    dynamic_modules:ensure_modules(Host, [PusherMod]),
    [{push_opts, PushOpts} | Config1].

restore_modules(Config) ->
    Host = ct:get_config({hosts, mim, domain}),
    dynamic_modules:restore_modules(Host, Config).

%%--------------------------------------------------------------------
%% GROUP disco
%%--------------------------------------------------------------------

push_notifications_listed_disco_when_available(Config) ->
    escalus:story(
        Config, [{alice, 1}],
        fun(Alice) ->
            Server = escalus_client:server(Alice),
            escalus:send(Alice, escalus_stanza:disco_info(Server)),
            Stanza = escalus:wait_for_stanza(Alice),
            escalus:assert(is_iq_result, Stanza),
            escalus:assert(has_feature, [push_helper:ns_push()], Stanza),
            ok
        end).

push_notifications_not_listed_disco_when_not_available(Config) ->
    escalus:story(
        Config, [{alice, 1}],
        fun(Alice) ->
            Server = escalus_client:server(Alice),
            escalus:send(Alice, escalus_stanza:disco_info(Server)),
            Stanza = escalus:wait_for_stanza(Alice),
            escalus:assert(is_iq_result, Stanza),
            Pred = fun(Feature, Stanza0) -> not escalus_pred:has_feature(Feature, Stanza0) end,
            escalus:assert(Pred, [push_helper:ns_push()], Stanza),
            ok
        end).

%%--------------------------------------------------------------------
%% GROUP toggling
%%--------------------------------------------------------------------

enable_should_fail_with_missing_attributes(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            BobJID = escalus_utils:get_jid(Bob),

            escalus:send(Bob, escalus_stanza:iq(<<"set">>, [#xmlel{name = <<"enable">>}])),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),

            CorrectAttrs = [{<<"xmlns">>, <<"urn:xmpp:push:0">>},
                            {<<"jid">>, BobJID},
                            {<<"node">>, <<"NodeKey">>}],

            %% Sending only one attribute should fail
            lists:foreach(
                fun(Attr) ->
                    escalus:send(Bob, escalus_stanza:iq(<<"set">>,
                                                        [#xmlel{name = <<"enable">>,
                                                                attrs = [Attr]}])),
                    escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                                   escalus:wait_for_stanza(Bob))
                end, CorrectAttrs),

            %% Sending all but one attribute should fail
            lists:foreach(
                fun(Attr) ->
                    escalus:send(Bob, escalus_stanza:iq(<<"set">>,
                                                        [#xmlel{name = <<"enable">>,
                                                                attrs = CorrectAttrs -- [Attr]}])),
                    escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                                   escalus:wait_for_stanza(Bob))
                end, CorrectAttrs),

            ok
        end).

enable_should_fail_with_invalid_attributes(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            PubsubJID = pubsub_jid(Config),

            %% Empty JID
            escalus:send(Bob, enable_stanza(<<>>, <<"nodeId">>)),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),

            %% Empty node
            escalus:send(Bob, enable_stanza(PubsubJID, <<>>)),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),
            ok
        end).


enable_should_succeed_without_form(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            ok
        end).

enable_with_form_should_fail_with_incorrect_from(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>, [], <<"wrong">>)),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),
            ok
        end).

enable_should_accept_correct_from(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>, [])),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>, [
                {<<"secret1">>, <<"token1">>},
                {<<"secret2">>, <<"token2">>}
            ])),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            ok
        end).

disable_should_fail_with_missing_attributes(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            BobJID = escalus_utils:get_jid(Bob),

            escalus:send(Bob, escalus_stanza:iq(<<"set">>, [#xmlel{name = <<"disable">>}])),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),

            CorrectAttrs = [{<<"xmlns">>, <<"urn:xmpp:push:0">>}, {<<"jid">>, BobJID}],

            %% Sending only one attribute should fail
            lists:foreach(
                fun(Attr) ->
                    escalus:send(Bob, escalus_stanza:iq(<<"set">>,
                                                        [#xmlel{name = <<"disable">>,
                                                                attrs = [Attr]}])),
                    escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                                   escalus:wait_for_stanza(Bob))
                end, CorrectAttrs),
            ok
        end).

disable_should_fail_with_invalid_attributes(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            %% Empty JID
            escalus:send(Bob, disable_stanza(<<>>, <<"nodeId">>)),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),
            escalus:send(Bob, disable_stanza(<<>>)),
            escalus:assert(is_error, [<<"modify">>, <<"bad-request">>],
                           escalus:wait_for_stanza(Bob)),
            ok
        end).

disable_all(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, disable_stanza(PubsubJID)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            ok
        end).

disable_node(Config) ->
    escalus:story(
        Config, [{bob, 1}],
        fun(Bob) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, disable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            ok
        end).

%%--------------------------------------------------------------------
%% GROUP pm_msg_notifications
%%--------------------------------------------------------------------

pm_no_msg_notifications_if_not_enabled(Config) ->
    escalus:story(
        Config, [{bob, 1}, {alice, 1}],
        fun(Bob, Alice) ->
            become_unavailable(Bob),
            escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),

            ?assert(not truly(received_push(Config))),
            ok
        end).

pm_no_msg_notifications_if_user_online(Config) ->
    escalus:story(
        Config, [{bob, 1}, {alice, 1}],
        fun(Bob, Alice) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),

            ?assert(not truly(received_push(Config))),
            ok
        end).

pm_msg_notify_if_user_offline(Config) ->
    escalus:story(
        Config, [{bob, 1}, {alice, 1}],
        fun(Bob, Alice) ->
            PubsubJID = pubsub_jid(Config),

            AliceJID = bare_jid(Alice),
            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),
            become_unavailable(Bob),

            escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),

            #{ payload := Payload } = received_push(Config),
            ?assertMatch(<<"OH, HAI!">>, proplists:get_value(<<"last-message-body">>, Payload)),
            ?assertMatch(AliceJID,
                         proplists:get_value(<<"last-message-sender">>, Payload)),

            ok
        end).

pm_msg_notify_if_user_offline_with_publish_options(Config) ->
    escalus:story(
        Config, [{bob, 1}, {alice, 1}],
        fun(Bob, Alice) ->
            PubsubJID = pubsub_jid(Config),

            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>,
                                            [{<<"field1">>, <<"value1">>},
                                             {<<"field2">>, <<"value2">>}])),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),
            become_unavailable(Bob),

            escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),

            #{ publish_options := PublishOptions } = received_push(Config),

            ?assertMatch(<<"value1">>, proplists:get_value(<<"field1">>, PublishOptions)),
            ?assertMatch(<<"value2">>, proplists:get_value(<<"field2">>, PublishOptions)),
            ok
        end).

pm_msg_notify_stops_after_disabling(Config) ->
    escalus:story(
        Config, [{bob, 1}, {alice, 1}],
        fun(Bob, Alice) ->
            PubsubJID = pubsub_jid(Config),

            %% Enable
            escalus:send(Bob, enable_stanza(PubsubJID, <<"NodeId">>, [])),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),

            %% Disable
            escalus:send(Bob, disable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)),
            become_unavailable(Bob),

            escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),

            ?assert(not received_push(Config)),

            ok
        end).

%%--------------------------------------------------------------------
%% GROUP muclight_msg_notifications
%%--------------------------------------------------------------------

muclight_no_msg_notifications_if_not_enabled(Config) ->
    escalus:story(
        Config, [{alice, 1}, {bob, 1}, {kate, 1}],
        fun(Alice, Bob, Kate) ->
            Room = room_name(Config),
            create_room(Room, [bob, alice, kate], Config),
            become_unavailable(Alice),
            become_unavailable(Kate),

            Msg = <<"Heyah!">>,
            Stanza = escalus_stanza:groupchat_to(room_bin_jid(Room), Msg),

            escalus:send(Bob, Stanza),

            ?assert(not truly(received_push(Config))),

            ok
        end).

muclight_no_msg_notifications_if_user_online(Config) ->
    escalus:story(
        Config, [{alice, 1}, {bob, 1}, {kate, 1}],
        fun(Alice, Bob, Kate) ->
            Room = room_name(Config),
            PubsubJID = pubsub_jid(Config),

            create_room(Room, [bob, alice, kate], Config),
            escalus:send(Alice, enable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),
            become_unavailable(Kate),

            Msg = <<"Heyah!">>,
            Stanza = escalus_stanza:groupchat_to(room_bin_jid(Room), Msg),
            escalus:send(Bob, Stanza),

            ?assert(not truly(received_push(Config))),
            ok
        end).

muclight_msg_notify_if_user_offline(Config) ->
    escalus:story(
        Config, [{alice, 1}, {bob, 1}, {kate, 1}],
        fun(Alice, Bob, _Kate) ->
            PubsubJID = pubsub_jid(Config),
            Room = room_name(Config),
            BobJID = bare_jid(Bob),

            create_room(Room, [bob, alice, kate], Config),
            escalus:send(Alice, enable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),
            become_unavailable(Alice),

            Msg = <<"Heyah!">>,
            Stanza = escalus_stanza:groupchat_to(room_bin_jid(Room), Msg),
            escalus:send(Bob, Stanza),

            #{ payload := Payload } = received_push(Config),

            ?assertMatch(Msg, proplists:get_value(<<"last-message-body">>, Payload)),
            SenderId = <<(room_bin_jid(Room))/binary, "/" ,BobJID/binary>>,
            ?assertMatch(SenderId,
                         proplists:get_value(<<"last-message-sender">>, Payload)),
            ok
        end).

muclight_msg_notify_if_user_offline_with_publish_options(Config) ->
    escalus:story(
        Config, [{alice, 1}, {bob, 1}, {kate, 1}],
        fun(Alice, Bob, _Kate) ->
            PubsubJID = pubsub_jid(Config),
            Room = room_name(Config),

            create_room(Room, [bob, alice, kate], Config),
            escalus:send(Alice, enable_stanza(PubsubJID, <<"NodeId">>,
                                            [{<<"field1">>, <<"value1">>},
                                             {<<"field2">>, <<"value2">>}])),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),
            become_unavailable(Alice),

            Msg = <<"Heyah!">>,
            Stanza = escalus_stanza:groupchat_to(room_bin_jid(Room), Msg),
            escalus:send(Bob, Stanza),

            #{ publish_options := PublishOptions } = received_push(Config),

            ?assertMatch(<<"value1">>, proplists:get_value(<<"field1">>, PublishOptions)),
            ?assertMatch(<<"value2">>, proplists:get_value(<<"field2">>, PublishOptions)),
            ok
        end).

muclight_msg_notify_stops_after_disabling(Config) ->
    escalus:story(
        Config, [{alice, 1}, {bob, 1}, {kate, 1}],
        fun(Alice, Bob, _Kate) ->
            Room = room_name(Config),
            PubsubJID = pubsub_jid(Config),
            create_room(Room, [bob, alice, kate], Config),

            %% Enable
            escalus:send(Alice, enable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),

            %% Disable
            escalus:send(Alice, disable_stanza(PubsubJID, <<"NodeId">>)),
            escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),
            become_unavailable(Alice),

            Msg = <<"Heyah!">>,
            Stanza = escalus_stanza:groupchat_to(room_bin_jid(Room), Msg),
            escalus:send(Bob, Stanza),

            ?assert(not truly(received_push(Config))),
            ok
        end).

%%--------------------------------------------------------------------
%% Remote code
%% Functions that will be executed in MongooseIM context + helpers that set them up
%%--------------------------------------------------------------------

start_route_listener(CaseName) ->
    %% We put namespaces in the state to avoid injecting push_helper module to MIM as well
    State = #{ pid => self(),
               pub_options_ns => push_helper:ns_pubsub_pub_options(),
               push_form_ns => push_helper:push_form_type() },
    Handler = rpc(mongoose_packet_handler, new, [?MODULE, State]),
    rpc(ejabberd_router, register_route, [atom_to_binary(CaseName, utf8), Handler]).

process_packet(_Acc, _From, To, El, State) ->
    #{ pid := TestCasePid, pub_options_ns := PubOptionsNS, push_form_ns := PushFormNS } = State,
    PublishXML = exml_query:path(El, [{element, <<"pubsub">>},
                                      {element, <<"publish-options">>},
                                      {element, <<"x">>}]),
    PublishOptions = parse_form(PublishXML),

    PayloadXML = exml_query:path(El, [{element, <<"pubsub">>},
                                      {element, <<"publish">>},
                                      {element, <<"item">>},
                                      {element, <<"notification">>},
                                      {element, <<"x">>}]),
    Payload = parse_form(PayloadXML),
    
    case valid_ns_if_defined(PubOptionsNS, PublishOptions) andalso
         valid_ns_if_defined(PushFormNS, Payload) of
        true ->
            TestCasePid ! #{ publish_options => PublishOptions,
                             payload => Payload,
                             pubsub_jid_bin => jid:to_binary(To) };
        false ->
            %% We use publish_options0 and payload0 to avoid accidental match in received_push
            %% even after some tests updates and refactors
            TestCasePid ! #{ error => invalid_namespace,
                             publish_options0 => PublishOptions,
                             payload0 => Payload }
    end.

parse_form(undefined) ->
    undefined;
parse_form(#xmlel{name = <<"x">>} = Form) ->
    parse_form(exml_query:subelements(Form, <<"field">>));
parse_form(Fields) when is_list(Fields) ->
    lists:map(
        fun(Field) ->
            {exml_query:attr(Field, <<"var">>),
             exml_query:path(Field, [{element, <<"value">>}, cdata])}
        end, Fields).

valid_ns_if_defined(_, undefined) ->
    true;
valid_ns_if_defined(NS, FormProplist) ->
    NS =:= proplists:get_value(<<"FORM_TYPE">>, FormProplist).

start_hook_listener() ->
    TestCasePid = self(),
    rpc(?MODULE, rpc_start_hook_handler, [TestCasePid]).

rpc_start_hook_handler(TestCasePid) ->
    Handler = fun(Acc, _Host, [PayloadMap], OptionMap) ->
                      try jid:to_binary(mongoose_acc:get(push_notifications, pubsub_jid, Acc)) of
                          PubsubJIDBin ->
                              TestCasePid ! #{ publish_options => maps:to_list(OptionMap),
                                               payload => maps:to_list(PayloadMap),
                                               pubsub_jid_bin => PubsubJIDBin },
                              Acc
                      catch
                          C:R:S ->
                              TestCasePid ! #{ event => handler_error,
                                               class => C,
                                               reason => R,
                                               stacktrace => S },
                              Acc
                      end
              end,
    ejabberd_hooks:add(push_notifications, <<"localhost">>, Handler, 50).

%%--------------------------------------------------------------------
%% Test helpers
%%--------------------------------------------------------------------

create_room(Room, [Owner | Members], Config) ->
    Domain = ct:get_config({hosts, mim, domain}),
    create_room(Room, <<"muclight.", Domain/binary>>, Owner, Members,
                                Config, <<"v1">>).

received_push(Config) ->
    ExpectedPubsubJIDBin = pubsub_jid(Config),
    %% With parallel test cases execution we might receive notifications from other cases
    %% so it's essential to filter by our pubsub JID
    receive
        #{ pubsub_jid_bin := PubsubJIDBin } = Push when PubsubJIDBin =:= ExpectedPubsubJIDBin ->
            Push
    after
        timer:seconds(5) ->
            ct:pal("~p", [#{ result => nomatch, msg_inbox => process_info(self(), messages) }]),
            false
    end.

truly(false) ->
    false;
truly(undefined) ->
    false;
truly(_) ->
    true.

bare_jid(JIDOrClient) ->
    ShortJID = escalus_client:short_jid(JIDOrClient),
    list_to_binary(string:to_lower(binary_to_list(ShortJID))).

pubsub_jid(Config) ->
    CaseName = proplists:get_value(case_name, Config),
    CaseNameBin = atom_to_binary(CaseName, utf8),
    case ?config(pubsub_host, Config) of
        virtual -> <<CaseNameBin/binary, ".hyperion">>;
        _ -> <<"pubsub@", CaseNameBin/binary>>
    end.

room_name(Config) ->
    CaseName = proplists:get_value(case_name, Config),
    <<"room_", (atom_to_binary(CaseName, utf8))/binary>>.

is_offline(LUser, LServer) ->
    case catch lists:max(rpc(ejabberd_sm, get_user_present_pids, [LUser, LServer])) of
        {Priority, _} when is_integer(Priority), Priority >= 0 ->
            false;
        _ ->
            true
    end.

