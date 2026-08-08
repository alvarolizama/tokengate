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
  `record_request/1` uses `:ets.update_counter/4` (atomic), and `snapshot/0` /
  `reset/0` read/replace keys directly. This avoids a GenServer bottleneck on
  the hot path.

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
    * `{:latency, :sum}`               — sum of all latency samples (ms)
    * `{:latency, :count}`             — number of latency samples
    * `{:latency, {:bucket, upper}}`   — histogram bucket counters (atomic)

  Latency is a fixed-bucket histogram instead of the old prepend-and-trim
  list: each request atomically increments its bucket with
  `:ets.update_counter/4`, so there is no read-modify-write race between
  concurrent proxy processes. p95 is approximated from the histogram with
  nearest-rank interpolation; avg is `sum / count` exact.

  Micro-USD: `round(cost_usd * 1_000_000)` so $1.500000 → 1_500_000.
  """

  use GenServer

  alias Phoenix.PubSub

  @table :tokengate_metrics
  @pubsub Tokengate.PubSub
  @topic "metrics:updated"

  # Fixed latency buckets (upper bound in ms, inclusive). The infinity bucket
  # catches everything above the last finite bound. Ordered ascending for
  # nearest-rank p95 computation.
  @latency_buckets [50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, :infinity]

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

    # Latency histogram: atomic bucket increment + running sum/count.
    record_latency(latency_ms)

    # Rolling per-model window for the Monitor sparklines
    Tokengate.Metrics.Window.record_request(attrs)
    Tokengate.Metrics.Window.record_request_credential(attrs)

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
  decimal places. `avg_ms` is exact (`sum / count`). `p95_ms` is the
  nearest-rank upper bound from the fixed-bucket histogram.
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

  # Latency histogram ----------------------------------------------------------

  defp record_latency(latency_ms) when is_integer(latency_ms) and latency_ms >= 0 do
    # Sum + count for exact average.
    add({:latency, :sum}, latency_ms)
    incr({:latency, :count})

    # Atomic bucket increment. The bucket key is the upper bound; :infinity
    # catches anything above the last finite bound.
    bucket = latency_bucket(latency_ms)
    incr({:latency, {:bucket, bucket}})

    :ok
  end

  defp record_latency(_latency_ms), do: :ok

  defp latency_bucket(latency_ms) do
    Enum.find(@latency_buckets, fn
      :infinity -> true
      upper -> latency_ms <= upper
    end)
  end

  defp latency_stats do
    count = read_counter({:latency, :count})
    sum = read_counter({:latency, :sum})

    if count == 0 do
      {0, 0.0, 0}
    else
      avg = sum / count
      p95 = histogram_p95(count)
      {count, avg * 1.0, p95}
    end
  end

  # Nearest-rank p95 over the fixed-bucket histogram: find the bucket whose
  # cumulative count reaches the p95 rank, then linearly interpolate within
  # that bucket's width for a smoother estimate. The :infinity bucket maps
  # to the previous finite bound (no upper width to interpolate over).
  defp histogram_p95(total_count) do
    rank = ceil(0.95 * total_count)

    {_cumulative, p95} =
      Enum.reduce_while(@latency_buckets, {0, 0}, fn bucket, {cumulative, _p95} ->
        count = read_counter({:latency, {:bucket, bucket}})
        cumulative = cumulative + count

        if cumulative >= rank do
          p95 = interpolate_bucket(bucket, cumulative - count, rank, count)
          {:halt, {cumulative, p95}}
        else
          {:cont, {cumulative, 0}}
        end
      end)

    p95
  end

  defp interpolate_bucket(:infinity, _bucket_start, _rank, _count) do
    # Open-ended bucket: use the previous finite bound as the estimate.
    @latency_buckets |> Enum.at(-2)
  end

  defp interpolate_bucket(upper, bucket_start, rank, count) do
    # Linear interpolation within the bucket's width.
    lower = previous_bucket_upper(upper)

    if count == 0 do
      upper
    else
      fraction = (rank - bucket_start) / count
      lower + fraction * (upper - lower)
    end
  end

  defp previous_bucket_upper(upper) do
    case Enum.take_while(@latency_buckets, &(&1 != upper)) do
      [] -> 0
      buckets -> List.last(buckets)
    end
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
