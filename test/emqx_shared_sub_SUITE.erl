
%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_shared_sub_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([t_random_basic/1,
         t_random/1,
         t_round_robin/1,
         t_sticky/1,
         t_hash/1,
         t_not_so_sticky/1,
         t_no_connection_nack/1
        ]).

-include("emqx.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(wait(For, Timeout), wait_for(?FUNCTION_NAME, ?LINE, fun() -> For end, Timeout)).

all() -> [t_random_basic,
          t_random,
          t_round_robin,
          t_sticky,
          t_hash,
          t_not_so_sticky,
          t_no_connection_nack
         ].

init_per_suite(Config) ->
    emqx_ct_broker_helpers:run_setup_steps(),
    Config.

end_per_suite(_Config) ->
    emqx_ct_broker_helpers:run_teardown_steps().

t_random_basic(_) ->
    application:set_env(?APPLICATION, shared_subscription_strategy, random),
    ClientId = <<"ClientId">>,
    {ok, ConnPid} = emqx_mock_client:start_link(ClientId),
    {ok, SPid} = emqx_mock_client:open_session(ConnPid, ClientId, internal),
    Message1 = emqx_message:make(<<"ClientId">>, 2, <<"foo">>, <<"hello">>),
    emqx_session:subscribe(SPid, [{<<"foo">>, #{qos => 2, share => <<"group1">>}}]),
    %% wait for the subscription to show up
    ?wait(subscribed(<<"group1">>, <<"foo">>, SPid), 1000),
    emqx_session:publish(SPid, 1, Message1),
    ?wait(case emqx_mock_client:get_last_message(ConnPid) of
              {publish, 1, _} -> true;
              Other -> Other
          end, 1000),
    emqx_session:puback(SPid, 2),
    emqx_session:puback(SPid, 3, reasoncode),
    emqx_session:pubrec(SPid, 4),
    emqx_session:pubrec(SPid, 5, reasoncode),
    emqx_session:pubrel(SPid, 6, reasoncode),
    emqx_session:pubcomp(SPid, 7, reasoncode),
    emqx_mock_client:close_session(ConnPid),
    ok.

%% Start two subscribers share subscribe to "$share/g1/foo/bar"
%% Set 'sticky' dispatch strategy, send 1st message to find
%% out which member it picked, then close its connection
%% send the second message, the message should be 'nack'ed
%% by the sticky session and delivered to the 2nd session.
t_no_connection_nack(_) ->
    application:set_env(?APPLICATION, shared_subscription_strategy, sticky),
    Publisher = <<"publisher">>,
    Subscriber1 = <<"Subscriber1">>,
    Subscriber2 = <<"Subscriber2">>,
    QoS = 1,
    Group = <<"g1">>,
    Topic = <<"foo/bar">>,
    {ok, PubConnPid} = emqx_mock_client:start_link(Publisher),
    {ok, SubConnPid1} = emqx_mock_client:start_link(Subscriber1),
    {ok, SubConnPid2} = emqx_mock_client:start_link(Subscriber2),
    %% allow session to persist after connection shutdown
    Attrs = #{expiry_interval => timer:seconds(30)},
    {ok, P_Pid} = emqx_mock_client:open_session(PubConnPid, Publisher, internal, Attrs),
    {ok, SPid1} = emqx_mock_client:open_session(SubConnPid1, Subscriber1, internal, Attrs),
    {ok, SPid2} = emqx_mock_client:open_session(SubConnPid2, Subscriber2, internal, Attrs),
    emqx_session:subscribe(SPid1, [{Topic, #{qos => QoS, share => Group}}]),
    emqx_session:subscribe(SPid2, [{Topic, #{qos => QoS, share => Group}}]),
    %% wait for the subscriptions to show up
    ?wait(subscribed(Group, Topic, SPid1), 1000),
    ?wait(subscribed(Group, Topic, SPid2), 1000),
    MkPayload = fun(PacketId) -> iolist_to_binary(["hello-", integer_to_list(PacketId)]) end,
    SendF = fun(PacketId) -> emqx_session:publish(P_Pid, PacketId, emqx_message:make(Publisher, QoS, Topic, MkPayload(PacketId))) end,
    SendF(1),
    Ref = make_ref(),
    CasePid = self(),
    Received =
        fun(PacketId, ConnPid) ->
                Payload = MkPayload(PacketId),
                case emqx_mock_client:get_last_message(ConnPid) of
                    {publish, _, #message{payload = Payload}} ->
                        CasePid ! {Ref, PacketId, ConnPid},
                        true;
                    _Other ->
                        false
                end
        end,
    ?wait(Received(1, SubConnPid1) orelse Received(1, SubConnPid2), 1000),
    %% This is the connection which was picked by broker to dispatch (sticky) for 1st message
    ConnPid = receive {Ref, 1, Pid} -> Pid after 1000 -> error(timeout) end,
    %% Now kill the connection, expect all following messages to be delivered to the other subscriber.
    emqx_mock_client:stop(ConnPid),
    %% sleep then make synced calls to session processes to ensure that
    %% the connection pid's 'EXIT' message is propagated to the session process
    %% also to be sure sessions are still alive
    timer:sleep(5),
    _ = emqx_session:info(SPid1),
    _ = emqx_session:info(SPid2),
    %% Now we know what is the other still alive connection
    [TheOtherConnPid] = [SubConnPid1, SubConnPid2] -- [ConnPid],
    %% Send some more messages
    PacketIdList = lists:seq(2, 10),
    lists:foreach(fun(Id) ->
                          SendF(Id),
                          ?wait(Received(Id, TheOtherConnPid), 1000)
                  end, PacketIdList),
    %% clean up
    emqx_mock_client:close_session(PubConnPid),
    emqx_sm:close_session(SPid1),
    emqx_sm:close_session(SPid2),
    emqx_mock_client:close_session(TheOtherConnPid),
    ok.

t_random(_) ->
    test_two_messages(random).

t_round_robin(_) ->
    test_two_messages(round_robin).

t_sticky(_) ->
    test_two_messages(sticky).

t_hash(_) ->
    test_two_messages(hash).

%% if the original subscriber dies, change to another one alive
t_not_so_sticky(_) ->
    application:set_env(?APPLICATION, shared_subscription_strategy, sticky),
    ClientId1 = <<"ClientId1">>,
    ClientId2 = <<"ClientId2">>,
    {ok, ConnPid1} = emqx_mock_client:start_link(ClientId1),
    {ok, ConnPid2} = emqx_mock_client:start_link(ClientId2),
    {ok, SPid1} = emqx_mock_client:open_session(ConnPid1, ClientId1, internal),
    {ok, SPid2} = emqx_mock_client:open_session(ConnPid2, ClientId2, internal),
    Message1 = emqx_message:make(ClientId1, 0, <<"foo/bar">>, <<"hello1">>),
    Message2 = emqx_message:make(ClientId1, 0, <<"foo/bar">>, <<"hello2">>),
    emqx_session:subscribe(SPid1, [{<<"foo/bar">>, #{qos => 0, share => <<"group1">>}}]),
    %% wait for the subscription to show up
    ?wait(subscribed(<<"group1">>, <<"foo/bar">>, SPid1), 1000),
    emqx_session:publish(SPid1, 1, Message1),
    ?wait(case emqx_mock_client:get_last_message(ConnPid1) of
              {publish, _, #message{payload = <<"hello1">>}} -> true;
              Other -> Other
          end, 1000),
    emqx_mock_client:close_session(ConnPid1),
    ?wait(not subscribed(<<"group1">>, <<"foo/bar">>, SPid1), 1000),
    emqx_session:subscribe(SPid2, [{<<"foo/#">>, #{qos => 0, share => <<"group1">>}}]),
    ?wait(subscribed(<<"group1">>, <<"foo/#">>, SPid2), 1000),
    emqx_session:publish(SPid2, 2, Message2),
    ?wait(case emqx_mock_client:get_last_message(ConnPid2) of
              {publish, _, #message{payload = <<"hello2">>}} -> true;
              Other -> Other
          end, 1000),
    emqx_mock_client:close_session(ConnPid2),
    ?wait(not subscribed(<<"group1">>, <<"foo/#">>, SPid2), 1000),
    ok.

test_two_messages(Strategy) ->
    Topic = <<"foo/bar">>,
    application:set_env(?APPLICATION, shared_subscription_strategy, Strategy),
    ClientId1 = <<"ClientId1">>,
    ClientId2 = <<"ClientId2">>,
    {ok, ConnPid1} = emqx_mock_client:start_link(ClientId1),
    {ok, ConnPid2} = emqx_mock_client:start_link(ClientId2),
    {ok, SPid1} = emqx_mock_client:open_session(ConnPid1, ClientId1, internal),
    {ok, SPid2} = emqx_mock_client:open_session(ConnPid2, ClientId2, internal),
    Message1 = emqx_message:make(ClientId1, 0, Topic, <<"hello1">>),
    Message2 = emqx_message:make(ClientId1, 0, Topic, <<"hello2">>),
    emqx_session:subscribe(SPid1, [{Topic, #{qos => 0, share => <<"group1">>}}]),
    emqx_session:subscribe(SPid2, [{Topic, #{qos => 0, share => <<"group1">>}}]),
    %% wait for the subscription to show up
    ?wait(subscribed(<<"group1">>, Topic, SPid1) andalso
          subscribed(<<"group1">>, Topic, SPid2), 1000),
    emqx_broker:publish(Message1),
    Me = self(),
    WaitF = fun(ExpectedPayload) ->
                    case last_message(ExpectedPayload, [ConnPid1, ConnPid2]) of
                        {true, Pid} ->
                            Me ! {subscriber, Pid},
                            true;
                        Other ->
                            Other
                    end
            end,
    ?wait(WaitF(<<"hello1">>), 2000),
    UsedSubPid1 = receive {subscriber, P1} -> P1 end,
    emqx_broker:publish(Message2),
    ?wait(WaitF(<<"hello2">>), 2000),
    UsedSubPid2 = receive {subscriber, P2} -> P2 end,
    case Strategy of
        sticky -> ?assert(UsedSubPid1 =:= UsedSubPid2);
        round_robin -> ?assert(UsedSubPid1 =/= UsedSubPid2);
        hash -> ?assert(UsedSubPid1 =:= UsedSubPid2);
        _ -> ok
    end,
    emqx_mock_client:close_session(ConnPid1),
    emqx_mock_client:close_session(ConnPid2),
    ok.

last_message(_ExpectedPayload, []) -> <<"not yet?">>;
last_message(ExpectedPayload, [Pid | Pids]) ->
    case emqx_mock_client:get_last_message(Pid) of
        {publish, _, #message{payload = ExpectedPayload}} -> {true, Pid};
        _Other -> last_message(ExpectedPayload, Pids)
    end.

%%------------------------------------------------------------------------------
%% help functions
%%------------------------------------------------------------------------------

subscribed(Group, Topic, Pid) ->
    lists:member(Pid, emqx_shared_sub:subscribers(Group, Topic)).

wait_for(Fn, Ln, F, Timeout) ->
    {Pid, Mref} = erlang:spawn_monitor(fun() -> wait_loop(F, catch_call(F)) end),
    wait_for_down(Fn, Ln, Timeout, Pid, Mref, false).

wait_for_down(Fn, Ln, Timeout, Pid, Mref, Kill) ->
    receive
        {'DOWN', Mref, process, Pid, normal} ->
            ok;
        {'DOWN', Mref, process, Pid, {unexpected, Result}} ->
            erlang:error({unexpected, Fn, Ln, Result});
        {'DOWN', Mref, process, Pid, {crashed, {C, E, S}}} ->
            erlang:raise(C, {Fn, Ln, E}, S)
    after
        Timeout ->
            case Kill of
                true ->
                    erlang:demonitor(Mref, [flush]),
                    erlang:exit(Pid, kill),
                    erlang:error({Fn, Ln, timeout});
                false ->
                    Pid ! stop,
                    wait_for_down(Fn, Ln, Timeout, Pid, Mref, true)
            end
    end.

wait_loop(F, ok) -> exit(normal);
wait_loop(F, LastRes) ->
    receive
        stop -> erlang:exit(LastRes)
    after
        100 ->
            Res = catch_call(F),
            wait_loop(F, Res)
    end.

catch_call(F) ->
    try
        case F() of
            true -> ok;
            Other -> {unexpected, Other}
        end
    catch
        C : E : S ->
            {crashed, {C, E, S}}
    end.

