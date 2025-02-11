%%% @doc Simple wrapper module that enables compute on remote machines,
%%% implementing the JSON-Iface. This can be used either as a standalone, to 
%%% bring trusted results into the local node, or as the `Execution-Device' of
%%% an AO process.
-module(dev_compute_lite).
-export([compute/3]).
-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

compute(Msg1, Msg2, Opts) ->
    OutputPrefix = dev_stack:prefix(Msg1, Msg2, Opts),
    Slot = hb_converge:get(<<"slot">>, Msg2, Opts),
    Accept = hb_converge:get(<<"accept">>, Msg2, <<"application/http">>, Opts),
    ProcessID =
        hb_converge:get_first(
            [
                {Msg1, <<"process/id">>},
                {Msg2, <<"process-id">>}
            ],
            Opts
        ),
    {ok, JSONRes} = do_compute(ProcessID, Slot, Opts),
    case Accept of
        <<"application/http">> ->
            {ok, Msg} = dev_json_iface:json_to_message(JSONRes, Opts),
            {ok,
                hb_converge:set(
                    Msg1,
                    <<OutputPrefix/binary, "/results">>,
                    Msg,
                    Opts
                )
            };
        <<"application/json">> ->
            {ok, #{ <<"body">> => JSONRes }}
    end.

%% @doc Execute computation on a remote machine via relay and the JSON-Iface.
do_compute(ProcID, Slot, Opts) ->
    Res = 
        hb_converge:resolve(#{ <<"device">> => <<"relay@1.0">> }, #{
            <<"path">> => <<"call">>,
            <<"relay-path">> =>
                <<
                    "/result/",
                    (integer_to_binary(Slot))/binary,
                    "?process-id=",
                    ProcID/binary
                >>
            },
            Opts
        ),
    ?event({res, Res}),
    {ok, Response} = Res,
    JSONRes = hb_converge:get(<<"body">>, Response, Opts),
    ?event({json_res, JSONRes}),
    {ok, JSONRes}.