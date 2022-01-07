%%--------------------------------------------------------------------
%% Copyright (c) 2017-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_rpc).

%% Note: please don't forget to add new API functions to
%% `emqx_bpapi_trans:extract_mfa'

-export([ call/4
        , call/5
        , cast/4
        , cast/5
        , multicall/4
        , multicall/5
        ]).

-export_type([ badrpc/0
             , call_result/0
             , cast_result/0
             , multicall_result/0
             ]).

-compile({inline,
          [ rpc_node/1
          , rpc_nodes/1
          ]}).

-define(DefaultClientNum, 1).

-type badrpc() ::  {badrpc, term()} | {badtcp, term()}.

-type call_result() :: term() | badrpc().

-type cast_result() :: true.

-type multicall_result() :: {_Results :: [term()], _BadNodes :: [node()]}.

-spec call(node(), module(), atom(), list()) -> call_result().
call(Node, Mod, Fun, Args) ->
    filter_result(gen_rpc:call(rpc_node(Node), Mod, Fun, Args)).

-spec call(term(), node(), module(), atom(), list()) -> call_result().
call(Key, Node, Mod, Fun, Args) ->
    filter_result(gen_rpc:call(rpc_node({Key, Node}), Mod, Fun, Args)).

-spec multicall([node()], module(), atom(), list()) -> multicall_result().
multicall(Nodes, Mod, Fun, Args) ->
    gen_rpc:multicall(rpc_nodes(Nodes), Mod, Fun, Args).

-spec multicall(term(), [node()], module(), atom(), list()) -> multicall_result().
multicall(Key, Nodes, Mod, Fun, Args) ->
    gen_rpc:multicall(rpc_nodes([{Key, Node} || Node <- Nodes]), Mod, Fun, Args).

-spec cast(node(), module(), atom(), list()) -> cast_result().
cast(Node, Mod, Fun, Args) ->
    gen_rpc:cast(rpc_node(Node), Mod, Fun, Args).

-spec cast(term(), node(), module(), atom(), list()) -> cast_result().
cast(Key, Node, Mod, Fun, Args) ->
    gen_rpc:cast(rpc_node({Key, Node}), Mod, Fun, Args).

rpc_node(Node) when is_atom(Node) ->
    {Node, rand:uniform(max_client_num())};
rpc_node({Key, Node}) when is_atom(Node) ->
    {Node, erlang:phash2(Key, max_client_num()) + 1}.

rpc_nodes(Nodes) ->
    rpc_nodes(Nodes, []).

rpc_nodes([], Acc) ->
    Acc;
rpc_nodes([Node | Nodes], Acc) ->
    rpc_nodes(Nodes, [rpc_node(Node) | Acc]).

filter_result({Error, Reason})
  when Error =:= badrpc; Error =:= badtcp ->
    {badrpc, Reason};
filter_result(Delivery) ->
    Delivery.

max_client_num() ->
    emqx:get_config([rpc, tcp_client_num], ?DefaultClientNum).
