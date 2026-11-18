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
    * `{:requests, {:agent, type}}`    — per `agent_type`, bounded (see below)
    * `{:tokens, :prompt}`             — total prompt tokens
    * `{:tokens, :completion}`         — total completion tokens
    * `{:cost_micro, :total}`          — total cost in micro-USD (Decimal → integer)
    * `{:latency, :sum}`               — sum of all latency samples (ms)
    * `{:latency, :count}`             — number of latency samples
    * `{:latency, {:bucket, upper}}`   — histogram bucket counters (atomic)

  ## Cardinality

  `agent_type` is the ONE dimension that comes from client input
  (`X-Agent-Type` is free text), so it is the only one that could grow the
  table forever: a client sending a unique value per request used to mint a
  permanent ETS entry each time. Writes collapse it onto a fixed vocabulary
  (`@agent_types`) plus an `"other"` bucket, which caps the key set at a
  constant; the periodic sweep below removes any key outside it (legacy rows
  written before the allowlist existed).

  The per-model / per-provider tallies were removed: nothing read them, and
  they were a write per request plus an ETS key per dimension value.

  Latency is a fixed-bucket histogram instead of the old prepend-and-trim
  list: each request atomically increments its bucket with
  `:ets.update_counter/4`, so there is no read-modify-write race between
  concurrent proxy processes. p95 is approximated from the histogram with
  nearest-rank interpolation; avg is `sum / count` exact.

  ## Broadcast coalescing

  Dashboards only need the event as a "something changed" trigger, so
  `record_request/1` broadcasts AT MOST once per `@broadcast_interval_ms`
  instead of one PubSub message per proxied request (`F44`: two broadcasts per
  request woke every connected LiveView).

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

  # Fixed vocabulary for the ONE client-controlled dimension (`X-Agent-Type`).
  # Anything else collapses into @agent_overflow, so the ETS key set cannot
  # grow with traffic.
  @agent_types ~w(api sdk cli curl browser ide unknown)
  @agent_overflow "other"

  # Minimum spacing between `metrics:updated` broadcasts: dashboards treat the
  # event as a dirty flag, so one per second is plenty and one per request
  # storms every connected LiveView.
  @broadcast_interval_ms 1_000
  @broadcast_key {:broadcast, :last_ms}

  # Cadence of the stray-key sweep.
  @sweep_interval_ms 60_000

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

    * `model_id`  — term (usually binary id); accepted, NOT tallied (see
      "Cardinality": the per-model counters were written on every request and
      read by nothing)
    * `provider_id`     — term; accepted, NOT tallied (same reason)
    * `agent_type`      — string; collapsed onto the fixed vocabulary
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
    agent_type = Map.get(attrs, :agent_type)
    status = Map.get(attrs, :status, 0)
    latency_ms = Map.get(attrs, :latency_ms, 0)
    prompt_tokens = Map.get(attrs, :prompt_tokens, 0)
    completion_tokens = Map.get(attrs, :completion_tokens, 0)
    cost_usd = Map.get(attrs, :cost_usd) || Decimal.new(0)

    cost_micro = decimal_to_micro(cost_usd)

    # Counters
    incr({:requests, :total})

    # The only dimension that comes from client input: collapse it onto the
    # fixed vocabulary so the table cannot grow with traffic.
    case agent_bucket(agent_type) do
      nil -> :ok
      bucket -> incr({:requests, {:agent, bucket}})
    end

    if status >= 400 do
      incr({:requests, :errors})
    end

    add({:tokens, :prompt}, prompt_tokens)
    add({:tokens, :completion}, completion_tokens)
    add({:cost_micro, :total}, cost_micro)

    # Latency histogram: atomic bucket increment + running sum/count.
    record_latency(latency_ms)

    broadcast_metrics_updated()

    :ok
  end

  # `nil` (unknown caller) writes nothing; a known type passes through; any
  # other client-supplied string becomes the overflow bucket. Bounded at 8
  # possible keys, forever.
  defp agent_bucket(nil), do: nil
  defp agent_bucket(type) when type in @agent_types, do: type
  defp agent_bucket(type) when is_binary(type) or is_atom(type), do: @agent_overflow
  defp agent_bucket(_), do: nil

  @doc """
  Returns the current in-memory snapshot.

  Shape:

      %{
        requests_total: non_neg_integer(),
        errors_total: non_neg_integer(),
        error_rate: float(),
        by_agent: %{type => n},
        prompt_tokens: non_neg_integer(),
        completion_tokens: non_neg_integer(),
        cost_usd: Decimal.t(),
        latency: %{count: non_neg_integer(), avg_ms: float(), p95_ms: number()}
      }

  `by_agent` is keyed by the bounded vocabulary (see "Cardinality").
  `error_rate` is `0.0` when there are no requests. `cost_usd` is
  reconstructed from the micro-USD integer counter as `Decimal` with 6
  decimal places. `avg_ms` is exact (`sum / count`). `p95_ms` is the
  nearest-rank upper bound from the fixed-bucket histogram.
  """
  @spec snapshot() :: map()
  def snapshot do
    requests_total = read_counter({:requests, :total})
    errors_total = read_counter({:requests, :errors})

    by_agent = select_dim(:agent)

    prompt_tokens = read_counter({:tokens, :prompt})
    completion_tokens = read_counter({:tokens, :completion})

    cost_micro = read_counter({:cost_micro, :total})

    {count, avg_ms, p95_ms} = latency_stats()

    %{
      requests_total: requests_total,
      errors_total: errors_total,
      error_rate: error_rate(requests_total, errors_total),
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
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    prune_dimensions()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Removes any agent key outside the fixed vocabulary. With the write-time
  # allowlist this is a no-op in steady state; it is the self-heal for keys
  # minted by an older version (or by a future code path that forgets the
  # allowlist), so an unbounded dimension can never survive a deploy.
  defp prune_dimensions do
    allowed = MapSet.new(@agent_types ++ [@agent_overflow])

    @table
    |> :ets.select([{{{:requests, {:agent, :"$1"}}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.each(&:ets.delete(@table, {:requests, {:agent, &1}}))

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Coalesced dirty flag: at most one `metrics:updated` per interval, no
  # matter how many proxy processes record a request concurrently.
  defp broadcast_metrics_updated do
    if claim_broadcast_slot(System.monotonic_time(:millisecond)) do
      PubSub.broadcast(@pubsub, @topic, {:metrics_updated, snapshot_lite()})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Claims the broadcast slot: `insert_new` takes the FIRST slot after a reset,
  # and the interval slot is claimed by DELETING the stale stamp (only one
  # caller can delete the same ETS object) and re-stamping it.
  defp claim_broadcast_slot(now) do
    if :ets.insert_new(@table, {@broadcast_key, now}) do
      true
    else
      stale = [
        {{@broadcast_key, :"$1"}, [{:>=, now, {:+, :"$1", @broadcast_interval_ms}}], [true]}
      ]

      if :ets.select_delete(@table, stale) == 1 do
        :ets.insert(@table, {@broadcast_key, now})
        true
      else
        false
      end
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
