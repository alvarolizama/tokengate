defmodule Tokengate.Budgets.Manager do
  @moduledoc """
  ETS-backed micro-USD spend cache for budget enforcement.

  Two budget layers, one reserve primitive:

  - **Layer 1 — monthly per subject** (`{subject_id, :monthly}`): the member's
    or service's effective monthly budget (group default + extra). `nil` =
    unlimited.
  - **Layer 2 — global daily kill-switch** (`{:global, :daily}`): the org-wide
    daily cap. `nil` = off.

  ## Table

  - `:tokengate_budgets` — a single public, named ETS `:set` table with
    `write_concurrency: true`. Objects are flat 4-tuples:

      {key, amount_micro, loaded_from_db?, period_stamp}

    - `key` — `{subject_id, :monthly}`, `{subject_id, :daily}` (display only)
      or `{:global, :daily}` (position 1).
    - `amount_micro` — integer micro-USD, the counter element (position 2),
      updated atomically via `:ets.update_counter/4`.
    - `loaded_from_db?` — boolean (position 3); `true` once seeded from DB.
    - `period_stamp` — `Date.t()` for daily, `{year, month}` for monthly
      (position 4); used to detect day/month rollover.

  ## Enforcement model: reserve → settle

  The durable truth is `request_logs`; this ETS cache is a hot replica. A
  request **reserves** (holds) an amount on both layers before it executes and
  **settles** the hold to the real cost when it finishes. Holding before the
  cost is known is what stops N concurrent requests from jointly blowing past
  a cap: each request holds its share first (see `reserve/5`).

  ## API summary

    * `reserve/5` — pre-flight hold on both layers (rejects if exhausted).
    * `settle/3` — swap the hold for the real cost after the request.
    * `release/2` — release a hold when the request never settled (error path).
    * `spend/1` — read-back of current daily/monthly spend in USD (display).
    * `global_daily_spend/0` — read-back of the org daily spend (display).
    * `set_from_db/3` / `set_global_from_db/1` — `Budgets.SyncWorker` drift reset.
    * `reset_monthly_counters/0` — `Budgets.ResetWorker` monthly reset.
    * `seed/3` / `load_from_db/2` — lazy-load helpers.

  `nil` budget/cap means unlimited for that layer.
  """

  use GenServer

  require Logger

  @table :tokengate_budgets
  @credits_table :tokengate_credits
  @micro 1_000_000
  @global_key {:global, :daily}

  # ---------------------------------------------------------------------------
  # Public API — enforcement
  # ---------------------------------------------------------------------------

  @doc """
  Reserves budget for an in-flight request on both layers.

  Holds `requested_cost_usd` against the subject's monthly counter (layer 1,
  cap = `monthly_budget_usd`) and the global daily counter (layer 2, cap =
  `global_cap_usd`). Rejects when either layer is already exhausted, so N
  concurrent requests cannot jointly blow past a cap.

  Optimistic and atomic: `:ets.update_counter/4` bumps first and returns the
  new value, so the "already exhausted" decision needs no lock. The held
  amount may transiently push a counter above its cap; `settle/3` corrects it.

  `monthly_budget_usd == nil` (unlimited) holds nothing and never rejects.
  `exempt_global?` skips layer 2 entirely (a `global_daily` exemption).

  Returns `{:ok, hold}` or
  `{:error, {:budget_exceeded, %{layer: :subject | :global}}}`.
  """
  @spec reserve(
          subject_id :: term(),
          monthly_budget_usd :: Decimal.t() | nil,
          global_cap_usd :: Decimal.t() | nil,
          requested_cost_usd :: Decimal.t() | nil,
          exempt_global? :: boolean()
        ) ::
          {:ok, map()} | {:error, {:budget_exceeded, %{layer: :subject | :global}}}
  def reserve(subject_id, monthly_budget_usd, global_cap_usd, requested_cost_usd, exempt_global?) do
    ensure_loaded(subject_id, :monthly)
    ensure_loaded_global()

    requested = to_micro(requested_cost_usd)

    case hold_counter({subject_id, :monthly}, requested, monthly_budget_usd) do
      {:error, :exhausted} ->
        {:error, {:budget_exceeded, %{layer: :subject}}}

      {:ok, held_monthly} ->
        if exempt_global? do
          {:ok, %{monthly_micro: held_monthly, global_micro: 0, exempt_global?: true}}
        else
          case hold_counter(@global_key, requested, global_cap_usd) do
            {:ok, held_global} ->
              {:ok,
               %{monthly_micro: held_monthly, global_micro: held_global, exempt_global?: false}}

            {:error, :exhausted} ->
              # Roll layer 1 back so the two layers stay consistent.
              bump_counter({subject_id, :monthly}, -held_monthly)
              {:error, {:budget_exceeded, %{layer: :global}}}
          end
        end
    end
  end

  @doc """
  Swaps a hold for the real cost once the request finished.

  Layer 1 and (unless the hold was global-exempt) layer 2 both move from the
  held amount to `actual_cost_usd`. The subject's daily counter (display only,
  never a cap) is bumped by the real cost.
  """
  @spec settle(subject_id :: term(), hold :: map(), actual_cost_usd :: Decimal.t() | nil) :: :ok
  def settle(
        subject_id,
        %{monthly_micro: held_monthly, global_micro: held_global} = hold,
        actual_cost_usd
      ) do
    ensure_loaded(subject_id, :daily)
    ensure_loaded(subject_id, :monthly)

    actual = to_micro(actual_cost_usd)

    bump_counter({subject_id, :monthly}, actual - held_monthly)
    bump_counter({subject_id, :daily}, actual)

    unless hold.exempt_global? do
      bump_counter(@global_key, actual - held_global)
    end

    maybe_enqueue_sync(subject_id)
    unless hold.exempt_global?, do: maybe_enqueue_global_sync()

    :ok
  end

  @doc """
  Releases a hold without recording spend — used when the request never
  produced a cost (provider failure, exception). Exactly one of `settle/3`
  or `release/2` must be called per hold.
  """
  @spec release(subject_id :: term(), hold :: map()) :: :ok
  def release(subject_id, %{monthly_micro: held_monthly, global_micro: held_global} = hold) do
    bump_counter({subject_id, :monthly}, -held_monthly)

    unless hold.exempt_global? do
      bump_counter(@global_key, -held_global)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Public API — credit grants (layer 1 for users)
  # ---------------------------------------------------------------------------

  @doc """
  Holds `requested_cost_usd` against the **first credit grant** (in the given
  order) that still has room, then the global daily cap (layer 2).

  `grants` is the ordered list from `Credits.grants_for/1` — each
  `%{subscription: %Subscription{}, user_id: id, tier: 1 | 2}`, best-first
  (group default before the user's direct credit; soonest-expiry first within a
  tier).

    * empty list → no credit gate (tier 3, unlimited): only the global cap applies;
    * non-empty but every grant exhausted → `{:error, {:budget_exceeded,
      %{layer: :credit}}}`.

  Returns `{:ok, hold}` (fed to `settle_credits/2` / `release_credits/1`) or an
  error tuple. The hold carries `:subscription_id` so the caller can persist
  which grant the request debited.
  """
  @spec reserve_credits([map()], Decimal.t() | nil, Decimal.t() | nil, boolean()) ::
          {:ok, map()} | {:error, {:budget_exceeded, %{layer: :credit | :global}}}
  def reserve_credits(grants, global_cap_usd, requested_cost_usd, exempt_global?) do
    ensure_loaded_global()
    Enum.each(grants, &ensure_grant_loaded/1)

    requested = to_micro(requested_cost_usd)

    case pick_grant(grants) do
      :none ->
        hold_global_only(global_cap_usd, requested, exempt_global?)

      :exhausted ->
        {:error, {:budget_exceeded, %{layer: :credit}}}

      {:ok, grant_key, subscription_id} ->
        held = bump_credit(grant_key, requested)

        hold_global_after(
          grant_key,
          subscription_id,
          held,
          global_cap_usd,
          requested,
          exempt_global?
        )
    end
  end

  @doc "Settles a credit hold to the real cost."
  @spec settle_credits(map(), Decimal.t() | nil) :: :ok
  def settle_credits(%{kind: kind} = hold, actual_cost_usd) do
    actual = to_micro(actual_cost_usd)

    if kind == :credit do
      bump_credit(hold.grant_key, actual - hold.subject_micro)
    end

    unless hold.exempt_global? do
      bump_counter(@global_key, actual - hold.global_micro)
      maybe_enqueue_global_sync()
    end

    :ok
  end

  @doc "Releases a credit hold without recording spend."
  @spec release_credits(map()) :: :ok
  def release_credits(%{kind: kind} = hold) do
    if kind == :credit do
      bump_credit(hold.grant_key, -hold.subject_micro)
    end

    unless hold.exempt_global? do
      bump_counter(@global_key, -hold.global_micro)
    end

    :ok
  end

  @doc "Consumo/crédito vigentes de un grant (display). `nil` si no está cargado."
  def credit_spend(subscription_id, user_id) do
    key = {:grant, subscription_id, user_id}

    case :ets.lookup(@credits_table, key) do
      [{^key, consumed, credited, _cycle_start, _loaded?, _units, _granting?}] ->
        %{
          consumed_micro: consumed,
          credited_micro: credited,
          remaining_micro: max(0, credited - consumed)
        }

      _ ->
        nil
    end
  end

  # Layer-2-only hold (no credit gate): tier 3 (unlimited) subjects.
  defp hold_global_only(global_cap_usd, requested, exempt_global?) do
    if exempt_global? do
      {:ok, no_credit_hold(0, true)}
    else
      case hold_counter(@global_key, requested, global_cap_usd) do
        {:ok, held_global} -> {:ok, no_credit_hold(held_global, false)}
        {:error, :exhausted} -> {:error, {:budget_exceeded, %{layer: :global}}}
      end
    end
  end

  defp no_credit_hold(held_global, exempt_global?) do
    %{
      kind: :no_credit,
      grant_key: nil,
      subscription_id: nil,
      subject_micro: 0,
      global_micro: held_global,
      exempt_global?: exempt_global?
    }
  end

  # Layer 2 after a successful grant hold; rolls the grant back if the global
  # layer is exhausted so the two stay consistent.
  defp hold_global_after(
         grant_key,
         subscription_id,
         held,
         global_cap_usd,
         requested,
         exempt_global?
       ) do
    if exempt_global? do
      {:ok, credit_hold(grant_key, subscription_id, held, 0, true)}
    else
      case hold_counter(@global_key, requested, global_cap_usd) do
        {:ok, held_global} ->
          {:ok, credit_hold(grant_key, subscription_id, held, held_global, false)}

        {:error, :exhausted} ->
          bump_credit(grant_key, -held)
          {:error, {:budget_exceeded, %{layer: :global}}}
      end
    end
  end

  defp credit_hold(grant_key, subscription_id, held, held_global, exempt_global?) do
    %{
      kind: :credit,
      grant_key: grant_key,
      subscription_id: subscription_id,
      subject_micro: held,
      global_micro: held_global,
      exempt_global?: exempt_global?
    }
  end

  # First grant (in order) with room: consumed < credited.
  defp pick_grant([]), do: :none

  defp pick_grant(grants) do
    case Enum.find(grants, &grant_has_room?/1) do
      nil -> :exhausted
      grant -> {:ok, grant_key(grant), grant.subscription.id}
    end
  end

  defp grant_has_room?(grant) do
    key = grant_key(grant)

    # Object is {key, consumed, credited, cycle_start, loaded?, units, granting?}
    # — pos 2 = consumed, 3 = credited.
    read_credit(key, 2) < read_credit(key, 3)
  end

  # Grant ETS key: user grants are (subscription, user_id), service grants
  # (subscription, service_id) — each service drains its own pocket even when
  # several services share one subscription.
  defp grant_key(%{subscription: subscription, service_id: service_id})
       when service_id != nil,
       do: {:grant, subscription.id, {:service, service_id}}

  defp grant_key(%{subscription: subscription, user_id: user_id}),
    do: {:grant, subscription.id, user_id}

  defp read_credit(key, position) do
    :ets.lookup_element(@credits_table, key, position, 0)
  end

  # Bump position 2 (consumed_micro). The default object covers the rare race
  # where the entry was evicted between ensure and here. Positions 2/3 (consumed,
  # credited) must stay put — `read_credit/2` and `pick_grant/1` index them.
  defp bump_credit(key, inc) when is_integer(inc) do
    default = {key, 0, 0, nil, false, 0, false}
    :ets.update_counter(@credits_table, key, {2, inc}, default)
  end

  defp ensure_grant_loaded(%{subscription: subscription} = grant) do
    key = grant_key(grant)
    current_start = current_cycle_start(subscription)

    case :ets.lookup(@credits_table, key) do
      [{^key, _consumed, _credited, cycle_start, true, seeded_units, seeded_granting?}] ->
        # La frescura incluye si la sub otorga crédito, comparado en las DOS
        # direcciones: pausar/vencer no cambia el ciclo ni `units`, así que sin
        # este chequeo una entrada ya sembrada seguía sirviendo el crédito viejo
        # (y al reactivar la sub se quedaba en 0, bloqueando a un miembro con
        # suscripción vigente).
        if cycle_start == current_start and seeded_units == subscription.units and
             seeded_granting? == Tokengate.Credits.grants_credit?(subscription) do
          :ok
        else
          seed_grant(subscription, grant, key)
        end

      _ ->
        seed_grant(subscription, grant, key)
    end
  end

  defp seed_grant(subscription, grant, key) do
    state = Tokengate.Credits.grant_state(subscription, grant_subject(grant))

    GenServer.call(
      __MODULE__,
      {:seed_grant, key, state.consumed_micro, state.credited_micro, state.cycle_start,
       subscription.units, Tokengate.Credits.grants_credit?(subscription)}
    )
  end

  # The subject whose spend a grant debits: the service for service grants,
  # the user for member grants.
  defp grant_subject(%{service_id: service_id}) when service_id != nil,
    do: {:service, service_id}

  defp grant_subject(%{user_id: user_id}), do: user_id

  defp current_cycle_start(subscription) do
    %{start: start} = Tokengate.Credits.cycle_bounds(subscription, Date.utc_today())
    start
  end

  @doc """
  Returns the current daily and monthly spend for `subject_id` as Decimals
  (USD), converting from the internal micro-USD representation.

  Triggers a lazy load from the DB if the entry is missing or stale (day/month
  rollover). The DB read happens in the caller; the GenServer then seeds the
  entry (see `load_from_db/2` and `seed/3`).
  """
  @spec spend(subject_id :: term()) :: %{daily_usd: Decimal.t(), monthly_usd: Decimal.t()}
  def spend(subject_id) do
    ensure_loaded(subject_id, :daily)
    ensure_loaded(subject_id, :monthly)

    %{
      daily_usd: from_micro(read_counter({subject_id, :daily})),
      monthly_usd: from_micro(read_counter({subject_id, :monthly}))
    }
  end

  # ---------------------------------------------------------------------------
  # Global daily counter (display)
  # ---------------------------------------------------------------------------

  @doc """
  Start of the current UTC day as a `DateTime.t()` — the kill-switch day
  boundary (`GlobalSettings.daily_max_spend_usd` resets at 00:00 UTC).
  Shared by the Manager seed and display callers so both agree on the
  window.
  """
  @spec utc_day_start() :: DateTime.t()
  def utc_day_start, do: period_start(:daily)

  @doc """
  Returns the total daily spend across every member and credential (UTC day)
  in USD as a Decimal. Lazy-loads from the DB on first touch or day rollover.

  NOTE (display): this is the raw enforcement counter — while requests are
  in flight it includes the `$max_request_cost_usd` holds reserved by
  `reserve_credits/4` and not yet settled, so the value "breathes" with
  concurrent traffic. Use for enforcement, not for spend dashboards: both
  `/stats` and the maintenance screen display real spend from `request_logs`
  (`Budgets.global_daily_budget_summary/0`); maintenance additionally shows
  this counter as a drift reference when the two disagree.
  """
  @spec global_daily_spend() :: Decimal.t()
  def global_daily_spend do
    ensure_loaded_global()
    from_micro(read_counter(@global_key))
  end

  @doc """
  Resets the global daily ETS counter to the micro-USD value recomputed
  from the DB by `Budgets.SyncWorker`.
  """
  @spec set_global_from_db(integer()) :: :ok
  def set_global_from_db(daily_micro) do
    GenServer.call(__MODULE__, {:set_global_from_db, daily_micro})
  end

  @doc """
  Resets the monthly ETS counter for `subject_id` to the given micro-USD value,
  as recomputed by `Budgets.SyncWorker` from the DB.

  Marks the entry as `loaded_from_db?: true` and stamps the current month so it
  is not considered stale on the next read.
  """
  @spec set_from_db(subject_id :: term(), monthly_micro :: integer()) :: :ok
  def set_from_db(subject_id, monthly_micro) do
    GenServer.call(__MODULE__, {:set_from_db, subject_id, monthly_micro})
  end

  @doc """
  Seeds a single period entry for `subject_id` from a precomputed micro-USD
  value (typically the result of `load_from_db/2`).

  This is the GenServer-side companion to `load_from_db/2`: the caller reads
  from the DB and passes the integer micro-USD here so the singleton never
  touches the repo.
  """
  @spec seed(subject_id :: term(), period :: :daily | :monthly, micro :: integer()) :: :ok
  def seed(subject_id, period, micro) do
    GenServer.call(__MODULE__, {:seed, subject_id, period, micro})
    # Clear the single-flight loading marker now that the real entry is in
    # place (see `seed_from_db_single_flight/3`). Idempotent — the marker may
    # already have been removed by the caller's `after` block.
    :ets.delete(@table, {:loading, {subject_id, period}})
    :ok
  end

  @doc """
  Loads the spend for `subject` over the given period from the DB and returns
  it as integer micro-USD.

  `subject` is a member id or a service id (both binary). This reads
  `total_cost_usd` — what TokenGate actually paid — so the budget counters stay
  in the same currency as the dashboard's "Costo real".

  Intended to be called from the **caller process** (not the GenServer) to keep
  DB I/O out of the singleton. The returned value is then handed to `seed/3`.

  `from` is a `DateTime.t()` marking the start of the period (e.g. start of
  today for daily, start of month for monthly).
  """
  @spec load_from_db(subject :: term(), from :: DateTime.t()) :: integer()
  def load_from_db(subject, from) do
    filters = %{subject_id: subject, from: from}
    summary = Tokengate.Logs.cost_summary(filters)
    to_micro(summary.total_cost_usd)
  end

  @doc """
  Real spend of the **whole instance** (every member and service) over
  `from`, as integer micro-USD — the durable counterpart of the global daily
  counter.

  Unlike `load_from_db/2` this applies NO subject filter, so it is the right
  seed source for `{:global, :daily}`. Passing `:global` to `load_from_db/2`
  instead raises `Ecto.Query.CastError` (it casts an atom against the binary_id
  `group_member_id` column), so the global path needs its own loader.

  Intended to be called from the caller process (not the GenServer) to keep
  DB I/O out of the singleton, then handed to `set_global_from_db/1`.
  """
  @spec load_global_from_db(from :: DateTime.t()) :: integer()
  def load_global_from_db(from) do
    summary = Tokengate.Logs.cost_summary(%{from: from})
    to_micro(summary.total_cost_usd)
  end

  @doc """
  Deletes every `{subject_id, :monthly}` entry from the ETS table.

  Called by `Budgets.ResetWorker` on the 1st of each month. The next
  `reserve/5` or `spend/1` for each subject will lazy-load from DB, which
  effectively starts the monthly counter at 0.
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
    ensure_credits_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:seed, subject_id, period, micro}, _from, state) do
    key = {subject_id, period}
    obj = {key, micro, true, current_period_stamp(period)}
    :ets.insert(@table, obj)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_from_db, subject_id, monthly_micro}, _from, state) do
    :ets.insert(
      @table,
      {{subject_id, :monthly}, monthly_micro, true, current_period_stamp(:monthly)}
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

  @impl true
  def handle_call(
        {:seed_grant, key, consumed_micro, credited_micro, cycle_start, units, granting?},
        _from,
        state
      ) do
    :ets.insert(
      @credits_table,
      {key, consumed_micro, credited_micro, cycle_start, true, units, granting?}
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

  # Grants table. Object:
  # {key, consumed_micro, credited_micro, cycle_start, loaded?, units, granting?}
  # where key = {:grant, subscription_id, user_id}. `granting?` es si la sub
  # otorgaba crédito al sembrar: forma parte de la frescura (junto a
  # `cycle_start` y `units`) porque pausar/vencer/reactivar no cambia ninguno de
  # los otros dos. Separate from `:tokengate_budgets` so the legacy 4-tuples stay
  # untouched.
  defp ensure_credits_table do
    if :ets.whereis(@credits_table) == :undefined do
      :ets.new(@credits_table, [
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
  # Internal — ensure loaded / stale check
  # ---------------------------------------------------------------------------

  # Ensures the entry for (subject_id, period) exists and is current. If it is
  # missing or the stored day/month no longer matches today, we re-seed from the
  # DB. The DB read happens in the caller (this process), then the GenServer
  # seeds the entry — keeping DB I/O out of the singleton.
  defp ensure_loaded(subject_id, period) do
    key = {subject_id, period}
    current = current_period_stamp(period)

    case :ets.lookup(@table, key) do
      [] ->
        seed_from_db_single_flight(subject_id, period, key)

      [{^key, _micro, _loaded?, stored_period}] ->
        if stale?(period, stored_period, current) do
          seed_from_db_single_flight(subject_id, period, key)
        else
          :ok
        end
    end
  end

  defp stale?(:daily, stored_day, today), do: stored_day != today

  defp stale?(:monthly, {y, m}, {ty, tm}), do: y != ty or m != tm

  # Ensures the global daily entry exists and is current. Same lazy-load pattern
  # as per-subject entries but keyed by @global_key. Degrades gracefully if the
  # ETS table doesn't exist yet (hot-reload).
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
    micro = load_global_from_db(from)
    GenServer.call(__MODULE__, {:seed_global, micro})
  end

  defp seed_from_db(subject_id, period) do
    from = period_start(period)
    micro = load_from_db(subject_id, from)
    seed(subject_id, period, micro)
  end

  # Single-flight wrapper around `seed_from_db/2`: concurrent callers for the
  # same key (thundering herd on a brand-new subject or day rollover) park on the
  # ETS `{:loading, key}` marker instead of all hitting the DB at once. The
  # marker is removed in the `after` block (crash-safe) and again in `seed/3`
  # after the real entry is inserted (idempotent no-op).
  defp seed_from_db_single_flight(subject_id, period, key) do
    loading_key = {:loading, key}

    case :ets.insert_new(@table, {loading_key, true}) do
      true ->
        try do
          seed_from_db(subject_id, period)
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
  # proceeds anyway — `bump_counter` / `read_counter` tolerate a missing entry,
  # so worst case we seed from 0 for this request.
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
  # Internal — counter read / bump / hold
  # ---------------------------------------------------------------------------

  defp read_counter(key) do
    # Position 2 = amount_micro. Default 0 when key missing.
    :ets.lookup_element(@table, key, 2, 0)
  end

  # Bumps position 2 (amount_micro) by `inc` and returns the NEW counter value.
  # The default object covers the rare race where the entry was evicted between
  # ensure_loaded and here.
  defp bump_counter(key, inc) when is_integer(inc) do
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

  # Optimistic hold on `key`: bump first, then decide. `nil` cap = unlimited →
  # hold nothing and never reject. Otherwise, reject iff the value BEFORE this
  # bump was already at/over the cap (the "already exhausted" gate); a single
  # request over the remaining headroom is still held (it is a hold, and
  # `settle/3` corrects it), but it blocks the next concurrent one.
  defp hold_counter(_key, _requested, nil), do: {:ok, 0}

  defp hold_counter(key, requested, cap) do
    limit = to_micro(cap)
    new = bump_counter(key, requested)

    if new - requested >= limit do
      bump_counter(key, -requested)
      {:error, :exhausted}
    else
      {:ok, requested}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — debounced SyncWorker enqueue
  # ---------------------------------------------------------------------------

  defp maybe_enqueue_sync(subject_id) do
    key = {:sync_pending, subject_id}

    if :ets.insert_new(@table, {key, true}) do
      _ =
        %{subject_id: subject_id}
        |> Tokengate.Budgets.SyncWorker.new()
        |> Oban.insert()
    end

    :ok
  end

  # Debounced enqueue of the GLOBAL counter reconciler. Same pattern as
  # `maybe_enqueue_sync/1`, with a fixed marker key (the job carries no args).
  # Without this the global kill-switch counter only ever moves by hold/settle
  # and keeps phantom ceilings from crashed requests for the whole UTC day.
  defp maybe_enqueue_global_sync do
    key = {:sync_pending, :global}

    if :ets.insert_new(@table, {key, true}) do
      _ =
        %{}
        |> Tokengate.Budgets.GlobalSyncWorker.new()
        |> Oban.insert()
    end

    :ok
  end

  @doc false
  def clear_global_sync_pending do
    :ets.delete(@table, {:sync_pending, :global})
    :ok
  end

  @doc false
  def clear_sync_pending(subject_id) do
    :ets.delete(@table, {:sync_pending, subject_id})
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
end
