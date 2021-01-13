-module(ecredis).

-define(ECREDIS_SERVER, ecredis_server).

%% API.
-export([
    start_link/1,
    q/2,
    qp/2
]).

-ifdef(TEST).
-export([query_by_slot/1]).
-endif.

-include("ecredis.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link({ClusterName :: atom(), InitNodes :: [{}]}) -> {ok, pid()}.
start_link({ClusterName, InitNodes}) ->
    gen_server:start_link({local, ClusterName}, ?ECREDIS_SERVER, [ClusterName, InitNodes], []).


-spec qp(ClusterName :: atom(), Commands :: redis_pipeline_command()) -> redis_pipeline_result().
qp(ClusterName, Commands) ->
    Query = #query{
        query_type = qp,
        cluster_name = ClusterName,
        command = Commands,
        indices = lists:seq(1, length(Commands))
    },
    case query_by_command(Query) of
        {ok, Response} ->
            Response;
        {error, Reason} ->
            Reason
    end.


-spec q(ClusterName :: atom(), Command :: redis_command()) -> redis_result().
q(ClusterName, Command) ->
    Query = #query{
        query_type = q,
        cluster_name = ClusterName,
        command = Command,
        indices = [1]
    },
    case query_by_command(Query) of
        {ok, Response} ->
            Response;
        {error, Reason} ->
            Reason
    end.
    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% INTERNAL FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% @doc Use the command of the given query to determine which slot the command
%% should be sent to, then update the query config and query by slot
-spec query_by_command(Query :: #query{}) -> {ok, redis_result()} | {error, term()}.
query_by_command(#query{command = Command} = Query) ->
    case ecredis_command_parser:get_key_from_command(Command) of
        undefined ->
            ecredis_logger:log_error("Unable to execute - invalid cluster key~n", Query),
            {error, {invalid_cluster_key, Command}};
        Key ->
            Slot = ecredis_command_parser:get_key_slot(Key),
            NewQuery = Query#query{slot = Slot, version = 0, retries = 0},
            case query_by_slot(NewQuery) of
                #query{response = Response} ->
                    {ok, Response};
                Err ->
                    {error, Err}
            end
    end.


%% @doc Use the slot of the given query to determine where to send the command,
%% then update the query config and execute the query
-spec query_by_slot(Query :: #query{}) -> #query{}.
query_by_slot(#query{retries = Retries} = Query) when Retries >= ?REDIS_CLUSTER_REQUEST_TTL ->
    % Recursion depth is reached - return the most recent error
    ecredis_logger:log_error("Max retries reached", Query),
    Query;
query_by_slot(#query{command = Command, retries = Retries} = Query) ->
    NewQuery = case get_pid_and_map_version(Query) of
        undefined ->
            ecredis_logger:log_error("Unable to execute - slot has no connection", Query),
            % Slot was not mapped to any pid - remap the cluster and try again 
            remap_cluster(Query),
            query_by_slot(Query#query{
                response = {error, no_connection, Command},
                retries = Retries + 1
            });
        {Pid, Version} ->
            Query#query{pid = Pid, version = Version}
    end,
    execute_query(NewQuery).


%% @doc Execute the given query. Separate out the successful commands and retry
%% any commands that fail. If the recursion depth is reached, just return the error.
-spec execute_query(#query{}) -> #query{}.
execute_query(#query{retries = Retries} = Query) when Retries >= ?REDIS_CLUSTER_REQUEST_TTL ->
    % Recursion depth is reached - return the most recent error
    ecredis_logger:log_error("Max retries reached", Query),
    Query;
execute_query(#query{command = Command, retries = Retries, pid = Pid} = Query) ->
    throttle_retries(Retries),
    NewQuery = Query#query{response = eredis_query(Pid, Command)},
    case get_successes_and_retries(NewQuery) of
        {_Successes, []} ->
            % All commands were successful - return the query as is
            NewQuery;
        {Successes, QueriesToResend} ->
            check_sanity_if_qp(Query),
            % Reexecute all queries that failed
            NewSuccesses = [execute_query(Q) || Q <- QueriesToResend],
            % Remove any (ASKING, <<"OK">>) command/response pairs that are
            % artifacts from redirection
            NewSuccesses2 = [filter_out_asking_result(Q) || Q <- NewSuccesses],
            % Put the original successes and new successes back in order
            {Indices, Responses} = lists:unzip(merge_responses(NewSuccesses2 ++ Successes)),
            % Update the query config with the full, ordered set of responses
            Query#query{indices = Indices, response = Responses}
    end.

%% @doc Separates successful commands form those that need to be retried. If the
%% command got a redirect error, make a new query config with the updated pid
-spec get_successes_and_retries(#query{}) -> {[#query{}], [#query{}]}.
get_successes_and_retries(#query{response = {ok, _}} = Query) ->
    % The query was successful - add the query to the successes list
    {[Query], []};
get_successes_and_retries(#query{
        response = {error, <<"MOVED ", Dest/binary>>},
        retries = Retries} = Query) ->
    % The command was sent to the wrong node - refresh the mapping, update
    % the query to reflect the new pid, and add the query to the retries list
    ecredis_logger:log_warning("MOVED", Query),
    case get_destination_pid(Query, Dest) of
        {ok, Slot, Pid} ->
            remap_cluster(Query),
            {[], [Query#query{
                slot = Slot,
                pid = Pid,
                retries = Retries + 1
            }]};
        undefined ->
            % Unable to connect to the redirect destination. Return the error as-is
            {[Query], []}
    end;
get_successes_and_retries(#query{
        command = Command,
        response = {error, <<"ASK ", Dest/binary>>},
        retries = Retries} = Query) ->
    % The command's slot is in the process of migration - upate the query to reflect
    % the new pid, prepend the ASKING command, and add the query to the retries list
    ecredis_logger:log_warning("ASK", Query),
    case get_destination_pid(Query, Dest) of
        {ok, Slot, Pid} ->
            {[], [Query#query{
                command = [["ASKING"], Command],
                slot = Slot,
                pid = Pid,
                retries = Retries + 1
            }]};
        undefined ->
            % Unable to connect to the redirect destination. Return the error as-is
            {[Query], []}
    end;
get_successes_and_retries(#query{response = {error, _}, retries = Retries} = Query) ->
    % TODO fill in handlers for other errors, as for when to retry or when to not
    % - TRYAGAIN should retry
    % - CLUSTERDOWN should retry
    % - tcp_closed?
    % - no_connection?
    ecredis_logger:log_error("Other error", Query),
    {[], [Query#query{retries = Retries + 1}]};
get_successes_and_retries(#query{
        command = Commands,
        response = Responses,
        indices = Indices} = Query) when is_list(Responses) ->
    % TODO group queries by destination to save trips to redis
    % Check each command in a pipeline individually for errors, then aggregate
    % the lists of successes and retries
    IndexCommandResponseList = lists:zip3(Indices, Commands, Responses),
    % Separate the pipeline into individual commands
    PossibleRetries = [Query#query{
        command = Command,
        response = Response,
        indices = [Index]} || {Index, Command, Response} <- IndexCommandResponseList],
    {Successes, NeedToRetries} = lists:unzip([get_successes_and_retries(Q) || Q <- PossibleRetries]),
    {lists:flatten(Successes), lists:flatten(NeedToRetries)}.


%% @doc Send the command to the given redis node 
-spec eredis_query(pid(), redis_command()) -> redis_result().
eredis_query(Pid, [[X|_]|_] = Commands) when is_list(X); is_binary(X) ->
    eredis:qp(Pid, Commands);
eredis_query(Pid, Command) ->
    eredis:q(Pid, Command).


%% @doc If the command is being retried, sleep the process for a little bit to 
%% allow for remapping to occur
-spec throttle_retries(integer()) -> ok.
throttle_retries(0) ->
    ok;
throttle_retries(_) ->
    timer:sleep(?REDIS_RETRY_DELAY).


%% @doc Get the pid associated with the given destination. lookup_eredis_pid/2
%% will attempt to start a new connection if one does not already exist
-spec get_destination_pid(#query{}, binary()) -> {ok, integer(), pid()} | undefined.
get_destination_pid(#query{cluster_name = ClusterName}, Dest) ->
    [SlotBin, AddrPort] = binary:split(Dest, <<" ">>),
    [Address, Port] = binary:split(AddrPort, <<":">>),
    Node = #node{address = binary_to_list(Address), port = binary_to_integer(Port)},
    case ecredis_server:lookup_eredis_pid(ClusterName, Node) of
        {ok, Pid} ->
            {ok, binary_to_integer(SlotBin), Pid};
        undefined ->
            undefined
    end.


%% @doc Use the indices list from a query to tag each of the responses.
-spec index_responses(#query{}) -> [{integer(), redis_result()}].
index_responses(#query{response = Responses, indices = Indices}) when is_list(Responses) ->
    lists:zip(Indices, Responses);
index_responses(#query{response = Response, indices = [Index]}) ->
    [{Index, Response}].


%% @doc Merge the responses of all of the queries based on the indices of the
%% resonses. Used to re-order the responses if some had to be resent due to errors
-spec merge_responses([[#query{}]]) -> [{integer(), redis_result()}].
merge_responses(QueryList) ->
    IndexedResponses = lists:map(fun index_responses/1, QueryList),
    lists:merge(IndexedResponses).


%% @doc When a query receives an ASK response, we prepend the ASKING command
%% onto that query to allow the query to be serviced. An ASKING command receives
%% <<"OK">> from redis. But, the client didn't send these commands, so we need to
%% remove these responses so they don't get returned to the client. 
-spec filter_out_asking_result(#query{}) -> #query{}.
filter_out_asking_result(#query{command = Commands, response = Responses} = Query)
        when is_list(Commands), is_list(Responses) ->
    {FilteredCommands, FilteredResponses} = lists:unzip(lists:filter(fun
        ({["ASKING"], {ok, <<"OK">>}}) -> 
            false;
        (_) ->
            true
        end, lists:zip(Commands, Responses))),
    Query#query{command = FilteredCommands, response = FilteredResponses};
filter_out_asking_result(Query) ->
    % Single command
    Query.


%% @doc This is just a wrapper to allow for a cleaner interface above :)
-spec remap_cluster(#query{}) -> {ok, integer()}.
remap_cluster(#query{cluster_name = ClusterName, version = Version}) ->
    ecredis_server:remap_cluster(ClusterName, Version).


%% @doc This is just a wrapper to allow for a cleaner interface above :)
-spec get_pid_and_map_version(#query{}) -> {pid(), integer()} | undefined.
get_pid_and_map_version(#query{cluster_name = ClusterName, slot = Slot}) ->
    ecredis_server:get_eredis_pid_by_slot(ClusterName, Slot).


-spec check_sanity_if_qp(#query{}) -> ok.
check_sanity_if_qp(#query{query_type = qp, command = Commands} = Query) ->
    case ecredis_command_parser:check_sanity_of_keys(Commands) of
        ok ->
            ok;
        error ->
            ecredis_logger:log_error("All keys in pipeline command are not mapped to the same slot", Query),
            ok
    end;
check_sanity_if_qp(_Query) ->
    ok.

% check_for_moved_errors([{error, <<"MOVED ", _/binary>>} | _Rest]) ->
%     true;
% check_for_moved_errors([_ | Rest]) ->
%     check_for_moved_errors(Rest);
% check_for_moved_errors(_) ->
%     false.

