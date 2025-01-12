%%% @doc A router that attaches a HTTP server to the Converge resolver.
%%% Because Converge is built to speak in HTTP semantics, this module
%%% only has to marshal the HTTP request into a message, and then
%%% pass it to the Converge resolver. 
%%% 
%%% `hb_http:reply/3' is used to respond to the client, handling the 
%%% process of converting a message back into an HTTP response.
%%% 
%%% The router uses an `Opts` message as its Cowboy initial state, 
%%% such that changing it on start of the router server allows for
%%% the execution parameters of all downstream requests to be controlled.
-module(hb_http_server).
-export([start/0, start/1, allowed_methods/2, init/2, set_opts/1]).
-export([start_test_node/0, start_test_node/1]).
-include_lib("eunit/include/eunit.hrl").
-include("include/hb.hrl").

%% @doc Starts the HTTP server. Optionally accepts an `Opts` message, which
%% is used as the source for server configuration settings, as well as the
%% `Opts` argument to use for all Converge resolution requests downstream.
start() ->
    start(#{
        store => hb_opts:get(store),
        wallet => hb_opts:get(wallet),
        port => 8734
    }).

start(Opts) ->
    hb_http:start(),
    Port = hb_opts:get(port, no_port, Opts),
    Dispatcher =
        cowboy_router:compile(
            [
                % {HostMatch, list({PathMatch, Handler, InitialState})}
                {'_', [
                    {
                        "/metrics/[:registry]",
                        prometheus_cowboy2_handler,
                        #{}
                    },
                    {
                        '_',
                        ?MODULE,
                        % The default opts for executions from the HTTP API.
                        % We force a specific store, wallet, and that 
                        % hb_converge should return a regardless of whether 
                        % the result comes wrapped in one or not.
                        Port
                    }
                ]}
            ]
        ),
    {ok, Listener} = cowboy:start_clear(
        {?MODULE, Port}, 
        [{port, Port}],
        #{
            env => #{dispatch => Dispatcher, opts => Opts},
            metrics_callback =>
                fun prometheus_cowboy2_instrumenter:observe/1,
            stream_handlers => [cowboy_metrics_h, cowboy_stream_h]
        }
    ),
    ?event(debug,
        {http_server_started,
            {listener, Listener},
            {port, Port}
        }
    ),
    {ok, Listener}.

init(Req, Port) ->
    Opts = cowboy:get_env({?MODULE, Port}, opts, no_opts),
    % Parse the HTTP request into HyerBEAM's message format.
    MsgSingleton = hb_http:req_to_message(Req, Opts),
    ?event(debug, {http_inbound, MsgSingleton}),
    % Execute the message through Converge Protocol.
    {ok, RawRes} = hb_converge:resolve(MsgSingleton, Opts),
    % Sign the transaction if it's not already signed.
    IsForceSigned = hb_opts:get(force_signed, false, Opts),
    Signed =
        case IsForceSigned andalso hb_message:signers(RawRes) of
            [] ->
                hb_message:sign(
                    RawRes, hb_opts:get(wallet, no_wallet, Opts));
            _ -> RawRes
        end,
    % Respond to the client.
    hb_http:reply(
        Req,
        hb_http:message_to_status(Signed),
        Signed
    ).

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>], Req, State}.

%% @doc Update the `Opts` map that the HTTP server uses for all future
%% requests.
set_opts(Opts) ->
    Port = hb_opts:get(port, no_port, Opts),
    cowboy:set_env({?MODULE, Port}, opts, Opts).

%%% Tests

test_opts(Opts) ->
    rand:seed(default),
    % Generate a random port number between 42000 and 62000 to use
    % for the server.
    Port = 42000 + rand:uniform(20000),
    Wallet = ar_wallet:new(),
    Opts#{
        % Generate a random port number between 8000 and 9000.
        port => Port,
        store =>
            [
                {hb_store_fs,
                    #{prefix => "TEST-cache-" ++ integer_to_list(Port)}
                }
            ],
        wallet => Wallet
    }.

%% @doc Test that we can start the server, send a message, and get a response.
start_test_node() ->
    start_test_node(#{}).
start_test_node(Opts) ->
    application:ensure_all_started([
        kernel,
        stdlib,
        inets,
        ssl,
        debugger,
        cowboy,
        gun,
        prometheus,
        prometheus_cowboy,
        os_mon,
        rocksdb
    ]),
    hb:init(),
    hb_sup:start_link(Opts),
    ServerOpts = test_opts(Opts),
    start(ServerOpts),
    Port = hb_opts:get(port, no_port, ServerOpts),
    <<"http://localhost:", (integer_to_binary(Port))/binary, "/">>.

raw_http_access_test() ->
    URL = start_test_node(),
    TX =
        ar_bundles:serialize(
            hb_message:convert(
                #{
                    path => <<"Key1">>,
                    <<"Key1">> => #{ <<"Key2">> => <<"Value1">> }
                },
                tx,
                converge,
                #{}
            )
        ),
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(
            post,
            {iolist_to_binary(URL), [], "application/octet-stream", TX},
            [],
            [{body_format, binary}]
        ),
    Msg = hb_message:convert(ar_bundles:deserialize(Body), converge, tx, #{}),
    ?assertEqual(<<"Value1">>, hb_converge:get(<<"Key2">>, Msg, #{})).