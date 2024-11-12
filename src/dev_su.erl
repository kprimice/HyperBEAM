-module(dev_su).
%%% Local scheduling functions:
-export([schedule/1]).
%%% CU-flow functions:
-export([init/2, end_of_schedule/1, uses/0, checkpoint/1]).
%%% MU-flow functions:
-export([push/2]).

-include("include/ao.hrl").

%%% A simple scheduler scheme for AO.
%%% The module is composed of three parts:
%%% 1. The HTTP interface for the scheduler itself.
%%% 2. The 'push' client function needed for dispatching messages to the SU.
%%% 3. The device client functions needed in order to manage a schedule
%%%    for the execution of processes.

%%% HTTP API functions:
schedule(Item) ->
    {ok, Output} = su_http:handle(Item),
	%?debug_wait(1000),
    {ok, Output}.

%%% MU pushing client functions:
push(Msg, State = #{ logger := Logger }) ->
    ?c(su_scheduling_message_for_push),
    case ao_client:schedule(Msg) of
        {ok, Assignment} ->
			?c({scheduled_message, ar_util:id(Assignment, unsigned)}),
            {ok, State#{assignment => Assignment}};
        Error ->
			?c({error_scheduling_message, Error}),
            ao_logger:log(Logger, Error),
            {error, Error}
    end;
push(Arg1, Arg2) ->
	?c({unhandled_push_args, maps:keys(Arg2)}),
	{error, unhandled_push_args}.

%%% Process/device client functions:
init(State, [{<<"Location">>, Location} | _]) ->
    case State of
        #{schedule := Schedule} when Schedule =/= [] ->
            {ok, State};
        _ ->
            {ok, update_schedule(State#{su_location => Location})}
    end;
init(State, _) ->
    {ok, State}.

end_of_schedule(State) -> {ok, update_schedule(State)}.

update_schedule(State = #{ process := Proc }) ->
    Store = maps:get(store, State, ao:get(store)),
    CurrentSlot = maps:get(slot, State, 0),
    ToSlot = maps:get(to, State),
    ?c({updating_schedule_current, CurrentSlot, to, ToSlot}),
    % TODO: Get from slot via checkpoint. (Done, right?)
    Assignments = ao_client:get_assignments(ar_util:id(Proc, signed), CurrentSlot, ToSlot),
    ?c({got_assignments_from_su,
		[
			{
				element(2, lists:keyfind(<<"Assignment">>, 1, A#tx.tags)),
				ar_util:id(A, signed),
				ar_util:id(A, unsigned)
			}
		|| A <- Assignments ]}),
    lists:foreach(
        fun(Assignment) ->
            ?c({writing_assignment_to_cache, ar_util:id(Assignment, unsigned)}),
            ao_cache:write(Store, Assignment)
        end,
        Assignments
    ),
    State#{schedule => Assignments}.

checkpoint(State) -> {ok, State}.

uses() -> all.