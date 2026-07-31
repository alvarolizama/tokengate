defmodule Tokengate.Metrics.Collector do
  @moduledoc """
  In-memory real-time metrics collector for the dashboard.

  A GenServer (registered as `__MODULE__`) owns a single public, named ETS
  table `:tokengate_metrics` (created with `write_concurrency: true`).
  Postgres `request_logs` remains the durable source of truth; this
  collector keeps low-latency counters for dashboard reads.

  ## Concurrency model

  The GenServer only creates the ETS table in `init/1` and never touches it
  again directly. Every public function (`record_request/1`, `snapshot/0`,
  `reset/0`) runs **in the caller's process** against the public table —
  `record_request/1` uses `:ets.update_counter/4` (atomic), and
  `snapshot/0` / `reset/0` read/replace keys directly. This avoids a
  GenServer bottleneck on the hot path.

  ## Counters

    * `{:requests, :total}`            — total request count
    * `{:requests, :errors}`           — count of requests with status >= 400
    * `{:requests, {:alias, id}}`     — per `model_alias_id`
    * `{:requests, {:provider, id}}`   — per `provider_id`
    * `{:requests, {:agent, type}}`   — per `agent_type`
    * `{:tokens, :prompt}`             — total prompt tokens
    * `{:tokens, :completion}`         — total completion tokens
    * `{:cost_micro, :total}`          — total cost in micro-USD (Decimal → integer)
    * `{:savings_micro, :total}`       — total savings in micro-USD
    * `{:latency_samples}`             — list of the last 200 latency samples (ms)

  Micro-USD: `round(cost_usd * 1_000_000)` so $1.500000 → 1_500_000.
  """

  use GenServer

  alias Phoenix.PubSub

  @table :tokengate_metrics
  @max_latency_samples 200
  @pubsub Tokengate.PubSub
  @topic "metrics:updated"

  ## Public API ---------------------------------------------------------------

  @doc """
  Starts the collector. The GenServer creates the ETS table in `init/1` and
  then sits idle — all reads and writes happen in caller processes.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a single proxied request.

  `attrs` keys:

    * `model_alias_id`  — term (usually binary id)
    * `provider_id`     — term
    * `agent_type`      — string
    * `status`          — integer HTTP status
    * `latency_ms`      — integer
    * `prompt_tokens`    — integer
    * `completion_tokens` — integer
    * `cost_usd`        — `Decimal.t()` — what the upstream charged (the
      single cost dimension since the 2026-07-30 refactor)
    * `streaming`       — boolean (currently unused by counters)

  Runs entirely in the caller's process via atomic ETS updates. After
  recording, broadcasts a cheap `{:metrics_updated, snapshot_lite()}` on
  PubSub topic `"metrics:updated"`; dashboards call `snapshot/0` for the
  full picture.
  """
  @spec record_request(map()) :: :ok
  def record_request(attrs) do
    model_alias_id = Map.get(attrs, :model_alias_id)
    provider_id = Map.get(attrs, :provider_id)
    agent_type = Map.get(attrs, :agent_type)
    status = Map.get(attrs, :status, 0)
    latency_ms = Map.get(attrs, :latency_ms, 0)
    prompt_tokens = Map.get(attrs, :prompt_tokens, 0)
    completion_tokens = Map.get(attrs, :completion_tokens, 0)
    cost_usd = Map.get(attrs, :cost_usd) || Decimal.new(0)

    cost_micro = decimal_to_micro(cost_usd)

    # Counters
    incr({:requests, :total})

    unless is_nil(model_alias_id) do
      incr({:requests, {:alias, model_alias_id}})
    end

    unless is_nil(provider_id) do
      incr({:requests, {:provider, provider_id}})
    end

    unless is_nil(agent_type) do
      incr({:requests, {:agent, agent_type}})
    end

    if status >= 400 do
      incr({:requests, :errors})
    end

    add({:tokens, :prompt}, prompt_tokens)
    add({:tokens, :completion}, completion_tokens)
    add({:cost_micro, :total}, cost_micro)

    # Latency ring (prepend + trim to @max_latency_samples)
    push_latency(latency_ms)

    lite = snapshot_lite()
    PubSub.broadcast(@pubsub, @topic, {:metrics_updated, lite})

    :ok
  end

  @doc """
  Returns the current in-memory snapshot.

  Shape:

      %{
        requests_total: non_neg_integer(),
        errors_total: non_neg_integer(),
        error_rate: float(),
        by_alias: %{id => n},
        by_provider: %{id => n},
        by_agent: %{type => n},
        prompt_tokens: non_neg_integer(),
        completion_tokens: non_neg_integer(),
        cost_usd: Decimal.t(),
        latency: %{count: non_neg_integer(), avg_ms: float(), p95_ms: number()}
      }

  `error_rate` is `0.0` when there are no requests. `cost_usd` is
  reconstructed from the micro-USD integer counter as `Decimal` with 6
  decimal places. `p95_ms` uses the nearest-rank method on the last 200
  samples; when fewer than 20 samples exist the max is returned.
  """
  @spec snapshot() :: map()
  def snapshot do
    requests_total = read_counter({:requests, :total})
    errors_total = read_counter({:requests, :errors})

    by_alias = read_dimension({:requests, {:alias, :_}})
    by_provider = read_dimension({:requests, {:provider, :_}})
    by_agent = read_dimension({:requests, {:agent, :_}})

    prompt_tokens = read_counter({:tokens, :prompt})
    completion_tokens = read_counter({:tokens, :completion})

    cost_micro = read_counter({:cost_micro, :total})

    {count, avg_ms, p95_ms} = latency_stats()

    %{
      requests_total: requests_total,
      errors_total: errors_total,
      error_rate: error_rate(requests_total, errors_total),
      by_alias: by_alias,
      by_provider: by_provider,
      by_agent: by_agent,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      cost_usd: micro_to_decimal(cost_micro),
      latency: %{count: count, avg_ms: avg_ms, p95_ms: p95_ms}
    }
  end

  @doc """
  Returns a lightweight snapshot for PubSub broadcasts (cheap to serialize).

      %{requests_total: n, errors_total: n}
  """
  @spec snapshot_lite() :: map()
  def snapshot_lite do
    %{
      requests_total: read_counter({:requests, :total}),
      errors_total: read_counter({:requests, :errors})
    }
  end

  @doc """
  Resets all counters and latency samples. For tests.
  """
  @spec reset() :: :ok
  def reset do
    # Delete and re-create the table contents. The table itself is owned by
    # the GenServer and named, so we wipe known keys rather than recreating
    # it (which would race with the owner).
    :ets.delete_all_objects(@table)
    # Re-seed the latency_samples key as an empty list.
    :ets.insert(@table, {:latency_samples, []})
    :ok
  end

  ## GenServer callbacks ------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  ## Internals ----------------------------------------------------------------

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true
      ])
    end

    # Seed the latency samples list if absent.
    :ets.insert_new(@table, {:latency_samples, []})
    :ok
  end

  # Increment a counter by 1, initializing to 0 on first write.
  defp incr(key) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  end

  # Add `n` to a counter, initializing to 0 on first write.
  defp add(key, n) when is_integer(n) do
    :ets.update_counter(@table, key, {2, n}, {key, 0})
    :ok
  end

  defp read_counter(key) do
    :ets.lookup_element(@table, key, 2, 0)
  end

  # Reads all counter keys matching the pattern `{:requests, {dim, _}}` and
  # returns a map of `value => count`. Builds the match spec per-dimension
  # because ETS match specs don't support runtime-bound atoms via ^pin.
  defp read_dimension({:requests, {:alias, :_}}) do
    select_dim(:alias)
  end

  defp read_dimension({:requests, {:provider, :_}}) do
    select_dim(:provider)
  end

  defp read_dimension({:requests, {:agent, :_}}) do
    select_dim(:agent)
  end

  defp select_dim(dim) do
    match_spec = [
      {{{:requests, {dim, :"$1"}}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    :ets.select(@table, match_spec)
    |> Map.new()
  end

  # Latency ring: prepend, then trim to @max_latency_samples.
  # Uses :ets.lookup_element with a default to avoid a race when the key is
  # missing; updates are single-writer-per-key via update_element which is
  # atomic for the value field.
  defp push_latency(latency_ms) do
    # Read current list, prepend, trim, write back. This is not lock-free
    # across concurrent writers, but latency samples are an approximation
    # (dashboard p95) and occasional lost prepends are acceptable. The
    # alternative — routing every request through the GenServer — would
    # serialize all proxy responses on a single process.
    current =
      try do
        :ets.lookup_element(@table, :latency_samples, 2)
      rescue
        ArgumentError -> []
      else
        list when is_list(list) -> list
        _ -> []
      end

    new_list =
      [latency_ms | current]
      |> Enum.take(@max_latency_samples)

    :ets.insert(@table, {:latency_samples, new_list})
    :ok
  end

  defp latency_stats do
    samples =
      try do
        :ets.lookup_element(@table, :latency_samples, 2)
      rescue
        ArgumentError -> []
      else
        list when is_list(list) -> list
        _ -> []
      end

    count = length(samples)

    if count == 0 do
      {0, 0.0, 0}
    else
      sorted = Enum.sort(samples)
      avg = Enum.sum(sorted) / count
      p95 = percentile(sorted, count)
      {count, avg * 1.0, p95}
    end
  end

  # Nearest-rank p95: index = ceil(0.95 * count) - 1 (0-based). For count < 20,
  # we return the max (per spec) so small sample sizes don't produce a
  # misleadingly low p95.
  defp percentile(sorted, count) when count < 20 do
    Enum.max(sorted)
  end

  defp percentile(sorted, count) do
    # Nearest-rank method: rank = ceil(p/100 * n), index = rank - 1 (0-based).
    rank = ceil(0.95 * count)
    index = max(rank - 1, 0)
    Enum.at(sorted, index)
  end

  defp error_rate(0, _errors), do: 0.0
  defp error_rate(total, errors), do: errors / total * 1.0

  # Decimal → integer micro-USD. round(cost * 1_000_000).
  defp decimal_to_micro(%Decimal{} = d) do
    d
    |> Decimal.mult(Decimal.new(1_000_000))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp decimal_to_micro(n) when is_integer(n), do: n
  defp decimal_to_micro(n) when is_float(n), do: round(n * 1_000_000)

  defp micro_to_decimal(micro) when is_integer(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
  end
end
