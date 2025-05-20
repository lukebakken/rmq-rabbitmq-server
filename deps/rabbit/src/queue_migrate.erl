-module(queue_migrate).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit/include/amqqueue.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([go/0]).

%% Notes:
%% https://www.rabbitmq.com/docs/3.13/vhosts#migration-to-quorum-queues-a-way-to-relax-queue-property-equivalence-checks
%% quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true

%% This all assumes there are no connections/channels,
%% and thus no producers or consumers.

go() ->
    AllClassicQueues = [Q || Q <- rabbit_db_queue:get_all_by_type(rabbit_classic_queue), is_queue_to_migrate(Q)],
    ok = migrate_to_qq(AllClassicQueues, fun(Name) ->
                                                 ?LOG_INFO("migrating queue ~tp",[Name]),
                                                 <<"tmp_", Name/binary>>
                                         end),
    AllTmpQQueues = [Q || Q <- rabbit_db_queue:get_all_by_type(rabbit_quorum_queue), is_tmp_queue(Q)],
    ok = migrate_to_qq(AllTmpQQueues,
                       fun(Name) ->
                               <<"tmp_", CleanName/binary>> = Name,
                               CleanName
                       end),
    ok.

migrate_to_qq([], _) ->
    ?LOG_INFO("migration complete"),
    ok;
migrate_to_qq([Q|T], NameFun) ->
    Resource = amqqueue:get_name(Q),

    QName = Resource#resource.name,
    NewQName = NameFun(QName),
    ?LOG_INFO("migrating ~tp to ~tp", [QName, NewQName]),

    NewResource = Resource#resource{name = NewQName},
    %% TODO: Figure out feature compat and migration path
    NewArgs = convert_args(amqqueue:get_arguments(Q)),
    {new, NewQ} = rabbit_amqqueue:declare(NewResource, true, false, NewArgs, none, <<"internal_user">>),
    Bindings = rabbit_binding:list_for_destination(Resource),
    %% TODO check binding result
    [rabbit_binding:add(B#binding{destination = NewResource}, <<"internaluser">>) || B <- Bindings],
    migrate(Q, NewQ),
    migrate_to_qq(T, NameFun).

migrate(OldQ, NewQ) ->
    OldQState = rabbit_queue_type:init(),
    NewQState = rabbit_queue_type:init(),
    ok = dequeue_and_deliver(OldQ, NewQ, OldQState, NewQState).

dequeue_and_deliver(OldQ, NewQueue, OldQState, NewQueueState) ->
    %% Dequeue single active consumer not allowed on QQs, use consume instead?
    case rabbit_queue_type:dequeue(OldQ, false, self(), 0, OldQState) of
        {empty, DelState} ->
            ok = delete(OldQ, DelState);
        {ok, _Count, {Name, _, MsgId, _, Msg}, QueueState} ->
            DeliverState = deliver(NewQueue, Msg, NewQueueState),
            settle(OldQ, Name, MsgId, QueueState),
            dequeue_and_deliver(OldQ, NewQueue, QueueState, DeliverState);
        Unexpected ->
            ?LOG_ERROR("unexpected dequeue result: ~tp", [Unexpected])
    end.

convert_args(Args) ->
    QQType = {<<"x-queue-type">>, longstr, <<"quorum">>},
    NewArgs =
        lists:filtermap(
          fun({<<"x-overflow">>,longstr,<<"reject-publish-dlx">>}) ->
                  {true, {<<"x-overflow">>,longstr,<<"reject-publish">>}};
             ({<<"x-max-priority">>, _, _}) ->
                  false;
             ({<<"x-queue-mode">>, _, _}) ->
                  false;
             ({<<"x-queue-type">>, _, _}) ->
                  false;
             (Arg) ->
                  {true, Arg}
          end,
          Args),
    [QQType|NewArgs].

delete(Q, State) ->
    case rabbit_queue_type:delete(Q, false, false, <<"internal_user">>) of
        {ok, _} ->
            QRef = amqqueue:get_name(Q),
            case is_tmp_queue(Q) of
                false ->
                    receive
                        %% rabbit_fifo_client:handle_ra_event
                        %% Do we really care, other than making sure we get the expected msgs?
                        {'$gen_cast',{queue_event, QRef, {_, {machine, eol}} = Evt}} ->
                            %% Not sure if we fully care here, no channel etc to cleanup.
                            _ = rabbit_queue_type:handle_event(QRef, Evt, State),
                            ok;
                        {{'DOWN', QRef}, _, process, _Pid, normal} ->
                            ok
                            %% TODO log other messages
                    end;
                true ->
                    ok
            end;
        Error ->
            ?LOG_ERROR("error when deleting queue ~tp, error: ~tp", [qstr(Q), Error])
    end.

settle(OldQ, Name, MsgId, QueueState) ->
    {ok, NewState, _} = rabbit_queue_type:settle(Name, complete, 0, [MsgId], QueueState),
    case amqqueue:get_type(OldQ) of
        rabbit_quorum_queue ->
            QRef = amqqueue:get_name(OldQ),
            receive
                %% Get this event after settle on QQ
                {'$gen_cast',{queue_event, QRef, {_, {applied, [{0, ok}]}} = Evt}} ->
                    {ok, _LState, _} =
                        %% Since no channels etc, I assume we can just ignore event response?
                        rabbit_queue_type:handle_event(QRef, Evt, NewState),
                    ok
                %% TODO log other messages
            end;
        _ ->
            ok
    end.

deliver(Q, Msg, State) ->
    QRef = amqqueue:get_name(Q),
    {ok, NewState, _} = rabbit_queue_type:deliver([Q], Msg,
                                                  #{correlation=>1}, State),
    receive
        %% Make sure the msg was applied, before we allow further action
        %% (i.e a call to ack/settle we got the msg)
        {'$gen_cast',{queue_event, QRef,
                      {_, {applied,[{_,ok}]}} = Evt}} ->
            {ok, LState, _} =
                rabbit_queue_type:handle_event(QRef, Evt, NewState),
            LState
    end.

is_tmp_queue(Q) ->
    Resource = amqqueue:get_name(Q),
    Name = Resource#resource.name,
    case binary:match(Name, <<"tmp_">>) of
        {0,4} ->
            true;
        _ ->
            false
    end.

is_queue_to_migrate(Q) when ?amqqueue_is_classic(Q) andalso ?amqqueue_exclusive_owner_is(Q, none) ->
    case has_ha_policy(Q) of
        true ->
            true;
        _ ->
            ?LOG_WARNING("skipping migration of ~tp", [qstr(Q)])
    end;
is_queue_to_migrate(Q) ->
    ?LOG_WARNING("skipping migration of queue ~tp", [qstr(Q)]).

has_ha_policy(Q) ->
    case rabbit_policy:effective_definition(Q) of
        EffectivePolicies when is_list(EffectivePolicies) ->
            proplists:lookup(<<"ha-mode">>, EffectivePolicies) =/= none;
        _  ->
            false
    end.

qstr(Q) when ?is_amqqueue(Q) ->
    Res = amqqueue:get_name(Q),
    rabbit_misc:rs(Res).
