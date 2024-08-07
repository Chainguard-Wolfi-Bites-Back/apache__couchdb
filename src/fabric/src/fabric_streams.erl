% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(fabric_streams).

-export([
    start/2,
    start/3,
    start/4,
    start/5,
    cleanup/1,
    spawn_worker_cleaner/3,
    add_worker_to_cleaner/2
]).

-include_lib("fabric/include/fabric.hrl").
-include_lib("mem3/include/mem3.hrl").

-define(WORKER_CLEANER, fabric_worker_cleaner).

start(Workers, Keypos) ->
    start(Workers, Keypos, undefined, undefined).

start(Workers, Keypos, RingOpts) ->
    start(Workers, Keypos, undefined, undefined, RingOpts).

start(Workers, Keypos, StartFun, Replacements) ->
    start(Workers, Keypos, StartFun, Replacements, []).

start(Workers0, Keypos, StartFun, Replacements, RingOpts) ->
    Fun = fun handle_stream_start/3,
    Acc = #stream_acc{
        workers = fabric_dict:init(Workers0, waiting),
        ready = [],
        start_fun = StartFun,
        replacements = Replacements,
        ring_opts = RingOpts
    },
    ClientReq = chttpd_util:mochiweb_client_req_get(),
    spawn_worker_cleaner(self(), Workers0, ClientReq),
    Timeout = fabric_util:request_timeout(),
    case rexi_utils:recv(Workers0, Keypos, Fun, Acc, Timeout, infinity) of
        {ok, #stream_acc{ready = Workers}} ->
            AckedWorkers = fabric_dict:fold(
                fun(Worker, From, WorkerAcc) ->
                    rexi:stream_start(From),
                    [Worker | WorkerAcc]
                end,
                [],
                Workers
            ),
            {ok, AckedWorkers};
        Else ->
            Else
    end.

cleanup(Workers) ->
    % Stop the auxiliary cleaner process as we got to the point where cleanup
    % happesn in the regular fashion so we don't want to send 2x the number kill
    % messages
    case get(?WORKER_CLEANER) of
        CleanerPid when is_pid(CleanerPid) ->
            erase(?WORKER_CLEANER),
            exit(CleanerPid, kill);
        _ ->
            ok
    end,
    fabric_util:cleanup(Workers).

handle_stream_start({rexi_DOWN, _, {_, NodeRef}, _}, _, St) ->
    #stream_acc{workers = Workers, ready = Ready, ring_opts = RingOpts} = St,
    case fabric_ring:node_down(NodeRef, Workers, Ready, RingOpts) of
        {ok, Workers1} ->
            {ok, St#stream_acc{workers = Workers1}};
        error ->
            {error, {nodedown, <<"progress not possible">>}}
    end;
handle_stream_start({rexi_EXIT, Reason}, Worker, St) ->
    #stream_acc{
        workers = Workers,
        ready = Ready,
        replacements = Replacements,
        ring_opts = RingOpts
    } = St,
    case {fabric_ring:handle_error(Worker, Workers, Ready, RingOpts), Reason} of
        {{ok, Workers1}, _Reason} ->
            {ok, St#stream_acc{workers = Workers1}};
        {error, {maintenance_mode, _Node}} when Replacements /= undefined ->
            % Check if we have replacements for this range
            % and start the new workers if so.
            case lists:keytake(Worker#shard.range, 1, Replacements) of
                {value, {_Range, WorkerReplacements}, NewReplacements} ->
                    FinalWorkers = lists:foldl(
                        fun(Repl, NewWorkers) ->
                            NewWorker = (St#stream_acc.start_fun)(Repl),
                            add_worker_to_cleaner(self(), NewWorker),
                            fabric_dict:store(NewWorker, waiting, NewWorkers)
                        end,
                        Workers,
                        WorkerReplacements
                    ),
                    % Assert that our replaced worker provides us
                    % the oppurtunity to make progress. Need to make sure
                    % to include already processed responses, since we are
                    % checking the full range and some workers have already
                    % responded and were removed from the workers list
                    ReadyWorkers = [{W, R} || {_, W, R} <- Ready],
                    AllWorkers = FinalWorkers ++ ReadyWorkers,
                    true = fabric_ring:is_progress_possible(AllWorkers),
                    NewRefs = fabric_dict:fetch_keys(FinalWorkers),
                    {new_refs, NewRefs, St#stream_acc{
                        workers = FinalWorkers,
                        replacements = NewReplacements
                    }};
                false ->
                    % If we progress isn't possible and we don't have any
                    % replacements then we're dead in the water.
                    {error, {nodedown, <<"progress not possible">>}}
            end;
        {error, _} ->
            {error, fabric_util:error_info(Reason)}
    end;
handle_stream_start(rexi_STREAM_INIT, {Worker, From}, St) ->
    #stream_acc{workers = Workers, ready = Ready, ring_opts = RingOpts} = St,
    case fabric_dict:lookup_element(Worker, Workers) of
        undefined ->
            % This worker lost the race with other partition copies, terminate
            rexi:stream_cancel(From),
            {ok, St};
        waiting ->
            case fabric_ring:handle_response(Worker, From, Workers, Ready, RingOpts) of
                {ok, {Workers1, Ready1}} ->
                    % Don't have a full ring yet. Keep getting responses
                    {ok, St#stream_acc{workers = Workers1, ready = Ready1}};
                {stop, Ready1} ->
                    % Have a full ring of workers. But don't ack the worker
                    % yet so they don't start sending us rows until we're ready
                    {stop, St#stream_acc{workers = [], ready = Ready1}}
            end
    end;
handle_stream_start({ok, Error}, _, St) when Error == ddoc_updated; Error == insufficient_storage ->
    WaitingWorkers = [W || {W, _} <- St#stream_acc.workers],
    ReadyWorkers = [W || {W, _} <- St#stream_acc.ready],
    cleanup(WaitingWorkers ++ ReadyWorkers),
    {stop, Error};
handle_stream_start(Else, _, _) ->
    exit({invalid_stream_start, Else}).

% Spawn an auxiliary rexi worker cleaner. This will be used in cases
% when the coordinator (request) process is forceably killed and doesn't
% get a chance to process its `after` fabric:clean/1 clause.
spawn_worker_cleaner(Coordinator, Workers, ClientReq) ->
    case get(?WORKER_CLEANER) of
        undefined ->
            Pid = spawn(fun() ->
                erlang:monitor(process, Coordinator),
                cleaner_loop(Coordinator, Workers, ClientReq)
            end),
            put(?WORKER_CLEANER, Pid),
            Pid;
        ExistingCleaner ->
            ExistingCleaner
    end.

cleaner_loop(Pid, Workers, ClientReq) ->
    CheckMSec = chttpd_util:mochiweb_client_req_check_msec(),
    receive
        {add_worker, Pid, Worker} ->
            cleaner_loop(Pid, [Worker | Workers], ClientReq);
        {'DOWN', _, _, Pid, _} ->
            fabric_util:cleanup(Workers)
    after CheckMSec ->
        chttpd_util:stop_client_process_if_disconnected(Pid, ClientReq),
        cleaner_loop(Pid, Workers, ClientReq)
    end.

add_worker_to_cleaner(CoordinatorPid, Worker) ->
    case get(?WORKER_CLEANER) of
        CleanerPid when is_pid(CleanerPid) ->
            CleanerPid ! {add_worker, CoordinatorPid, Worker};
        _ ->
            ok
    end.

-ifdef(TEST).

-include_lib("couch/include/couch_eunit.hrl").

worker_cleaner_test_() ->
    {
        "Fabric spawn_worker_cleaner test",
        {
            foreach,
            fun setup/0,
            fun teardown/1,
            [
                ?TDEF_FE(should_clean_workers),
                ?TDEF_FE(does_not_fire_if_cleanup_called),
                ?TDEF_FE(should_clean_additional_worker_too),
                ?TDEF_FE(coordinator_is_killed_if_client_disconnects),
                ?TDEF_FE(coordinator_is_not_killed_if_client_is_connected)
            ]
        }
    }.

should_clean_workers(_) ->
    meck:reset(rexi),
    erase(?WORKER_CLEANER),
    Workers = [
        #shard{node = 'n1', ref = make_ref()},
        #shard{node = 'n2', ref = make_ref()}
    ],
    {Coord, _} = spawn_monitor(fun() ->
        receive
            die -> ok
        end
    end),
    Cleaner = spawn_worker_cleaner(Coord, Workers, undefined),
    Ref = erlang:monitor(process, Cleaner),
    Coord ! die,
    receive
        {'DOWN', Ref, _, Cleaner, _} -> ok
    end,
    ?assertEqual(1, meck:num_calls(rexi, kill_all, 1)).

does_not_fire_if_cleanup_called(_) ->
    meck:reset(rexi),
    erase(?WORKER_CLEANER),
    Workers = [
        #shard{node = 'n1', ref = make_ref()},
        #shard{node = 'n2', ref = make_ref()}
    ],
    {Coord, _} = spawn_monitor(fun() ->
        receive
            die -> ok
        end
    end),
    Cleaner = spawn_worker_cleaner(Coord, Workers, undefined),
    Ref = erlang:monitor(process, Cleaner),
    cleanup(Workers),
    Coord ! die,
    receive
        {'DOWN', Ref, _, _, _} -> ok
    end,
    % 2 calls would be from cleanup/1 function. If cleanup process fired
    % too it would have been 4 calls total.
    ?assertEqual(1, meck:num_calls(rexi, kill_all, 1)).

should_clean_additional_worker_too(_) ->
    meck:reset(rexi),
    erase(?WORKER_CLEANER),
    Workers = [
        #shard{node = 'n1', ref = make_ref()}
    ],
    {Coord, _} = spawn_monitor(fun() ->
        receive
            die -> ok
        end
    end),
    Cleaner = spawn_worker_cleaner(Coord, Workers, undefined),
    add_worker_to_cleaner(Coord, #shard{node = 'n2', ref = make_ref()}),
    Ref = erlang:monitor(process, Cleaner),
    Coord ! die,
    receive
        {'DOWN', Ref, _, Cleaner, _} -> ok
    end,
    ?assertEqual(1, meck:num_calls(rexi, kill_all, 1)).

coordinator_is_killed_if_client_disconnects(_) ->
    meck:reset(rexi),
    erase(?WORKER_CLEANER),
    Workers = [
        #shard{node = 'n1', ref = make_ref()},
        #shard{node = 'n2', ref = make_ref()}
    ],
    {Coord, CoordRef} = spawn_monitor(fun() ->
        receive
            die -> ok
        end
    end),
    Headers = mochiweb_headers:make([]),
    {ok, Sock} = gen_tcp:listen(0, [{active, false}]),
    ClientReq = mochiweb_request:new(Sock, 'GET', "/foo", {1, 1}, Headers),
    % Close the socket and then expect coordinator to be killed
    ok = gen_tcp:close(Sock),
    Cleaner = spawn_worker_cleaner(Coord, Workers, ClientReq),
    CleanerRef = erlang:monitor(process, Cleaner),
    % Assert the correct behavior on the support platforms (all except Windows so far)
    case os:type() of
        {unix, Type} when
            Type =:= linux;
            Type =:= darwin;
            Type =:= freebsd;
            Type =:= openbsd;
            Type =:= netbsd
        ->
            % Coordinator should be torn down
            receive
                {'DOWN', CoordRef, _, _, Reason} ->
                    ?assertEqual({shutdown, client_disconnected}, Reason)
            end,
            % Cleaner process itself should exit
            receive
                {'DOWN', CleanerRef, _, _, _} -> ok
            end,
            % Workers should have been killed
            ?assertEqual(1, meck:num_calls(rexi, kill_all, 1));
        {_, _} = OsType ->
            ?debugFmt("~n * Client disconnect test not yet supported on ~p~n", [OsType])
    end.

coordinator_is_not_killed_if_client_is_connected(_) ->
    meck:reset(rexi),
    erase(?WORKER_CLEANER),
    Workers = [
        #shard{node = 'n1', ref = make_ref()},
        #shard{node = 'n2', ref = make_ref()}
    ],
    {Coord, CoordRef} = spawn_monitor(fun() ->
        receive
            die -> ok
        end
    end),
    Headers = mochiweb_headers:make([]),
    {ok, Sock} = gen_tcp:listen(0, [{active, false}]),
    ClientReq = mochiweb_request:new(Sock, 'GET', "/foo", {1, 1}, Headers),
    Cleaner = spawn_worker_cleaner(Coord, Workers, ClientReq),
    CleanerRef = erlang:monitor(process, Cleaner),
    % Coordinator should stay up
    receive
        {'DOWN', CoordRef, _, Coord, _} ->
            ?assert(false, {unexpected_coordinator_exit, Coord})
    after 1000 ->
        ?assert(is_process_alive(Coord))
    end,
    % Cleaner process stays up
    ?assert(is_process_alive(Cleaner)),
    % Tear everything down at the end of the test
    gen_tcp:close(Sock),
    Coord ! die,
    receive
        {'DOWN', CleanerRef, _, _, _} -> ok
    end.

setup() ->
    ok = meck:expect(rexi, kill_all, fun(_) -> ok end),
    % Speed up disconnect socket timeout for the test to 200 msec
    ok = meck:expect(chttpd_util, mochiweb_client_req_check_msec, 0, 200).

teardown(_) ->
    meck:unload().

-endif.
