-module(hb_converge).
%%% Main Converge API:
-export([resolve/2, resolve/3, load_device/2]).
-export([to_key/1, to_key/2, key_to_binary/1, key_to_binary/2]).
%%% Shortcuts and tools:
-export([keys/1, keys/2, keys/3]).
-export([get/2, get/3, get/4, set/2, set/3, set/4, remove/2, remove/3]).
-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% @moduledoc This module is the root of the device call logic of the 
%%% Converge Protocol in HyperBEAM.
%%% 
%%% At the implementation level, every message is simply a collection of keys,
%%% dictated by its `Device`, that can be resolved in order to yield their
%%% values. Each key may return another message or a raw value:
%%% 
%%% 	converge(Message1, Message2) -> {Status, Message3}
%%% 
%%% Under-the-hood, `Converge(Message1, Message2)` leads to the evaluation of
%%% `DeviceMod:PathPart(Message1, Message2)`, which defines the user compute
%%% to be performed. If `Message1` does not specify a device, `dev_message` is
%%% assumed. The key to resolve is specified by the `Path` field of the message.
%%% 
%%% After each output, the `HashPath` is updated to include the `Message2`
%%% that was executed upon it.
%%% 
%%% Because each message implies a device that can resolve its keys, as well
%%% as generating a merkle tree of the computation that led to the result,
%%% you can see Converge Protocol as a system for cryptographically chaining 
%%% the execution of `combinators`. See `docs/converge-protocol.md` for more 
%%% information about Converge.
%%% 
%%% The `Fun(Message1, Message2)` pattern is repeated throughout the HyperBEAM 
%%% codebase, sometimes with `MessageX` replaced with `MX` or `MsgX` for brevity.
%%% 
%%% Message3 can be either a new message or a raw output value (a binary, integer,
%%% float, atom, or list of such values).
%%% 
%%% Devices can be expressed as either modules or maps. They can also be 
%%% referenced by an Arweave ID, which can be used to load a device from 
%%% the network (depending on the value of the `load_remote_devices' and 
%%% `trusted_device_signers' environment settings).
%%% 
%%% HyperBEAM device implementations are defined as follows:
%%% 
%%%     DevMod:ExportedFunc : Key resolution functions. All are assumed to be
%%%                           device keys (thus, present in every message that
%%%                           uses it) unless specified by `DevMod:info()`.
%%%                           Each function takes a set of parameters
%%%                           of the form `DevMod:KeyHandler(Msg1, Msg2, Opts)`.
%%%                           Each of these arguments can be ommitted if not
%%%                           needed. Non-exported functions are not assumed
%%%                           to be device keys.
%%%
%%%     DevMod:info : Optional. Returns a map of options for the device. All 
%%%                   options are optional and assumed to be the defaults if 
%%%                   not specified. This function can accept a `Message1` as 
%%%                   an argument, allowing it to specify its functionality 
%%%                   based on a specific message if appropriate.
%%% 
%%%     info/exports : Overrides the export list of the Erlang module, such that
%%%                   only the functions in this list are assumed to be device
%%%                   keys. Defaults to all of the functions that DevMod 
%%%                   exports in the Erlang environment.
%%% 
%%%     info/handler : A function that should be used to handle _all_ keys for 
%%%                    messages using the device.
%%% 
%%%     info/default : A function that should be used to handle all keys that
%%%                    are not explicitly implemented by the device. Defaults to
%%%                    the `dev_message` device, which contains general keys for 
%%%                    interacting with messages.
%%% 
%%%     info/default_mod : A different device module that should be used to
%%%                        handle all keys that are not explicitly implemented
%%%                        by the device. Defaults to the `dev_message` device.
%%% 
%%% The HyperBEAM resolver also takes a number of runtime options that change
%%% the way that the environment operates:
%%% 
%%% `update_hashpath`:  Whether to add the `Msg2` to `HashPath` for the `Msg3`.
%%% 					Default: true.
%%% `cache_results`:    Whether to cache the resolved `Msg3`.
%%% 					Default: true.
%%% `add_key`:          Whether to add the key to the start of the arguments.
%%% 					Default: <not set>.

%% @doc Takes a singleton message and parse Msg1 and Msg2 from it, then invoke
%% `resolve`.
resolve(Msg, Opts) ->
    Path =
        hb_path:term_to_path(
            hb_converge:get(
                path,
                Msg,
                #{ hashpath => ignore }
            ),
            Opts
        ),
    case Path of
        [ Msg1ID | _Rest ] when ?IS_ID(Msg1ID) ->
            ?event({normalizing_single_message_message_path, Msg}),
            {ok, Msg1} = hb_cache:read(Msg1ID, Opts),
            resolve(
                Msg1,
                hb_path:tl(Msg, Opts),
                Opts
            );
        SingletonPath ->
            resolve(Msg, #{ path => SingletonPath }, Opts)
    end.

%% @doc Get the value of a message's key by running its associated device
%% function. Optionally, takes options that control the runtime environment. 
%% This function returns the raw result of the device function call:
%% {ok | error, NewMessage}.
resolve(Msg1, Msg2, Opts) ->
    resolve_stage(1, Msg1, Msg2, Opts).

%% @doc Internal function for handling request resolution.
%% The resolver is composed of a series of discrete phases:
%%      1: Request normalization.
%%      2: Cache lookup.
%%      3: Device lookup.
%%      4: Concurrent-resolver lookup.
%%      5: Execution.
%%      6: Cryptographic linking.
%%      7: Result caching.
%%      8: Notify waiters.
%%      9: Recurse, fork, or terminate.
resolve_stage(1, Msg1, Msg2, Opts) when is_map(Msg2) and is_map(Opts) ->
    Key = hb_path:hd(Msg2, Opts),
    case ?IS_ID(Key) of
        true ->
            % The key is an ID (reference call), so we should resolve the
            % referenced message against Msg1. 
            {ok, Msg2Indirect} = hb_cache:read(Key, Opts),
            case resolve(Msg1, Msg2Indirect, Opts) of
                {ok, Msg3Indirect} ->
                    resolve(Msg3Indirect, hb_path:tl(Msg2, Opts), Opts);
                {error, _} ->
                    throw({error, {device_not_loadable, Key}})
            end;
        false ->
            % This is a direct invocation, so just proceed with the normal
            % resolution process.
            resolve_stage(2, Msg1, Msg2, Opts)
    end;
resolve_stage(1, Msg1, Path, Opts) ->
    % If we have been given a Path rather than a full message, construct the
    % message around it and recurse.
    resolve_stage(1, Msg1, #{ path => Path }, Opts);
resolve_stage(2, Msg1, Msg2 = #{ path := Path }, Opts) ->
    %% Cache lookup: Check if we already have the result of `resolve(Msg1, Msg2)`
    %% in the appropriate caches.
    case hb_cache:read(Path, Opts) of
        {ok, Msg3} -> {ok, Msg3};
        not_found -> resolve_stage(3, Msg1, Msg2, Opts)
    end;
resolve_stage(3, Msg1, Msg2, Opts) ->
    %% Device lookup: Find the Erlang function that should be utilized to 
    %% execute Msg2 on Msg1.
	{ResolvedMod, ResolvedFunc, NewOpts} =
		try
			Key = hb_path:hd(Msg2, Opts),
			% Try to load the device and get the function to call.
			{Status, Mod, Func} = message_to_fun(Msg1, Key, Opts),
			?event(
				{resolving, Key,
					{func, Func},
					{msg1, Msg1},
					{msg2, Msg2},
					{opts, Opts}
				}
			),
			% Next, add an option to the Opts map to indicate if we should
			% add the key to the start of the arguments.
			{
                Mod,
				Func,
				Opts#{
					add_key =>
						case Status of
							add_key -> Key;
							_ -> false
						end
				}
			}
		catch
			Class:Exception:Stacktrace ->
                % If the device cannot be loaded, we alert the caller.
				handle_error(
					loading_device,
					{Class, Exception, Stacktrace},
					Opts
				)
		end,
	resolve_stage(4, ResolvedMod, ResolvedFunc, Msg1, Msg2, NewOpts).
resolve_stage(4, Mod, Func, Msg1, Msg2, Opts) ->
    % Concurrent-resolver lookup: Search for local (or Distributed
    % Erlang cluster) processes that are already performing the execution.
    % Before we search for a live executor, we check if the device specifies 
    % a function that tailors the 'group' name of the execution. For example, 
    % the `dev_process` device 'groups' all calls to the same process onto
    % calls to a single executor. By default, `{Msg1, Msg2}` is used as the
    % group name.
    Group =
        case info(Mod, Msg2, Opts) of
            #{ group := GroupFunc } ->
                apply(GroupFunc, truncate_args(Func, [Msg1, Msg2, Opts]));
            _ -> {Msg1, Msg2}
        end,
    case pg:get_local_members(Group) of
        [] ->
            % Register ourselves as members of the group
            pg:join(Group, self()),
            % Remember the group we joined for the post-execution steps.
            resolve_stage(5, Mod, Func, Msg1, Msg2,
                Opts#{ groups => maps:get(groups, Opts, []) });
        [Leader|_] ->
            % There is another executor of this resolution in-flight.
            % Bail execution, register to receive the response, then
            % wait.
            await_resolution(Leader, Msg1, Msg2, Opts)
    end;
resolve_stage(5, Mod, Func, Msg1, Msg2, Opts) ->
	% Execution.
	% First, determine the arguments to pass to the function.
	% While calculating the arguments we unset the add_key option.
	UserOpts = maps:remove(add_key, Opts),
	Args =
		case maps:get(add_key, Opts, false) of
			false -> [Msg1, Msg2, UserOpts];
			Key -> [Key, Msg1, Msg2, UserOpts]
		end,
    % Try to execute the function.
    Res = 
        try apply(Func, truncate_args(Func, Args))
        catch
            ExecClass:ExecException:ExecStacktrace ->
                % If the function call fails, we raise an error in the manner
                % indicated by caller's `#Opts`.
                handle_error(
                    device_call,
                    {ExecClass, ExecException, ExecStacktrace},
                    Opts
                )
        end,
    % Handle the result of the function call.
    case Res of
        {ok, Msg3} ->
            % Result is normal. Continue to the next stage.
            resolve_stage(6, Mod, Msg1, Msg2, Msg3, UserOpts);
        AbnormalRes ->
            % Result is abnormal. Skip cryptographic linking, such
            % that we do not attest to false results.
            resolve_stage(7, Mod, Msg1, Msg2, AbnormalRes, UserOpts)
    end;
resolve_stage(6, Mod, Msg1, Msg2, Result, Opts) when not is_map(Result) ->
    % Skip cryptographic linking if the result is not a map.
    resolve_stage(7, Mod, Msg1, Msg2, Result, Opts);
resolve_stage(6, Mod, Msg1, Msg2, Msg3, Opts) ->
    % Cryptographic linking. Now that we have generated the result, we
    % need to cryptographically link the output to its input via a hashpath.
    resolve_stage(7, Mod, Msg1, Msg2,
        case hb_opts:get(hashpath, update, Opts#{ only => local }) of
            update -> hb_path:push(hashpath, Msg3, Msg2);
            ignore -> Msg3
        end,
        Opts
    );
resolve_stage(7, Mod, Msg1, Msg2, Msg3, Opts) ->
    % Result caching: Optionally, cache the result of the computation locally.
    update_cache(Msg1, Msg2, Msg3, Opts),
    resolve_stage(8, Mod, Msg1, Msg2, Msg3, Opts);
resolve_stage(8, Mod, Msg1, Msg2, Msg3, Opts) ->
    % Notify waiters.
    notify_waiting(Msg1, Msg2, Msg3, Opts),
    resolve_stage(9, Mod, Msg1, Msg2, Msg3, Opts);
resolve_stage(9, Mod, _Msg1, Msg2, Msg3, Opts) ->
    % Recurse, fork, or terminate.
	case hb_path:tl(Msg2, Opts) of
		NextMsg when NextMsg =/= undefined ->
			% There are more elements in the path, so we recurse.
			?event({resolution_recursing, {next_msg, NextMsg}}),
			resolve(Msg3, NextMsg, Opts);
		undefined ->
			% The path resolved to the last element, so we check whether
            % we should fork a new process with Msg3 waiting for messages,
            % or simply return to the caller. We prefer the global option, such
            % that node operators can control whether devices are able to 
            % generate long-running executions.
            case hb_opts:get(spawn_worker, false, Opts#{ prefer => global }) of
                false -> ok;
                true ->
                    % We should spin up a process that will hold `Msg3` 
                    % in memory for future executions.
                    WorkerPID = spawn(
                        fun() ->
                            % If the device's info contains a `worker` key we
                            % use that instead of the default worker function.
                            WorkerFun =
                                maps:get(
                                    worker,
                                    info(Mod, Msg3, Opts),
                                    fun worker/2
                                ),
                            % Call the worker function, unsetting the option
                            % to avoid recursive spawns.
                            apply(
                                WorkerFun,
                                truncate_args(WorkerFun, [Msg3, Opts])
                            )
                        end
                    ),
                    % Unregister ourselves from the group and register the
                    % forked process instead. The `groups` option in `Opts`
                    % acts as a stack, ensuring that recursive executions 
                    % (un)register to the correct group.
                    [ExecGroup|_] = hb_opts:get(groups, Opts),
                    pg:leave(ExecGroup, [self()]),
                    pg:join(ExecGroup, [WorkerPID])
            end,
            % Resolution has finished successfully, return to the
            % caller.
			?event({resolution_complete, {result, Msg3}, {request, Msg2}}),
            {ok, Msg3}
	end.

%% @doc A server function for handling persistent executions. These can be
%% useful for situations where a message is large and expensive to serialize
%% and deserialize, or when executions should be deliberately serialized
%% to avoid paralell executions of the same computation.
worker(Msg1, Opts) ->
    Timeout = hb_opts:get(worker_timeout, infinity, Opts),
    receive
        {resolve, Listener, Msg1, Msg2, _ListenerOpts} ->
            Msg3 = resolve(Msg1, Msg2, Opts),
            Listener ! {resolved, self(), Msg1, Msg2, Msg3},
            % In this (default) worker implementation we do not advance the
            % process to monitor resolution of `Msg3`, staying instead with
            % Msg1 indefinitely.
            worker(Msg1, Opts)
    after Timeout ->
        % We have hit the in-memory persistence timeout. Check whether the
        % device has shutdown procedures (for example, writing in-memory
        % state to the cache).
        resolve(Msg1, terminate, Opts#{ hashpath := ignore })
    end.

%% @doc If there was already an Erlang process handling this execution,
%% we should register with them and wait for them to notify us of
%% completion.
await_resolution(Leader, Msg1, Msg2, Opts) ->
    % Calculate the compute path that we will wait upon resolution of.
    % Register with the process.
    ?no_prod("We should find a more efficient way to represent the "
        "requested execution. This may cause memory issues."),
    Leader ! {resolve, self(), Msg1, Msg2, Opts},
    % Wait for the result.
    receive
        {resolved, Leader, Msg1, Msg2, Result} ->
            ?no_prod("Should we handle response matching in a more "
            " fine-grained manner?"),
            Result
    end.

%% @doc Check our inbox for processes that are waiting for the resolution
%% of this execution.
notify_waiting(Msg1, Msg2, Msg3, Opts) ->
    receive
        {resolve, Listener, Msg1, Msg2, _ListenerOpts} ->
            Listener ! {resolved, self(), Msg1, Msg2, Msg3},
            notify_waiting(Msg1, Msg2, Msg3, Opts)
    after 0 ->
        ok
    end.

%% @doc Write a resulting M3 message to the cache if requested.
update_cache(Msg1, Msg2, Msg3, Opts) ->
    ExecCacheSetting = hb_opts:get(cache, always, Opts),
    M1CacheSetting = dev_message:get(<<"Cache-Control">>, Msg1, Opts),
    M2CacheSetting = dev_message:get(<<"Cache-Control">>, Msg2, Opts),
    case must_cache(ExecCacheSetting, M1CacheSetting, M2CacheSetting) of
        true ->
            case hb_opts:get(async_cache, false, Opts) of
                true ->
                    spawn(fun() ->
                        hb_cache:write_result(Msg1, Msg2, Msg3, Opts)
                    end);
                false ->
                    hb_cache:write_result(Msg1, Msg2, Msg3, Opts)
            end;
        false -> ok
    end.

%% @doc Takes the `Opts` cache setting, M1, and M2 `Cache-Control` headers, and
%% returns true if the message should be cached.
must_cache(no_cache, _, _) -> false;
must_cache(no_store, _, _) -> false;
must_cache(none, _, _) -> false;
must_cache(_, CC1, CC2) ->
    CC1List = term_to_cache_control_list(CC1),
    CC2List = term_to_cache_control_list(CC2),  
    NoCacheSpecifiers = [no_cache, no_store, no_transform],
    lists:any(
        fun(X) -> lists:member(X, NoCacheSpecifiers) end,
        CC1List ++ CC2List
    ).

%% @doc Convert cache control specifier(s) to a normalized list.
term_to_cache_control_list({error, not_found}) -> [];
term_to_cache_control_list({ok, CC}) -> term_to_cache_control_list(CC);
term_to_cache_control_list(X) when is_list(X) ->
    lists:flatten(lists:map(fun term_to_cache_control_list/1, X));
term_to_cache_control_list(X) when is_binary(X) -> X;
term_to_cache_control_list(X) ->
    hb_path:term_to_path(X).

%% @doc Shortcut for resolving a key in a message without its status if it is
%% `ok`. This makes it easier to write complex logic on top of messages while
%% maintaining a functional style.
%% 
%% Additionally, this function supports the `{as, Device, Msg}` syntax, which
%% allows the key to be resolved using another device to resolve the key,
%% while maintaining the tracability of the `HashPath` of the output message.
%% 
%% Returns the value of the key if it is found, otherwise returns the default
%% provided by the user, or `not_found` if no default is provided.
get(Path, Msg) ->
    get(Path, Msg, default_runtime_opts(Msg)).
get(Path, Msg, Opts) ->
    get(Path, Msg, not_found, Opts).
get(Path, {as, Device, Msg}, Default, Opts) ->
    get(Path, set(Msg, #{ device => Device }), Default, Opts);
get(Path, Msg, Default, Opts) ->
	%?event({getting_key, {path, Path}, {msg, Msg}, {opts, Opts}}),
	case resolve(Msg, #{ path => Path }, Opts) of
		{ok, Value} -> Value;
		{error, _} -> Default
	end.

%% @doc Shortcut to get the list of keys from a message.
keys(Msg) -> keys(Msg, #{}).
keys(Msg, Opts) -> keys(Msg, Opts, keep).
keys(Msg, Opts, keep) ->
    get(keys, Msg, Opts);
keys(Msg, Opts, remove) ->
    lists:filter(
        fun(Key) -> not lists:member(Key, ?CONVERGE_KEYS) end,
        keys(Msg, Opts, keep)
    ).

%% @doc Shortcut for setting a key in the message using its underlying device.
%% Like the `get/3' function, this function honors the `error_strategy' option.
%% `set' works with maps and recursive paths while maintaining the appropriate
%% `HashPath' for each step.
set(Msg1, Msg2) ->
    set(Msg1, Msg2, #{}).
set(Msg1, RawMsg2, Opts) when is_map(RawMsg2) ->
    Msg2 = maps:without([hashpath], RawMsg2),
    ?event({set_called, {msg1, Msg1}, {msg2, Msg2}}),
    case map_size(Msg2) of
        0 -> Msg1;
        _ ->
            % First, get the first key and value to set.
            Key = hd(keys(Msg2, Opts#{ hashpath => ignore })),
            Val = get(Key, Msg2, Opts),
            ?event({got_val_to_set, {key, Key}, {val, Val}}),
            % Then, set the key and recurse, removing the key from the Msg2.
            set(
                set(Msg1, Key, Val, Opts),
                remove(Msg2, Key, Opts),
                Opts
            )
    end.
set(Msg1, Key, Value, Opts) ->
    % For an individual key, we run deep_set with the key as the path.
    % This handles both the case that the key is a path as well as the case
    % that it is a single key.
    Path = hb_path:term_to_path(Key),
    % ?event(
    %     {setting_individual_key,
    %         {msg1, Msg1},
    %         {key, Key},
    %         {path, Path},
    %         {value, Value}
    %     }
    % ),
    deep_set(Msg1, Path, Value, Opts).

%% @doc Recursively search a map, resolving keys, and set the value of the key
%% at the given path.
deep_set(Msg, [Key], Value, Opts) ->
    %?event({setting_last_key, {key, Key}, {value, Value}}),
    device_set(Msg, Key, Value, Opts);
deep_set(Msg, [Key|Rest], Value, Opts) ->
    {ok, SubMsg} = resolve(Msg, Key, Opts),
    ?event({traversing_deeper_to_set, {current_key, Key}, {current_value, SubMsg}, {rest, Rest}}),
    device_set(Msg, Key, deep_set(SubMsg, Rest, Value, Opts), Opts).

device_set(Msg, Key, Value, Opts) ->
	?event({calling_device_set, {msg, Msg}, {applying_path, #{ path => set, Key => Value }}}),
	Res = hb_util:ok(resolve(Msg, #{ path => set, Key => Value }, Opts), Opts),
	?event({device_set_result, Res}),
	Res.

%% @doc Remove a key from a message, using its underlying device.
remove(Msg, Key) -> remove(Msg, Key, #{}).
remove(Msg, Key, Opts) ->
	hb_util:ok(resolve(Msg, #{ path => remove, item => Key }, Opts), Opts).

%% @doc Handle an error in a device call.
handle_error(Whence, {Class, Exception, Stacktrace}, Opts) ->
    case maps:get(error_strategy, Opts, throw) of
        throw -> erlang:raise(Class, Exception, Stacktrace);
        _ -> {error, Whence, {Class, Exception, Stacktrace}}
    end.

%% @doc Truncate the arguments of a function to the number of arguments it
%% actually takes.
truncate_args(Fun, Args) ->
    {arity, Arity} = erlang:fun_info(Fun, arity),
    lists:sublist(Args, Arity).

%% @doc Calculate the Erlang function that should be called to get a value for
%% a given key from a device.
%%
%% This comes in 7 forms:
%% 1. The message does not specify a device, so we use the default device.
%% 2. The device has a `handler' key in its `Dev:info()' map, which is a
%% function that takes a key and returns a function to handle that key. We pass
%% the key as an additional argument to this function.
%% 3. The device has a function of the name `Key', which should be called
%% directly.
%% 4. The device does not implement the key, but does have a default handler
%% for us to call. We pass it the key as an additional argument.
%% 5. The device does not implement the key, and has no default handler. We use
%% the default device to handle the key.
%% Error: If the device is specified, but not loadable, we raise an error.
%%
%% Returns {ok | add_key, Fun} where Fun is the function to call, and add_key
%% indicates that the key should be added to the start of the call's arguments.
message_to_fun(Msg, Key, Opts) ->
	DevID =
		case dev_message:get(device, Msg, Opts) of
			{error, not_found} ->
				% The message does not specify a device, so we use the 
				% default device.
				default_module();
			{ok, DevVal} -> DevVal
		end,
	Dev =
		case load_device(DevID, Opts) of
			{error, _} ->
				% Error case: A device is specified, but it is not loadable.
				throw({error, {device_not_loadable, DevID}});
			{ok, DevMod} -> DevMod
		end,
	%?event({message_to_fun, {dev, Dev}, {key, Key}, {opts, Opts}}),
	case maps:find(handler, Info = info(Dev, Msg, Opts)) of
		{ok, Handler} ->
			% Case 2: The device has an explicit handler function.
			?event({info_handler_found, {dev, Dev}, {key, Key}, {handler, Handler}}),
			{Status, Func} = info_handler_to_fun(Handler, Msg, Key, Opts),
            {Status, Dev, Func};
		error ->
			%?event({info_handler_not_found, {dev, Dev}, {key, Key}}),
			case find_exported_function(Dev, Key, 3, Opts) of
				{ok, Func} ->
					% Case 3: The device has a function of the name `Key`.
					{ok, Dev, Func};
				not_found ->
					case maps:find(default, Info) of
						{ok, DefaultFunc} when is_function(DefaultFunc) ->
							% Case 4: The device has a default handler.
                            %?event({default_handler_func, DefaultFunc}),
							{add_key, Dev, DefaultFunc};
                        {ok, DefaultMod} when is_atom(DefaultMod) ->
                            % ?event(
                            %     {
                            %         default_handler_mod,
                            %         {dev, DefaultMod},
                            %         {key, Key}
                            %     }
                            % ),
                            {Status, Func} =
                                message_to_fun(
                                    Msg#{ device => DefaultMod }, Key, Opts
                                ),
                            {Status, Dev, Func};
						error ->
							% Case 5: The device has no default handler.
							% We use the default device to handle the key.
							case default_module() of
								Dev ->
									% We are already using the default device,
									% so we cannot resolve the key. This should
									% never actually happen in practice, but it
									% resolves an infinite loop that can occur
									% during development.
									throw({
										error,
										default_device_could_not_resolve_key,
										{key, Key}
									});
								DefaultDev ->
                                    message_to_fun(
                                        Msg#{ device => DefaultDev },
                                        Key,
                                        Opts
                                    )
							end
					end
			end
	end.

%% @doc Parse a handler key given by a device's `info'.
info_handler_to_fun(Handler, _Msg, _Key, _Opts) when is_function(Handler) ->
	{add_key, Handler};
info_handler_to_fun(HandlerMap, Msg, Key, Opts) ->
	case maps:find(exclude, HandlerMap) of
		{ok, Exclude} ->
			case lists:member(Key, Exclude) of
				true ->
					{ok, MsgWithoutDevice} =
						dev_message:remove(Msg, #{ item => device }),
					message_to_fun(
						MsgWithoutDevice#{ device => default_module() },
						Key,
						Opts
					);
				false -> {add_key, maps:get(func, HandlerMap)}
			end;
		error -> {add_key, maps:get(func, HandlerMap)}
	end.

%% @doc Find the function with the highest arity that has the given name, if it
%% exists.
%%
%% If the device is a module, we look for a function with the given name.
%%
%% If the device is a map, we look for a key in the map. First we try to find
%% the key using its literal value. If that fails, we cast the key to an atom
%% and try again.
find_exported_function(Dev, Key, MaxArity, Opts) when is_map(Dev) ->
	case maps:get(Key, Dev, not_found) of
		not_found ->
			case to_key(Key) of
				undefined -> not_found;
				Key ->
					% The key is unchanged, so we return not_found.
					not_found;
				KeyAtom ->
					% The key was cast to an atom, so we try again.
					find_exported_function(Dev, KeyAtom, MaxArity, Opts)
			end;
		Fun when is_function(Fun) ->
			case erlang:fun_info(Fun, arity) of
				{arity, Arity} when Arity =< MaxArity ->
					case is_exported(Dev, Key, Opts) of
						true -> {ok, Fun};
						false -> not_found
					end;
				_ -> not_found
			end
	end;
find_exported_function(_Mod, _Key, Arity, _Opts) when Arity < 0 -> not_found;
find_exported_function(Mod, Key, Arity, Opts) when not is_atom(Key) ->
	case to_key(Key, Opts) of
		ConvertedKey when is_atom(ConvertedKey) ->
			find_exported_function(Mod, ConvertedKey, Arity, Opts);
		undefined -> not_found;
		BinaryKey when is_binary(BinaryKey) ->
			not_found
	end;
find_exported_function(Mod, Key, Arity, Opts) ->
	%?event({finding, {mod, Mod}, {key, Key}, {arity, Arity}}),
	case erlang:function_exported(Mod, Key, Arity) of
		true ->
			case is_exported(Mod, Key, Opts) of
				true ->
					%?event({found, {ok, fun Mod:Key/Arity}}),
					{ok, fun Mod:Key/Arity};
				false ->
					%?event({result, not_found}),
					not_found
			end;
		false ->
			%?event(
            %     {
            %         find_exported_function_result,
            %         {mod, Mod},
            %         {key, Key},
            %         {arity, Arity},
            %         {result, false}
            %     }
            % ),
			find_exported_function(Mod, Key, Arity - 1, Opts)
	end.

%% @doc Check if a device is guarding a key via its `exports' list. Defaults to
%% true if the device does not specify an `exports' list. The `info' function is
%% always exported, if it exists.
is_exported(_, info, _Opts) -> true;
is_exported(Dev, Key, Opts) ->
	case info(Dev, Key, Opts) of
		#{ exports := Exports } ->
			lists:member(Key, Exports);
		_ -> true
	end.

%% @doc Convert a key to an atom if it already exists in the Erlang atom table,
%% or to a binary otherwise.
to_key(Key) -> to_key(Key, #{ error_strategy => throw }).
to_key(Key, _Opts) when byte_size(Key) == 43 -> Key;
to_key(Key, Opts) ->
	try to_atom_unsafe(Key)
	catch _Type:_:_Trace -> key_to_binary(Key, Opts)
	end.

%% @doc Convert a key to its binary representation.
key_to_binary(Key) -> key_to_binary(Key, #{}).
key_to_binary(Key, _Opts) when is_binary(Key) -> Key;
key_to_binary(Key, _Opts) when is_atom(Key) -> atom_to_binary(Key);
key_to_binary(Key, _Opts) when is_list(Key) -> list_to_binary(Key);
key_to_binary(Key, _Opts) when is_integer(Key) -> integer_to_binary(Key).

%% @doc Helper function for key_to_atom that does not check for errors.
to_atom_unsafe(Key) when is_integer(Key) ->
    integer_to_binary(Key);
to_atom_unsafe(Key) when is_binary(Key) ->
    binary_to_existing_atom(hb_util:to_lower(Key), utf8);
to_atom_unsafe(Key) when is_list(Key) ->
    FlattenedKey = lists:flatten(Key),
    list_to_existing_atom(FlattenedKey);
to_atom_unsafe(Key) when is_atom(Key) -> Key.

%% @doc Load a device module from its name or a message ID.
%% Returns {ok, Executable} where Executable is the device module. On error,
%% a tuple of the form {error, Reason} is returned.
load_device(Map, _Opts) when is_map(Map) -> {ok, Map};
load_device(ID, _Opts) when is_atom(ID) ->
    try ID:module_info(), {ok, ID}
    catch _:_ -> {error, not_loadable}
    end;
load_device(ID, Opts) when is_binary(ID) and byte_size(ID) == 43 ->
	case hb_opts:get(load_remote_devices) of
		true ->
			{ok, Msg} = hb_cache:read(maps:get(store, Opts), ID),
			Trusted =
				lists:any(
					fun(Signer) ->
						lists:member(Signer, hb_opts:get(trusted_device_signers))
					end,
					hb_message:signers(Msg)
				),
			case Trusted of
				true ->
					RelBin = erlang:system_info(otp_release),
					case lists:keyfind(<<"Content-Type">>, 1, Msg#tx.tags) of
						<<"BEAM/", RelBin/bitstring>> ->
							{_, ModNameBin} =
								lists:keyfind(
                                    <<"Module-Name">>,
                                    1,
                                    Msg#tx.tags
                                ),
							ModName = list_to_atom(binary_to_list(ModNameBin)),
							case erlang:load_module(ModName, Msg#tx.data) of
								{module, _} -> {ok, ModName};
								{error, Reason} -> {error, Reason}
							end
					end;
				false -> {error, device_signer_not_trusted}
			end;
		false ->
			{error, remote_devices_disabled}
	end;
load_device(ID, Opts) ->
    case maps:get(ID, hb_opts:get(preloaded_devices), unsupported) of
        unsupported -> {error, module_not_admissable};
        Mod -> load_device(Mod, Opts)
    end.

%% @doc Get the info map for a device, optionally giving it a message if the
%% device's info function is parameterized by one.
info(DevMod, Msg, Opts) ->
	%?event({calculating_info, {dev, DevMod}, {msg, Msg}}),
	case find_exported_function(DevMod, info, 1, Opts) of
		{ok, Fun} ->
			Res = apply(Fun, truncate_args(Fun, [Msg, Opts])),
			% ?event({
            %     info_result,
            %     {dev, DevMod},
            %     {args, truncate_args(Fun, [Msg])},
            %     {result, Res}
            % }),
			Res;
		not_found -> #{}
	end.

%% @doc The default runtime options for a message. At the moment the `Message1'
%% but it is included such that we can modulate the options based on the message
%% if needed in the future.
default_runtime_opts(_Msg1) ->
    #{
        error_strategy => throw
    }.

%% @doc The default device is the identity device, which simply returns the
%% value associated with any key as it exists in its Erlang map. It should also
%% implement the `set' key, which returns a `Message3' with the values changed
%% according to the `Message2' passed to it.
default_module() -> dev_message.

%%% Tests

resolve_simple_test() ->
    pg:start(pg),
    ?assertEqual({ok, 1}, hb_converge:resolve(#{ a => 1 }, a, #{})).

resolve_from_multiple_keys_test() ->
    ?assertEqual(
        {ok, [a]},
        hb_converge:resolve(#{ a => 1, "priv_a" => 2 }, keys, #{})
    ).

resolve_path_element_test() ->
    ?assertEqual(
        {ok, [test_path]},
        hb_converge:resolve(#{ path => [test_path] }, path, #{})
    ),
    ?assertEqual(
        {ok, [a]},
        hb_converge:resolve(#{ <<"Path">> => [a] }, <<"Path">>, #{})
    ).

key_to_binary_test() ->
    ?assertEqual(<<"a">>, hb_converge:key_to_binary(a)),
    ?assertEqual(<<"a">>, hb_converge:key_to_binary(<<"a">>)),
    ?assertEqual(<<"a">>, hb_converge:key_to_binary("a")).

resolve_binary_key_test() ->
    ?assertEqual(
        {ok, 1},
        hb_converge:resolve(#{ a => 1 }, <<"a">>, #{})
    ),
    ?assertEqual(
        {ok, 1},
        hb_converge:resolve(
            #{
                <<"Test-Header">> => 1 },
                <<"Test-Header">>,
            #{}
        )
    ).

%% @doc Generates a test device with three keys, each of which uses
%% progressively more of the arguments that can be passed to a device key.
generate_device_with_keys_using_args() ->
    #{
        key_using_only_state =>
            fun(State) ->
                {ok,
                    <<(maps:get(state_key, State))/binary>>
                }
            end,
        key_using_state_and_msg =>
            fun(State, Msg) ->
                {ok,
                    <<
                        (maps:get(state_key, State))/binary,
                        (maps:get(msg_key, Msg))/binary
                    >>
                }
            end,
        key_using_all =>
            fun(State, Msg, Opts) ->
                {ok,
                    <<
                        (maps:get(state_key, State))/binary,
                        (maps:get(msg_key, Msg))/binary,
                        (maps:get(opts_key, Opts))/binary
                    >>
                }
            end
    }.

%% @doc Create a simple test device that implements the default handler.
gen_default_device() ->
    #{
        info =>
            fun() ->
                #{
                    default =>
                        fun(_, _State) ->
                            {ok, <<"DEFAULT">>}
                        end
                }
            end,
        state_key =>
            fun(_) ->
                {ok, <<"STATE">>}
            end
    }.

%% @doc Create a simple test device that implements the handler key.
gen_handler_device() ->
    #{
        info =>
            fun() ->
                #{
                    handler =>
                        fun(set, M1, M2, Opts) ->
                            dev_message:set(M1, M2, Opts);
                        (_, _, _, _) ->
                            {ok, <<"HANDLER VALUE">>}
                        end
                }
            end
    }.

%% @doc Test that arguments are passed to a device key as expected.
%% Particularly, we need to ensure that the key function in the device can
%% specify any arity (1 through 3) and the call is handled correctly.
key_from_id_device_with_args_test() ->
    Msg =
        #{
            device => generate_device_with_keys_using_args(),
            state_key => <<"1">>
        },
    ?assertEqual(
        {ok, <<"1">>},
        hb_converge:resolve(
            Msg,
            #{
                path => key_using_only_state,
                msg_key => <<"2">> % Param message, which is ignored
            },
            #{}
        )
    ),
    ?assertEqual(
        {ok, <<"13">>},
        hb_converge:resolve(
            Msg,
            #{
                path => key_using_state_and_msg,
                msg_key => <<"3">> % Param message, with value to add
            },
            #{}
        )
    ),
    ?assertEqual(
        {ok, <<"1337">>},
        hb_converge:resolve(
            Msg,
            #{
                path => key_using_all,
                msg_key => <<"3">> % Param message
            },
            #{
                opts_key => <<"37">> % Opts
            }
        )
    ).

device_with_handler_function_test() ->
    Msg =
        #{
            device => gen_handler_device(),
            test_key => <<"BAD">>
        },
    ?assertEqual(
        {ok, <<"HANDLER VALUE">>},
        hb_converge:resolve(Msg, test_key, #{})
    ).

device_with_default_handler_function_test() ->
    Msg =
        #{
            device => gen_default_device()
        },
    ?assertEqual(
        {ok, <<"STATE">>},
        hb_converge:resolve(Msg, state_key, #{})
    ),
    ?assertEqual(
        {ok, <<"DEFAULT">>},
        hb_converge:resolve(Msg, any_random_key, #{})
    ).

basic_get_test() ->
    Msg = #{ key1 => <<"value1">>, key2 => <<"value2">> },
    ?assertEqual(<<"value1">>, hb_converge:get(key1, Msg)),
    ?assertEqual(<<"value2">>, hb_converge:get(key2, Msg)).

basic_set_test() ->
    Msg = #{ key1 => <<"value1">>, key2 => <<"value2">> },
    UpdatedMsg = hb_converge:set(Msg, #{ key1 => <<"new_value1">> }),
    ?event({set_key_complete, {key, key1}, {value, <<"new_value1">>}}),
    ?assertEqual(<<"new_value1">>, hb_converge:get(key1, UpdatedMsg)),
    ?assertEqual(<<"value2">>, hb_converge:get(key2, UpdatedMsg)).

get_with_device_test() ->
    Msg =
        #{
            device => generate_device_with_keys_using_args(),
            state_key => <<"STATE">>
        },
    ?assertEqual(<<"STATE">>, hb_converge:get(state_key, Msg)),
    ?assertEqual(<<"STATE">>, hb_converge:get(key_using_only_state, Msg)).

get_as_with_device_test() ->
    Msg =
        #{
            device => gen_handler_device(),
            test_key => <<"ACTUAL VALUE">>
        },
    ?assertEqual(
        <<"HANDLER VALUE">>,
        hb_converge:get(test_key, Msg)
    ),
    ?assertEqual(
        <<"ACTUAL VALUE">>,
        hb_converge:get(test_key, {as, dev_message, Msg})
    ).

set_with_device_test() ->
    Msg =
        #{
            device =>
                #{
                    set =>
                        fun(State, _Msg) ->
                            {ok,
                                State#{
                                    set_count =>
                                        1 + maps:get(set_count, State, 0)
                                }
                            }
                        end
                },
            state_key => <<"STATE">>
        },
    ?assertEqual(<<"STATE">>, hb_converge:get(state_key, Msg)),
    SetOnce = hb_converge:set(Msg, #{ state_key => <<"SET_ONCE">> }),
    ?assertEqual(1, hb_converge:get(set_count, SetOnce)),
    SetTwice = hb_converge:set(SetOnce, #{ state_key => <<"SET_TWICE">> }),
    ?assertEqual(2, hb_converge:get(set_count, SetTwice)),
    ?assertEqual(<<"STATE">>, hb_converge:get(state_key, SetTwice)).

deep_set_test() ->
    % First validate second layer changes are handled correctly.
    Msg0 = #{ a => #{ b => 1 } },
    ?assertMatch(#{ a := #{ b := 2 } },
        hb_converge:set(Msg0, [a, b], 2, #{})),
    % Now validate deeper layer changes are handled correctly.
    Msg = #{ a => #{ b => #{ c => 1 } } },
    ?assertMatch(#{ a := #{ b := #{ c := 2 } } },
        hb_converge:set(Msg, [a, b, c], 2, #{})).

deep_set_with_device_test() ->
    Device = #{
        set =>
            fun(Msg1, Msg2) ->
                % A device where the set function modifies the key
                % and adds a modified flag.
                {Key, Val} = hd(maps:to_list(maps:remove(path, Msg2))),
                {ok, Msg1#{ Key => Val, modified => true }}
            end
    },
    % A message with an interspersed custom device: A and C have it,
    % B does not. A and C will have the modified flag set to true.
    Msg = #{
        device => Device,
        a =>
            #{
                b =>
                    #{
                        device => Device,
                        c => 1,
                        modified => false
                    },
                modified => false
            },
        modified => false
    },
    Outer = deep_set(Msg, [a, b, c], 2, #{}),
    A = hb_converge:get(a, Outer),
    B = hb_converge:get(b, A),
    C = hb_converge:get(c, B),
    ?assertEqual(2, C),
    ?assertEqual(true, hb_converge:get(modified, Outer)),
    ?assertEqual(false, hb_converge:get(modified, A)),
    ?assertEqual(true, hb_converge:get(modified, B)).

device_exports_test() ->
	?assert(is_exported(dev_message, info, #{})),
	?assert(is_exported(dev_message, set, #{})),
	?assert(not is_exported(dev_message, not_exported, #{})),
	Dev = #{
		info => fun() -> #{ exports => [set] } end,
		set => fun(_, _) -> {ok, <<"SET">>} end
	},
	?assert(is_exported(Dev, info, #{})),
	?assert(is_exported(Dev, set, #{})),
	?assert(not is_exported(Dev, not_exported, #{})).

denormalized_device_key_test() ->
	Msg = #{ <<"Device">> => dev_test },
	?assertEqual(dev_test, hb_converge:get(device, Msg)),
	?assertEqual(dev_test, hb_converge:get(<<"Device">>, Msg)),
	?assertEqual({module, dev_test},
		erlang:fun_info(
            element(3, message_to_fun(Msg, test_func, #{})),
            module
        )
    ).
