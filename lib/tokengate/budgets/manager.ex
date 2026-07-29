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

  @table :tokengate_budgets
  @micro 1_000_000

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

    available_micro =
      if member_monthly_budget do
        max(0, to_micro(member_monthly_budget) - to_micro(member_monthly_spend))
      else
        :unlimited
      end

    if available_micro == :unlimited or estimated_micro <= available_micro do
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
    micro = to_micro(provider_cost_usd)

    ensure_loaded(member_id, :daily)
    ensure_loaded(member_id, :monthly)

    # Atomic increments. Position 2 = amount_micro.
    bump_counter({member_id, :daily}, micro)
    bump_counter({member_id, :monthly}, micro)

    # Enqueue drift-correction worker. In test env (testing: :manual) this
    # only queues the job; it does not execute it.
    _ =
      %{member_id: member_id}
      |> Tokengate.Budgets.SyncWorker.new()
      |> Oban.insert()

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
  end

  @doc """
  Loads the spend for `member_id` over the given period from the DB
  (`Tokengate.Logs.cost_summary/1`) and returns it as integer micro-USD.

  This reads `total_provider_cost_usd` — what TokenGate actually paid —
  so the budget counters stay in the same currency as the dashboard's
  "Costo real".

  This is intended to be called from the **caller process** (not the
  GenServer) to keep DB I/O out of the singleton. The returned value is
  then handed to `seed/3` to populate the ETS cache.

  `from` is a `DateTime.t()` marking the start of the period (e.g. start
  of today for daily, start of month for monthly).
  """
  @spec load_from_db(member_id :: term(), from :: DateTime.t()) :: integer()
  def load_from_db(member_id, from) do
    summary =
      Tokengate.Logs.cost_summary(%{
        team_member_id: member_id,
        from: from
      })

    to_micro(summary.total_provider_cost_usd)
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
        seed_from_db(member_id, period)

      [{^key, _micro, _loaded?, stored_period}] ->
        if stale?(period, stored_period, current) do
          seed_from_db(member_id, period)
        else
          :ok
        end
    end
  end

  defp stale?(:daily, stored_day, today), do: stored_day != today

  defp stale?(:monthly, {y, m}, {ty, tm}), do: y != ty or m != tm

  defp seed_from_db(member_id, period) do
    from = period_start(period)
    micro = load_from_db(member_id, from)
    seed(member_id, period, micro)
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
    :ets.update_counter(@table, key, {2, inc}, default)
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
end
