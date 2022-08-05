%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(emqx_auth_mongo).

-behaviour(ecpool_worker).

-include("emqx_auth_mongo.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/types.hrl").

-export([ check/3
        , description/0
        ]).

-export([ replvar/2
        , replvars/2
        , connect/1
        , query/3
        , query_multi/3
        ]).

-export([ available/2
        , available/3
        ]).

check(ClientInfo = #{password := Password}, AuthResult,
      Env = #{authquery := AuthQuery, superquery := SuperQuery}) ->
    #authquery{collection = Collection, field = Fields,
               hash = HashType, selector = Selector} = AuthQuery,
    Pool = maps:get(pool, Env, ?APP),
    case query(Pool, Collection, maps:from_list(replvars(Selector, ClientInfo))) of
        undefined -> ok;
        {error, Reason} ->
            ?LOG(error, "[MongoDB] Can't connect to MongoDB server: ~0p", [Reason]),
            {stop, AuthResult#{auth_result => not_authorized, anonymous => false}};
        UserMap ->
            Result = case [maps:get(Field, UserMap, undefined) || Field <- Fields] of
                        [undefined] -> {error, password_error};
                        [PassHash] ->
                            check_pass({PassHash, Password}, HashType);
                        [PassHash, Salt|_] ->
                            check_pass({PassHash, Salt, Password}, HashType)
                     end,
            case Result of
                ok ->
                    {stop, AuthResult#{is_superuser => is_superuser(Pool, SuperQuery, ClientInfo),
                                       anonymous => false,
                                       auth_result => success}};
                {error, Error} ->
                    ?LOG(error, "[MongoDB] check auth fail: ~p", [Error]),
                    {stop, AuthResult#{auth_result => Error, anonymous => false}}
            end
    end.

check_pass(Password, HashType) ->
    case emqx_passwd:check_pass(Password, HashType) of
        ok -> ok;
        {error, _Reason} -> {error, not_authorized}
    end.

description() -> "Authentication with MongoDB".

%%--------------------------------------------------------------------
%% Is Superuser?
%%--------------------------------------------------------------------
is_superuser(_Pool, undefined, _ClientInfo) ->
    false;
is_superuser(Pool, #superquery{collection = Coll, field = Field, selector = Selector}, ClientInfo) ->
    case query(Pool, Coll, maps:from_list(replvars(Selector, ClientInfo))) of
        undefined -> false;
        {error, Reason} ->
            ?LOG(error, "[MongoDB] Can't connect to MongoDB server: ~0p", [Reason]),
            false;
        Row ->
            case maps:get(Field, Row, false) of
                true   -> true;
                _False -> false
            end
    end.

%%--------------------------------------------------------------------
%% Availability Test
%%--------------------------------------------------------------------

available(Pool, #superquery{collection = Collection, selector = Selector}) ->
    available(Pool, Collection, maps:from_list(replvars(Selector, test_client_info())));
available(Pool, #authquery{collection = Collection, selector = Selector}) ->
    available(Pool, Collection, maps:from_list(replvars(Selector, test_client_info())));
available(Pool, #aclquery{collection = Collection, selector = Selectors}) ->
    Fun =
        fun(Selector) ->
            maps:from_list(emqx_auth_mongo:replvars(Selector, test_client_info()))
        end,
    available(Pool, Collection, lists:map(Fun, Selectors), fun query_multi/3).

available(Pool, Collection, Query) ->
    available(Pool, Collection, Query, fun query/3).

available(Pool, Collection, Query, Fun) ->
    try Fun(Pool, Collection, Query) of
        {error, Reason} ->
            ?LOG(error, "[MongoDB] ~p availability test error: ~0p", [Collection, Reason]),
            {error, Reason};
        Error = #{<<"code">> := Code} ->
            CodeName = maps:get(<<"codeName">>, Error, undefined),
            ErrorMessage = maps:get(<<"errmsg">>, Error, undefined),
            ?LOG(error, "[MongoDB] ~p availability test error, code: ~p Name: ~0p Message: ~0p",
                [Collection, Code, CodeName, ErrorMessage]),
            {error, {mongo_error, Code}};
        _Return ->
            %% Any success result is fine.
            ok
    catch E:R:S ->
        ?LOG(error, "[MongoDB] ~p availability test error, ~p: ~0p: ~0p", [Collection, E, R, S]),
        {error, R}
    end.

%% Test client info
test_client_info() ->
    #{
        clientid => <<"EMQX_availability_test_client">>,
        username => <<"EMQX_availability_test_username">>,
        cn => <<"EMQX_availability_test_cn">>,
        dn => <<"EMQX_availability_test_dn">>
    }.

%%--------------------------------------------------------------------
%% Internal func
%%--------------------------------------------------------------------

replvars(VarList, ClientInfo) ->
    lists:map(fun(Var) -> replvar(Var, ClientInfo) end, VarList).

replvar({Field, <<"%u">>}, #{username := Username}) ->
    {Field, Username};
replvar({Field, <<"%c">>}, #{clientid := ClientId}) ->
    {Field, ClientId};
replvar({Field, <<"%C">>}, #{cn := CN}) ->
    {Field, CN};
replvar({Field, <<"%d">>}, #{dn := DN}) ->
    {Field, DN};
replvar(Selector, _ClientInfo) ->
    Selector.

%%--------------------------------------------------------------------
%% MongoDB Connect/Query
%%--------------------------------------------------------------------

connect(Opts) ->
    Type = proplists:get_value(type, Opts, single),
    Hosts = proplists:get_value(hosts, Opts, []),
    Options = proplists:get_value(options, Opts, []),
    WorkerOptions = proplists:get_value(worker_options, Opts, []),
    mongo_api:connect(Type, Hosts, Options, WorkerOptions).

query(Pool, Collection, Selector) ->
    ecpool:with_client(Pool, fun(Conn) -> mongo_api:find_one(Conn, Collection, Selector, #{}) end).

query_multi(Pool, Collection, SelectorList) ->
    lists:reverse(lists:flatten(lists:foldl(fun(Selector, Acc1) ->
        Batch = ecpool:with_client(Pool, fun(Conn) ->
                  case mongo_api:find(Conn, Collection, Selector, #{}) of
                      {error, Reason} ->
                          ?LOG(error, "[MongoDB] query_multi failed, got error: ~p", [Reason]),
                          [];
                      [] -> [];
                      {ok, Cursor} ->
                          mc_cursor:foldl(fun(O, Acc2) -> [O|Acc2] end, [], Cursor, 1000)
                  end
                end),
        [Batch|Acc1]
    end, [], SelectorList))).