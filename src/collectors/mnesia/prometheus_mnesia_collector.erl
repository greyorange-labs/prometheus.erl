%% @doc
%% Collects Mnesia metrics mainly using
%% <a href="http://erlang.org/doc/man/mnesia.html#system_info-1">
%%   mnesia:system_info/1
%% </a>.
%%
%% ==Exported metrics==
%% <ul>
%%   <li>
%%     `erlang_mnesia_held_locks'<br/>
%%     Type: gauge.<br/>
%%     Number of held locks.
%%   </li>
%%   <li>
%%     `erlang_mnesia_lock_queue'<br/>
%%     Type: gauge.<br/>
%%     Number of transactions waiting for a lock.
%%   </li>
%%   <li>
%%     `erlang_mnesia_transaction_participants'<br/>
%%     Type: gauge.<br/>
%%     Number of participant transactions.
%%   </li>
%%   <li>
%%     `erlang_mnesia_transaction_coordinators'<br/>
%%     Type: gauge.<br/>
%%     Number of coordinator transactions.
%%   </li>
%%   <li>
%%     `erlang_mnesia_failed_transactions'<br/>
%%     Type: counter.<br/>
%%     Number of failed (i.e. aborted) transactions.
%%   </li>
%%   <li>
%%     `erlang_mnesia_committed_transactions'<br/>
%%     Type: gauge.<br/>
%%     Number of committed transactions.
%%   </li>
%%   <li>
%%     `erlang_mnesia_logged_transactions'<br/>
%%     Type: counter.<br/>
%%     Number of transactions logged.
%%   </li>
%%   <li>
%%     `erlang_mnesia_restarted_transactions'<br/>
%%     Type: counter.<br/>
%%     Total number of transaction restarts.
%%   </li>
%%   <li>
%%     `erlang_mnesia_memory_usage_bytes'<br/>
%%     Type: gauge.<br/>
%%     Total number of bytes allocated by all mnesia tables.
%%   </li>
%% </ul>
%%
%% ==Configuration==
%%
%% Metrics exported by this collector can be configured via
%% `mnesia_collector_metrics' key of `prometheus' app environment.
%%
%% Available options:
%% - `held_locks' for `erlang_mnesia_held_locks';
%% - `lock_queue' for `erlang_mnesia_lock_queue';
%% - `transaction_participants' for `erlang_mnesia_transaction_participants';
%% - `transaction_coordinators' for `erlang_mnesia_transaction_coordinators';
%% - `transaction_failures' for `erlang_mnesia_failed_transactions';
%% - `transaction_commits' for `erlang_mnesia_committed_transactions';
%% - `transaction_log_writes' for `erlang_mnesia_logged_transactions';
%% - `transaction_restarts' for `erlang_mnesia_restarted_transactions';
%% - `memory_usage_bytes' for `erlang_mnesia_memory_usage_bytes'.
%%
%% By default all metrics are enabled.
%%
%% @end

-module(prometheus_mnesia_collector).

-export([deregister_cleanup/1,
         collect_mf/2]).

-import(prometheus_model_helpers, [create_mf/4]).

-include("prometheus.hrl").

-behaviour(prometheus_collector).

%%====================================================================
%% Macros
%%====================================================================

-define(METRIC_NAME_PREFIX, "erlang_mnesia_").

%%====================================================================
%% Collector API
%%====================================================================

%% @private
deregister_cleanup(_) -> ok.

%% @private
-spec collect_mf(_Registry, Callback) -> ok when
    _Registry :: prometheus_registry:registry(),
    Callback :: prometheus_collector:callback().
collect_mf(_Registry, Callback) ->
  case mnesia_running() of
    true ->
      EnabledMetrics = enabled_metrics(),
      Metrics = metrics(EnabledMetrics),
      prometheus_counter:declare([{name, held_locks_dist},
                            {help, "Held Locks Tablewise Activity Distribution."},
                            {labels, [lock_entity, target, type]}
                            ]),
      prometheus_counter:declare([{name, lock_queue_dist},
                            {help, "Lock Queue Tablewise Activity Distribution."},
                            {labels, [table, type]}
                            ]),
      [add_metric_family(Metric, Callback)
       || {Name, _, _, _}=Metric <- Metrics, metric_enabled(Name, EnabledMetrics)];
    false -> ok
  end,
  ok.

add_metric_family({Name, Type, Help, Metrics}, Callback) ->
  Callback(create_mf(?METRIC_NAME(Name), Help, Type, catch_all(Metrics))).

%%====================================================================
%% Private Parts
%%====================================================================

metrics(EnabledMetrics) ->
  {Participants, Coordinators} = get_tm_info(EnabledMetrics),
  MemoryUsage = get_memory_usage(),
  TablewiseMemoryUsage = get_tablewise_memory_usage(),
  TablewiseSize = get_tablewise_size(),

  HeldLocks = mnesia:system_info(held_locks),
  lists:foreach(
    fun({{LockEntity, Target}, Type, _}) ->
      Target1 =
        case Target of
          '______WHOLETABLE_____' -> whole_table;
          _ -> single
        end,
        prometheus_counter:inc(held_locks_dist, [LockEntity, Target1, Type])
    end,
  HeldLocks),
  LockQueue = mnesia:system_info(lock_queue),
  lists:foreach(
    fun({{Table, _Key}, Type, _Pid, _, _}) ->
      prometheus_counter:inc(lock_queue_dist, [Table, Type])
    end,
  LockQueue),

  [{held_locks, gauge,
    "Number of held locks.",
    fun() -> length(HeldLocks) end},
   {lock_queue, gauge,
    "Number of transactions waiting for a lock.",
    fun() -> length(LockQueue) end},
   {transaction_participants, gauge,
    "Number of participant transactions.",
    fun() -> Participants end},
   {transaction_coordinators, gauge,
    "Number of coordinator transactions.",
    fun() -> Coordinators end},
   {failed_transactions, counter,
    "Number of failed (i.e. aborted) transactions.",
    fun() -> mnesia:system_info(transaction_failures) end},
   {committed_transactions, counter,
    "Number of committed transactions.",
    fun() -> mnesia:system_info(transaction_commits) end},
   {logged_transactions, counter,
    "Number of transactions logged.",
    fun() -> mnesia:system_info(transaction_log_writes) end},
   {restarted_transactions, counter,
    "Total number of transaction restarts.",
    fun() -> mnesia:system_info(transaction_restarts) end},
   {memory_usage_bytes, gauge,
    "Total number of bytes allocated by all mnesia tables",
    fun() -> MemoryUsage end},
   {tablewise_memory_usage_bytes, gauge,
    "Number of bytes allocated per mnesia table",
    fun() -> TablewiseMemoryUsage end},
   {tablewise_size, gauge,
    "Number of rows present per table",
    fun() -> TablewiseSize end}
    ].

%%====================================================================
%% Private Parts
%%====================================================================

get_tm_info(SetMetrics) ->
  case tm_metrics_enabled(SetMetrics) of
    true ->
      prometheus_mnesia:tm_info();
    _ ->
      {undefined, undefined}
  end.

tm_metrics_enabled(SetMetrics) ->
  metric_enabled(transaction_participants, SetMetrics) orelse
    metric_enabled(transaction_coordinators, SetMetrics).

catch_all(DataFun) ->
    try DataFun()
    catch _:_ -> undefined
    end.

mnesia_running() ->
  erlang:function_exported(mnesia, system_info, 1) andalso
    mnesia:system_info(is_running) == yes.

enabled_metrics() ->
  application:get_env(prometheus, mnesia_collector_metrics, all).

metric_enabled(Name, Metrics) ->
  Metrics =:= all orelse lists:member(Name, Metrics).

get_memory_usage() ->
  WordSize = erlang:system_info(wordsize),
  Calculator = fun(Tab, Sum) ->
                 table_info(Tab, memory) + Sum
               end,
  lists:foldl(Calculator, 0, mnesia:system_info(tables)) * WordSize.

get_tablewise_memory_usage() ->
  WordSize = erlang:system_info(wordsize),
  Calculator =
    fun(Tab, Acc) ->
      [{[{table, Tab}], table_info(Tab, memory) * WordSize} | Acc]
    end,
  lists:foldl(Calculator, [], mnesia:system_info(tables)).

get_tablewise_size() ->
  Calculator =
    fun(Tab, Acc) ->
      [{[{table, Tab}], table_info(Tab, size)} | Acc]
    end,
  lists:foldl(Calculator, [], mnesia:system_info(tables)).

%% mnesia:table_info/2 may return 'undefined' when the table should
%% be loaded on the local node but hasn't been loaded yet.
%%
%% https://github.com/erlang/otp/issues/5830
table_info(Tab, Item) ->
    case mnesia:table_info(Tab, Item) of
        undefined -> 0;
        Val -> Val
    end.
