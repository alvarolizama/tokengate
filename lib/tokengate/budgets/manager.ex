defmodule Tokengate.Budgets.Manager do
  @moduledoc """
  ETS-backed micro-USD daily/monthly spend cache for budget enforcement.

  Maintains a hot cache of per-member spend in **micro-USD** (USD × 1_000_000)
  so that `:ets.update_counter/4` can atomically increment counters without
  the float drift that would accumulate with Decimal-in-ETS approaches.

  ## Table

  - `:tokengate_budgets` — a single public, named ETS `:set` table with
    `write_concurrency: true`. Objects are flat 4-tuples:

      {key, amount_micro, loaded_from_db?, period_stamp}

    - `key` — `{member_id, :daily}` or `{member_id, :monthly}` (position 1).
    - `amount_micro` — integer micro-USD, the counter element (position 2),
      updated atomically via `:ets.update_counter/4`.
    - `loaded_from_db?` — boolean (position 3); `true` once seeded from DB.
    - `period_stamp` — `Date.t()` for daily, `{year, month}` for monthly
      (position 4); used to detect day/month rollover.

  Storing the period stamp on the entry lets reads/writes detect a rollover
  and reset the counter to 0 (re-seeding from the DB).

  ## Lazy DB load

  The durable truth is the `request_logs` table; this ETS cache is a hot
  replica rebuilt lazily on first touch of a member's period.

  To keep the singleton GenServer free of DB I/O, the DB read happens in
  the **caller process** (via `load_from_db/2`), which then calls the
  GenServer (`seed/3`) to insert the seeded counter. The GenServer only
  owns the table lifecycle and serializes seeds/sets; counter increments
  are lock-free via ETS `update_counter`.

  ## API summary

    * `check/4` — pre-flight budget check (current_spend + estimated vs limit).
    * `record_spend/2` — post-request accumulation (atomic counter bump +
      SyncWorker enqueue).
    * `spend/1` — read-back of current daily/monthly spend in USD.
    * `set_from_db/3` — used by `Budgets.SyncWorker` to reset drift.
    * `seed/3` — internal, called by the lazy-load helper.
    * `load_from_db/2` — DB read helper (caller-side).

  `nil` limit means unlimited for that period.
  """

  use GenServer

  require Logger

  @table :tokengate_budgets
  @micro 1_000_000
  @global_key {:global, :daily}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Pre-flight budget check for a team member's request.

  Single cap: member's monthly budget (team default + member extra) minus
  current monthly spend. `nil` budget means unlimited.

  Returns `:ok` or `{:error, :budget_exceeded, %{available: Decimal.t()}}`.
  """
  @spec check_ladder(
          member_monthly_budget :: Decimal.t() | nil,
          member_monthly_spend :: Decimal.t(),
          estimated_cost_usd :: Decimal.t()
        ) :: :ok | {:error, :budget_exceeded, map()}
  def check_ladder(member_monthly_budget, member_monthly_spend, estimated_cost_usd) do
    estimated_micro = to_micro(estimated_cost_usd)
    spend_micro = to_micro(member_monthly_spend)

    available_micro =
      if member_monthly_budget do
        max(0, to_micro(member_monthly_budget) - spend_micro)
      else
        :unlimited
      end

    # Two rejection paths:
    #   1. Already exhausted (spend > budget) — rejects regardless of new cost.
    #   2. New cost would push us over budget.
    # The first path is what the 2026-07-30 refactor relies on: with the
    # upstream cost only known after the call, we always pass `0` from the
    # pre-check, so the "exhausted" gate is what actually keeps a member from
    # racking up unlimited spend.
    if available_micro == :unlimited or
         (estimated_micro <= available_micro and
            spend_micro <= to_micro(member_monthly_budget || 0)) do
      :ok
    else
      {:error, :budget_exceeded, %{available: from_micro(available_micro)}}
    end
  end

  @doc """
  Records actual spend for `member_id` by atomically incrementing both the
  daily and monthly ETS counters by `provider_cost_usd` (in micro-USD).

  `provider_cost_usd` is what TokenGate actually paid for the request,
  preferring the cost reported by the provider and falling back to the
  pricing-row estimate. This keeps the budget counters in the same currency
  as the "Costo real" shown in the dashboard.

  If a period's entry is missing or stale (day/month rollover), it is
  lazy-loaded from the DB first (read in the caller, seeded via the
  GenServer) before the counter bump.

  After updating the counters, enqueues a `Budgets.SyncWorker` Oban job
  for drift correction. In the test environment Oban runs in `:manual`
  mode, so the job is only enqueued (assert with `assert_enqueued/1`).
  """
  @spec record_spend(member_id :: term(), provider_cost_usd :: Decimal.t() | nil) :: :ok
  def record_spend(member_id, provider_cost_usd) do
    record_spend(member_id, nil, provider_cost_usd)
  end

  @spec record_spend(
          member_id :: term(),
          model_alias_id :: term(),
          provider_cost_usd :: Decimal.t() | nil
        ) :: :ok
  def record_spend(member_id, model_alias_id, provider_cost_usd) do
    micro = to_micro(provider_cost_usd)

    ensure_loaded(member_id, :daily)
    ensure_loaded(member_id, :monthly)

    # Per-model counters only when a model is in scope. `nil` model_alias_id
    # (the /2 convenience used by tests) tracks member-level + global only.
    if model_alias_id do
      ensure_loaded({member_id, model_alias_id}, :daily)
      ensure_loaded({:model, model_alias_id}, :daily)
    end

    # Atomic increments. Position 2 = amount_micro.
    bump_counter({member_id, :daily}, micro)
    bump_counter({member_id, :monthly}, micro)
    bump_counter(@global_key, micro)

    if model_alias_id do
      bump_counter({{member_id, model_alias_id}, :daily}, micro)
      bump_counter({{:model, model_alias_id}, :daily}, micro)
    end

    # Debounced drift-correction enqueue: instead of one Oban job per request,
    # we mark `{:sync_pending, member_id}` with insert_new and only enqueue when
    # the mark didn't already exist. The SyncWorker deletes the mark when it
    # runs, so the next request re-enqueues. This collapses bursts of spend
    # into a single sync per member per SyncWorker run.
    maybe_enqueue_sync(member_id)

    :ok
  end

  @doc """
  Returns the current daily and monthly spend for `member_id` as Decimals
  (USD), converting from the internal micro-USD representation.

  Triggers lazy load from the DB if the entry is missing or stale (day/month
  rollover). Missing entries are seeded to 0 (no spend yet this period).
  """
  @spec spend(member_id :: term()) :: %{daily_usd: Decimal.t(), monthly_usd: Decimal.t()}
  def spend(member_id) do
    ensure_loaded(member_id, :daily)
    ensure_loaded(member_id, :monthly)

    %{
      daily_usd: from_micro(read_counter({member_id, :daily})),
      monthly_usd: from_micro(read_counter({member_id, :monthly}))
    }
  end

  # ---------------------------------------------------------------------------
  # Global daily cap
  # ---------------------------------------------------------------------------

  @doc """
  Returns the total daily spend across every member and credential (UTC day)
  in USD as a Decimal. Lazy-loads from the DB on first touch or day rollover.
  """
  @spec global_daily_spend() :: Decimal.t()
  def global_daily_spend do
    ensure_loaded_global()
    from_micro(read_counter(@global_key))
  end

  @doc """
  Whether the global daily spending cap has been reached for the current
  UTC day. A `nil` cap means unlimited — always `false`.
  """
  @spec global_exhausted?(Decimal.t() | nil) :: boolean()
  def global_exhausted?(nil), do: false

  def global_exhausted?(%Decimal{} = cap) do
    ensure_loaded_global()
    read_counter(@global_key) >= to_micro(cap)
  end

  @doc """
  Resets the global daily ETS counter to the micro-USD value recomputed
  from the DB by `Budgets.SyncWorker`.
  """
  @spec set_global_from_db(integer()) :: :ok
  def set_global_from_db(daily_micro) do
    GenServer.call(__MODULE__, {:set_global_from_db, daily_micro})
  end

  # ---------------------------------------------------------------------------
  # Per-model daily caps
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current daily spend for a specific model across ALL users
  (UTC day) in USD as a Decimal. Lazy-loads from the DB on first touch or
  day rollover.
  """
  @spec model_total_daily_spend(model_alias_id :: term()) :: Decimal.t()
  def model_total_daily_spend(model_alias_id) do
    ensure_loaded({:model, model_alias_id}, :daily)
    from_micro(read_counter({{:model, model_alias_id}, :daily}))
  end

  @doc """
  Returns the current daily spend for `member_id` on a specific model
  (UTC day) in USD as a Decimal. Lazy-loads from the DB on first touch or
  day rollover.
  """
  @spec model_per_user_daily_spend(member_id :: term(), model_alias_id :: term()) :: Decimal.t()
  def model_per_user_daily_spend(member_id, model_alias_id) do
    ensure_loaded({member_id, model_alias_id}, :daily)
    from_micro(read_counter({{member_id, model_alias_id}, :daily}))
  end

  @doc """
  Whether the model's total daily cap (across all users) has been reached
  for the current UTC day. A `nil` or `0` cap means unlimited — always
  `false`.
  """
  @spec model_total_exhausted?(model_alias_id :: term(), cap :: Decimal.t() | number() | nil) ::
          boolean()
  def model_total_exhausted?(model_alias_id, cap) do
    case normalize_cap(cap) do
      nil ->
        false

      %Decimal{} = limit ->
        ensure_loaded({:model, model_alias_id}, :daily)
        read_counter({{:model, model_alias_id}, :daily}) >= to_micro(limit)
    end
  end

  @doc """
  Whether the member's per-user daily cap on the model has been reached for
  the current UTC day. A `nil` or `0` cap means unlimited — always `false`.
  """
  @spec model_per_user_exhausted?(
          member_id :: term(),
          model_alias_id :: term(),
          cap :: Decimal.t() | number() | nil
        ) :: boolean()
  def model_per_user_exhausted?(member_id, model_alias_id, cap) do
    case normalize_cap(cap) do
      nil ->
        false

      %Decimal{} = limit ->
        ensure_loaded({member_id, model_alias_id}, :daily)
        read_counter({{member_id, model_alias_id}, :daily}) >= to_micro(limit)
    end
  end

  @doc """
  Resets the daily and monthly ETS counters for `member_id` to the given
  micro-USD values, as recomputed by `Budgets.SyncWorker` from the DB.

  Marks the entries as `loaded_from_db?: true` and stamps the current
  day/month so they are not considered stale on the next read.
  """
  @spec set_from_db(member_id :: term(), daily_micro :: integer(), monthly_micro :: integer()) ::
          :ok
  def set_from_db(member_id, daily_micro, monthly_micro) do
    GenServer.call(__MODULE__, {:set_from_db, member_id, daily_micro, monthly_micro})
  end

  @doc """
  Seeds a single period entry for `member_id` from a precomputed micro-USD
  value (typically the result of `load_from_db/2`).

  This is the GenServer-side companion to `load_from_db/2`: the caller reads
  from the DB and passes the integer micro-USD here so the singleton never
  touches the repo.
  """
  @spec seed(member_id :: term(), period :: :daily | :monthly, micro :: integer()) :: :ok
  def seed(member_id, period, micro) do
    GenServer.call(__MODULE__, {:seed, member_id, period, micro})
    # Clear the single-flight loading marker now that the real entry is in
    # place (see `seed_from_db_single_flight/3`). Idempotent — the marker may
    # already have been removed by the caller's `after` block.
    :ets.delete(@table, {:loading, {member_id, period}})
    :ok
  end

  @doc """
  Loads the spend for `subject` over the given period from the DB
  (`Tokengate.Logs.cost_summary/1`) and returns it as integer micro-USD.

  `subject` may be:

    * a member id (binary) — member-level daily/monthly spend;
    * `{member_id, model_alias_id}` — per-user per-model daily spend;
    * `{:model, model_alias_id}` — per-model daily spend across all users;
    * `{:credential, credential_id}` — per-credential spend.

  This reads `total_cost_usd` — what TokenGate actually paid — so the
  budget counters stay in the same currency as the dashboard's
  "Costo real".

  This is intended to be called from the **caller process** (not the
  GenServer) to keep DB I/O out of the singleton. The returned value is
  then handed to `seed/3` to populate the ETS cache.

  `from` is a `DateTime.t()` marking the start of the period (e.g. start
  of today for daily, start of month for monthly).
  """
  @spec load_from_db(subject :: term(), from :: DateTime.t()) :: integer()
  def load_from_db(subject, from) do
    filters = subject_filters(subject) |> Map.put(:from, from)
    summary = Tokengate.Logs.cost_summary(filters)
    to_micro(summary.total_cost_usd)
  end

  @doc """
  Deletes every `{member_id, :monthly}` entry from the ETS table.

  Called by `Budgets.ResetWorker` on the 1st of each month. The next
  `record_spend/2` or `spend/1` for each member will lazy-load from DB,
  which effectively starts the monthly counter at 0.
  """
  @spec reset_monthly_counters() :: integer()
  def reset_monthly_counters do
    # Match pattern: delete every entry whose key ends in `:monthly`.
    :ets.select_delete(@table, [{{{:_, :monthly}, :_, :_, :_}, [], [true]}])
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:seed, member_id, period, micro}, _from, state) do
    key = {member_id, period}
    obj = {key, micro, true, current_period_stamp(period)}
    :ets.insert(@table, obj)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_from_db, member_id, daily_micro, monthly_micro}, _from, state) do
    :ets.insert(@table, {{member_id, :daily}, daily_micro, true, current_period_stamp(:daily)})

    :ets.insert(
      @table,
      {{member_id, :monthly}, monthly_micro, true, current_period_stamp(:monthly)}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_global_from_db, daily_micro}, _from, state) do
    :ets.insert(@table, {@global_key, daily_micro, true, current_period_stamp(:daily)})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:seed_global, micro}, _from, state) do
    :ets.insert(@table, {@global_key, micro, true, current_period_stamp(:daily)})
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Internal — table lifecycle
  # ---------------------------------------------------------------------------

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true,
        read_concurrency: true
      ])
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — period stamping
  # ---------------------------------------------------------------------------

  defp current_period_stamp(:daily), do: Date.utc_today()

  defp current_period_stamp(:monthly) do
    now = Date.utc_today()
    {now.year, now.month}
  end

  # ---------------------------------------------------------------------------
  # Internal — check logic
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Internal — ensure loaded / stale check
  # ---------------------------------------------------------------------------

  # Ensures the entry for (member_id, period) exists and is current. If it
  # is missing or the stored day/month no longer matches today, we re-seed
  # from the DB. The DB read happens in the caller (this process), then the
  # GenServer seeds the entry — keeping DB I/O out of the singleton.
  defp ensure_loaded(member_id, period) do
    key = {member_id, period}
    current = current_period_stamp(period)

    case :ets.lookup(@table, key) do
      [] ->
        seed_from_db_single_flight(member_id, period, key)

      [{^key, _micro, _loaded?, stored_period}] ->
        if stale?(period, stored_period, current) do
          seed_from_db_single_flight(member_id, period, key)
        else
          :ok
        end
    end
  end

  defp stale?(:daily, stored_day, today), do: stored_day != today

  defp stale?(:monthly, {y, m}, {ty, tm}), do: y != ty or m != tm

  # Ensures the global daily entry exists and is current. Same lazy-load
  # pattern as per-member/credential entries but keyed by @global_key.
  # Degrades gracefully if the ETS table doesn't exist yet (hot-reload).
  defp ensure_loaded_global do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        case :ets.lookup(@table, @global_key) do
          [] ->
            seed_global_from_db()

          [{@global_key, _micro, _loaded?, stored_day}] ->
            if stored_day != Date.utc_today() do
              seed_global_from_db()
            end
        end
    end
  rescue
    ArgumentError -> :ok
  end

  defp seed_global_from_db do
    from = period_start(:daily)
    summary = Tokengate.Logs.cost_summary(%{from: from})
    micro = to_micro(summary.total_cost_usd)
    GenServer.call(__MODULE__, {:seed_global, micro})
  end

  defp seed_from_db(member_id, period) do
    from = period_start(period)
    micro = load_from_db(member_id, from)
    seed(member_id, period, micro)
  end

  # Single-flight wrapper around `seed_from_db/2`: concurrent callers for the
  # same key (thundering herd on a brand-new member or day rollover) park on
  # the ETS `{:loading, key}` marker instead of all hitting the DB at once.
  # The marker is removed in the `after` block (crash-safe) and again in
  # `seed/3` after the real entry is inserted (idempotent no-op).
  defp seed_from_db_single_flight(member_id, period, key) do
    loading_key = {:loading, key}

    case :ets.insert_new(@table, {loading_key, true}) do
      true ->
        try do
          seed_from_db(member_id, period)
        after
          :ets.delete(@table, loading_key)
        end

      false ->
        # Someone else is loading this key — wait briefly for them to finish,
        # then proceed either way. If the loader crashed, the `after` block
        # removes the marker so the next caller retries the seed.
        wait_for_load(key, 0)
    end
  end

  # Polls for the real entry to appear. Gives up after 10 × 5ms = 50ms and
  # proceeds anyway — `bump_counter` / `read_counter` tolerate a missing
  # entry, so worst case we seed from 0 for this request.
  defp wait_for_load(_key, attempts) when attempts >= 10, do: :ok

  defp wait_for_load(key, attempts) do
    case :ets.lookup(@table, key) do
      [] ->
        Process.sleep(5)
        wait_for_load(key, attempts + 1)

      [_] ->
        :ok
    end
  end

  defp period_start(:daily) do
    today = Date.utc_today()
    DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
  end

  defp period_start(:monthly) do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
  end

  # ---------------------------------------------------------------------------
  # Internal — counter read / bump
  # ---------------------------------------------------------------------------

  defp read_counter(key) do
    # Position 2 = amount_micro. Default 0 when key missing.
    :ets.lookup_element(@table, key, 2, 0)
  end

  defp bump_counter(key, inc) when is_integer(inc) do
    # Increment element at position 2 (amount_micro) by inc.
    # Default object covers the rare race where the entry was evicted
    # between ensure_loaded and here.
    period = elem(key, 1)
    default = {key, 0, false, current_period_stamp(period)}

    case :ets.lookup(@table, key) do
      [] ->
        Logger.warning(
          "Budget entry evicted before bump_counter for #{inspect(key)} — reseeding from 0"
        )

        :ets.update_counter(@table, key, {2, inc}, default)

      [_] ->
        :ets.update_counter(@table, key, {2, inc}, default)
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — debounced SyncWorker enqueue
  # ---------------------------------------------------------------------------

  defp maybe_enqueue_sync({:credential, credential_id} = subject) do
    key = {:sync_pending, subject}

    if :ets.insert_new(@table, {key, true}) do
      _ =
        %{credential_id: credential_id}
        |> Tokengate.Budgets.SyncWorker.new()
        |> Oban.insert()
    end

    :ok
  end

  defp maybe_enqueue_sync(member_id) do
    key = {:sync_pending, member_id}

    if :ets.insert_new(@table, {key, true}) do
      _ =
        %{member_id: member_id}
        |> Tokengate.Budgets.SyncWorker.new()
        |> Oban.insert()
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal — PubSub broadcast for live dashboards
  # ---------------------------------------------------------------------------

  @doc false
  def clear_sync_pending({:credential, _credential_id} = subject) do
    :ets.delete(@table, {:sync_pending, subject})
    :ok
  end

  def clear_sync_pending(member_id) do
    :ets.delete(@table, {:sync_pending, member_id})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal — micro-USD conversion
  # ---------------------------------------------------------------------------

  defp to_micro(nil), do: 0

  defp to_micro(%Decimal{} = d) do
    # micro = round(usd * 1_000_000)
    d
    |> Decimal.mult(Decimal.new(@micro))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp to_micro(usd) when is_number(usd) do
    round(usd * @micro)
  end

  defp from_micro(micro) when is_integer(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(@micro))
  end

  # ---------------------------------------------------------------------------
  # Internal — subject → cost_summary filter mapping
  # ---------------------------------------------------------------------------

  # Maps a budget subject to the `Tokengate.Logs.cost_summary/1` filters used
  # to lazy-load its spend from the durable `request_logs` table. More specific
  # tuple shapes must match before the generic `{member_id, model_alias_id}`.
  # A binary subject may be a team member *or* a service (both keyed by their
  # id), so we use the combined `:subject_id` filter that matches either.
  defp subject_filters(subject) when is_binary(subject), do: %{subject_id: subject}
  defp subject_filters({:credential, credential_id}), do: %{credential_id: credential_id}
  defp subject_filters({:model, model_alias_id}), do: %{model_alias_id: model_alias_id}

  defp subject_filters({member_id, model_alias_id}),
    do: %{subject_id: member_id, model_alias_id: model_alias_id}

  # ---------------------------------------------------------------------------
  # Internal — cap normalization (nil/0 = unlimited)
  # ---------------------------------------------------------------------------

  # A cap of `nil` or `0` (in any numeric representation) means "unlimited" and
  # normalizes to `nil`. Anything else returns a `Decimal` limit.
  defp normalize_cap(nil), do: nil
  defp normalize_cap(%Decimal{} = d), do: if(Decimal.equal?(d, Decimal.new(0)), do: nil, else: d)
  defp normalize_cap(n) when is_number(n), do: if(n == 0, do: nil, else: Decimal.new(n))
  defp normalize_cap(_), do: nil
end
