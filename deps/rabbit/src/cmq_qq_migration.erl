-module(cmq_qq_migration).

-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit/include/amqqueue.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([start_link/0,
         start/0,
         start_async/0,
         start_migration/1]).

-define(QUEUE_MIGRATION_TIMEOUT_MS, 60000).

%% Notes:
%% https://www.rabbitmq.com/docs/3.13/vhosts#migration-to-quorum-queues-a-way-to-relax-queue-property-equivalence-checks
%% quorum_queue.property_equivalence.relaxed_checks_on_redeclaration = true

%% This all assumes there are no connections/channels,
%% and thus no producers or consumers.

start_link() ->
    PoolSize = erlang:system_info(schedulers) div 2,
    worker_pool_sup:start_link(PoolSize, ?MODULE).

%% Public API
start() ->
    try
        maybe_start_with_running_cluster(ensure_cluster_running())
    catch
        Class:Ex:Stack ->
            ?LOG_ERROR("exception in ~tp", [?MODULE]),
            ?LOG_ERROR(" - class ~tp", [Class]),
            ?LOG_ERROR(" - ex ~tp", [Ex]),
            ?LOG_ERROR(" - stack ~tp", [Stack])
    end.

start_async() ->
    spawn(fun start/0).

%% Private

maybe_start_with_running_cluster({true, Nodes}) ->
    maybe_start_with_no_connections(ensure_no_connections(Nodes));
maybe_start_with_running_cluster({false, _}) ->
    ?LOG_ERROR("cmq to qq migration requires all cluster member nodes to be running."),
    {error, cmq_qq_migration_requires_running_cluster}.

maybe_start_with_no_connections({true, Nodes}) ->
    ok = start_worker_pools(Nodes),
    maybe_start_with_lock(get_queue_migrate_lock(), Nodes);
maybe_start_with_no_connections({false, _}) ->
    ?LOG_ERROR("cmq to qq migration requires that no connections are active."),
    {error, cmq_qq_migration_requires_no_connections}.

maybe_start_with_lock({true, GlobalLockId}, Nodes) ->
    ok = start_with_lock(GlobalLockId, Nodes);
maybe_start_with_lock(false, _Nodes) ->
    ?LOG_WARNING("cmq to qq migration is already in progress, please wait."),
    {error, cmq_qq_migration_in_progress}.

start_with_lock(GlobalLockId, Nodes) ->
    try 
        Start = erlang:monotonic_time(second),
        {ok, Gatherer} = gatherer:start_link(),
        ok = start_migration_on_each_node(Nodes, Gatherer),
        empty = gatherer:out(Gatherer),
        ok = gatherer:stop(Gatherer),
        End = erlang:monotonic_time(second),
        Duration = End - Start,
        ?LOG_INFO("queue migration took ~B seconds", [Duration])
    after
        global:del_lock(GlobalLockId)
    end,
    ok.

start_migration_on_each_node([], _Gatherer) ->
    ok;
start_migration_on_each_node([Node | Rest], Gatherer) ->
    ok = erpc:call(Node, ?MODULE, start_migration, [Gatherer]),
    start_migration_on_each_node(Rest, Gatherer).

start_migration(Gatherer) ->
    Qs = [Q || Q <- rabbit_db_queue:get_all_by_type(rabbit_classic_queue), is_queue_to_migrate(Q)],
    start_migration(Qs, Gatherer).

start_migration([], _Gatherer) ->
    ok;
start_migration([ClassicQ | Rest], Gatherer) ->
    ok = gatherer:fork(Gatherer),
    MigrationFun = fun() ->
                        do_migration(ClassicQ, Gatherer)
                   end,
    ok = worker_pool:submit_async(?MODULE, MigrationFun),
    start_migration(Rest, Gatherer).

do_migration(ClassicQ, Gatherer) ->
    Ref = make_ref(),
    PPid = self(),
    Fun = fun() ->
                  try
                      {ok, QuorumQ0} = migrate_to_tmp_qq(ClassicQ),
                      {ok, QuorumQ1} = tmp_qq_to_qq(QuorumQ0),
                      PPid ! {self(), Ref, {ok, qstr(QuorumQ1)}}
                  catch C:R:S ->
                      PPid ! {self(), Ref, {error, {C, R, S}}}
                  after
                      unlink(PPid)
                  end
          end,
    % Note: must be in its own process to handle ra event messages
    CPid = spawn_link(Fun),
    Result = wait_child(CPid, Ref),
    ok = gatherer:finish(Gatherer),
    Result.

wait_child(CPid, Ref) ->
    receive
        {CPid, Ref, {ok, QName}} ->
            ?LOG_INFO("done migrating queue ~tp",[QName]),
            ok;
        {CPid, Ref, Error} ->
            ?LOG_ERROR("do_migration error: ~tp", [Error]),
            {error, Error};
        Other ->
            ?LOG_DEBUG("do_migration handled other message: ~tp", [Other]),
            wait_child(CPid, Ref)
    after
        ?QUEUE_MIGRATION_TIMEOUT_MS ->
            ?LOG_ERROR("do_migration timeout!"),
            {error, timeout}
    end.

migrate_to_tmp_qq(Q) ->
    AddTmpPrefixFun = fun(Name) ->
                              <<"tmp_", Name/binary>>
                      end,
    migrate(Q, AddTmpPrefixFun).

tmp_qq_to_qq(Q) ->
    RemoveTmpPrefixFun = fun(Name) ->
                                 <<"tmp_", CleanName/binary>> = Name,
                                 CleanName
                         end,
    migrate(Q, RemoveTmpPrefixFun).

migrate(Q, NameFun) ->
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
    ok = migrate_queue_messages(Q, NewQ),
    {ok, NewQ}.

migrate_queue_messages(OldQ, NewQ) ->
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
                        {'$gen_cast', {queue_event, QRef, {_, {machine, eol}} = Evt}} ->
                            %% Not sure if we fully care here, no channel etc to cleanup.
                            _ = rabbit_queue_type:handle_event(QRef, Evt, State),
                            ok;
                        {{'DOWN', QRef}, _, process, _Pid, normal} ->
                            ok
                        %% TODO log other messages
                    after 10000 ->
                        ?LOG_WARNING("queue deletion timeout for ~tp", [qstr(Q)])
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
            after 10000 ->
                ?LOG_WARNING("queue settle timeout for ~tp", [qstr(OldQ)])
            end;
        _ ->
            ok
    end.

deliver(Q, Msg, State) ->
    QRef = amqqueue:get_name(Q),
    {ok, NewState, _} = rabbit_queue_type:deliver([Q], Msg, #{correlation=>1}, State),
    receive
        %% Make sure the msg was applied, before we allow further action
        %% (i.e a call to ack/settle we got the msg)
        {'$gen_cast', {queue_event, QRef, {_, {applied, [{_, ok}]}} = Evt}} ->
            {ok, LState, _} = rabbit_queue_type:handle_event(QRef, Evt, NewState),
            LState
    after 1000 ->
        ?LOG_WARNING("queue deliver timeout for ~tp", [qstr(Q)])
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

is_queue_to_migrate(Q) when 
        ?amqqueue_pid_runs_on_local_node(Q) andalso
        ?amqqueue_is_classic(Q) andalso
        ?amqqueue_exclusive_owner_is(Q, none) ->
    case has_ha_policy(Q) of
        true ->
            true;
        _ ->
            ?LOG_WARNING("skipping migration of ~tp", [qstr(Q)]),
            false
    end;
is_queue_to_migrate(Q) ->
    ?LOG_WARNING("skipping migration of queue ~tp", [qstr(Q)]),
    false.

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

-spec get_queue_migrate_lock() ->
    {true, {?MODULE, pid()}} | false.
get_queue_migrate_lock() ->
    Id = {?MODULE, self()},
    Nodes = [node()|nodes()],
    %% Note that we're not re-trying. We want to immediately know
    %% if a queue migration is taking place and stop accordingly.
    case global:set_lock(Id, Nodes, 0) of
        true ->
            {true, Id};
        false ->
            false
    end.

-spec ensure_cluster_running() -> {boolean(), list(node())}.
ensure_cluster_running() ->
    M = sets:from_list(rabbit_nodes:list_members()),
    R = sets:from_list(rabbit_nodes:list_running()),
    Result = sets:is_subset(M, R) andalso sets:is_subset(R, M),
    {Result, sets:to_list(M)}.

-spec ensure_no_connections(list(node())) -> {boolean(), list(node())}.
ensure_no_connections(Nodes) ->
    ensure_no_connections(Nodes, Nodes).

ensure_no_connections([], Nodes) ->
    {true, Nodes};
ensure_no_connections([Node | Rest], Nodes) ->
    case erpc:call(Node, rabbit_networking, local_connections, []) of
      Conns when is_list(Conns) andalso length(Conns) > 0 ->
            {false, Nodes};
      Conns when is_list(Conns) andalso length(Conns) =:= 0 ->
            ensure_no_connections(Rest, Nodes);
      Unexpected ->
            {false, Unexpected}
    end.

-spec start_worker_pools(list(node())) -> ok.
start_worker_pools([]) ->
    ok;
start_worker_pools([Node | Rest]) ->
    case erpc:call(Node, rabbit_sup, start_child, [?MODULE]) of
        ok ->
            ?LOG_INFO("queue migration worker pool started on node ~tp", [Node]),
            ok;
        {error, {already_started, _}} ->
            ?LOG_DEBUG("queue migration worker pool already started on node ~tp", [Node]),
            ok
    end,
    start_worker_pools(Rest).
