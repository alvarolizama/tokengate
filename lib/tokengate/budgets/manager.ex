defmodule Tokengate.Budgets.Manager do
  @moduledoc """
  ETS-backed micro-USD spend cache for budget enforcement.

  One budget layer, one reserve primitive:

  - **Monthly per subject** (`{subject_id, :monthly}`): the member's or
    service's effective monthly budget (group default + extra). `nil` =
    unlimited.
  - **Spend plan** (credits): the subject's monthly limit plus its top-ups,
    reserved through `reserve_plan/2`.

  ## Table

  - `:tokengate_budgets` — a single public, named ETS `:set` table with
    `write_concurrency: true`. Objects are flat 4-tuples:

      {key, amount_micro, loaded_from_db?, period_stamp}

    - `key` — `{subject_id, :monthly}` or `{subject_id, :daily}` (display).
    - `amount_micro` — integer micro-USD, the counter element (position 2),
      updated atomically via `:ets.update_counter/4`.
    - `loaded_from_db?` — boolean (position 3); `true` once seeded from DB.
    - `period_stamp` — `Date.t()` for daily, `{year, month}` for monthly
      (position 4); used to detect day/month rollover.

  ## Enforcement model: reserve → settle

  The durable truth is `request_logs`; this ETS cache is a hot replica. A
  request **reserves** (holds) an amount before it executes and **settles**
  the hold to the real cost when it finishes. Holding before the cost is
  known is what stops N concurrent requests from jointly blowing past a cap:
  each request holds its share first (see `reserve/3`).

  ## API summary

    * `reserve/3` — pre-flight hold on the subject's monthly cap (rejects if
      exhausted).
    * `settle/3` — swap the hold for the real cost after the request.
    * `release/2` — release a hold when the request never settled (error path).
    * `spend/1` — read-back of current daily/monthly spend in USD (display).
    * `set_from_db/2` — `Budgets.SyncWorker` drift reset.
    * `reset_monthly_counters/0` — `Budgets.ResetWorker` monthly reset.
    * `seed/3` / `load_from_db/2` — lazy-load helpers.

  `nil` budget means unlimited for the layer.
  """

  use GenServer

  require Logger

  @table :tokengate_budgets
  @credits_table :tokengate_credits
  @micro 1_000_000

  # ---------------------------------------------------------------------------
  # Public API — enforcement
  # ---------------------------------------------------------------------------

  @doc """
  Reserves budget for an in-flight request against the subject's monthly
  counter (cap = `monthly_budget_usd`). Rejects when the layer is already
  exhausted, so N concurrent requests cannot jointly blow past the cap.

  Optimistic and atomic: `:ets.update_counter/4` bumps first and returns the
  new value, so the "already exhausted" decision needs no lock. The held
  amount may transiently push the counter above its cap; `settle/3` corrects it.

  `monthly_budget_usd == nil` (unlimited) holds nothing and never rejects.

  Returns `{:ok, hold}` or `{:error, {:budget_exceeded, %{layer: :subject}}}`.
  """
  @spec reserve(
          subject_id :: term(),
          monthly_budget_usd :: Decimal.t() | nil,
          requested_cost_usd :: Decimal.t() | nil
        ) ::
          {:ok, map()} | {:error, {:budget_exceeded, %{layer: :subject}}}
  def reserve(subject_id, monthly_budget_usd, requested_cost_usd) do
    ensure_loaded(subject_id, :monthly)

    requested = to_micro(requested_cost_usd)

    case hold_counter({subject_id, :monthly}, requested, monthly_budget_usd) do
      {:error, :exhausted} ->
        {:error, {:budget_exceeded, %{layer: :subject}}}

      {:ok, held_monthly} ->
        {:ok,
         %{
           monthly_micro: held_monthly,
           period: current_period_stamp(:monthly)
         }}
    end
  end

  @doc """
  Swaps a hold for the real cost once the request finished.

  The monthly counter moves from the held amount to `actual_cost_usd`. The
  subject's daily counter (display only, never a cap) is bumped by the real
  cost.
  """
  @spec settle(subject_id :: term(), hold :: map(), actual_cost_usd :: Decimal.t() | nil) :: :ok
  def settle(subject_id, %{monthly_micro: held_monthly}, actual_cost_usd) do
    ensure_loaded(subject_id, :daily)
    ensure_loaded(subject_id, :monthly)

    actual = to_micro(actual_cost_usd)

    # Legado de una capa, SIN guard por estado: el `ensure_loaded/2` de arriba
    # re-siembra una entrada evictada por un reset ANTES de que un guard pueda
    # verla (el `{:seed, ...}` del GenServer inserta incondicionalmente), así
    # que un guard aquí sería inerte — vería "viva y del mismo ciclo" lo que
    # acaba de renacer. El proxy no pasa por este path (los holds llevan `:kind`
    # y van a `settle_credits/2`); se conserva el comportamiento de siempre.
    bump_counter({subject_id, :monthly}, actual - held_monthly)
    bump_counter({subject_id, :daily}, actual)

    maybe_enqueue_sync(subject_id)

    :ok
  end

  @doc """
  Releases a hold without recording spend — used when the request never
  produced a cost (provider failure, exception). Exactly one of `settle/3`
  or `release/2` must be called per hold.
  """
  @spec release(subject_id :: term(), hold :: map()) :: :ok
  def release(subject_id, %{monthly_micro: held_monthly} = hold) do
    period = Map.get(hold, :period, current_period_stamp(:monthly))

    # El refund no resucita una entrada evictada por un reset (quedaría
    # negativa y bloquearía el re-seed): solo devuelve el delta a la entrada
    # viva de su ciclo.
    if monthly_counter_live?(subject_id, period) do
      bump_counter({subject_id, :monthly}, -held_monthly)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Public API — spend plan (límite del sujeto + top-ups)
  # ---------------------------------------------------------------------------

  @doc """
  Holds `requested_cost_usd` against the subject's **spend plan** (monthly
  limit first, then the top-up that expires soonest).

  `plan` es lo que resuelve `Credits.plan/1`:

      %{subject: {:user, id} | {:service, id},
        limit_usd: Decimal.t() | nil,
        unlimited?: boolean(),
        topups: [%Topup{}, ...]}   # en orden de drenado

  Orden de intento (una sola función, documentado aquí):

    1. `unlimited?` ⇒ no hay tope de sujeto: el hold no retiene nada.
    2. límite con remanente ⇒ se descuenta del límite.
    3. límite agotado (o `0`, o `nil`) y hay top-ups vigentes ⇒ drena el que
       **expira antes**.
    4. sin límite (`nil`) y sin ilimitado ni top-ups ⇒ **402** (`:no_credit`).

  Devuelve `{:ok, hold}` (para `settle_credits/2` / `release_credits/1`) o
  `{:error, {:budget_exceeded, %{layer: :subject | :no_credit}}}`.
  El hold dice **qué se debitó**: `:limit` o `{:topup, id}`.
  """
  @spec reserve_plan(Tokengate.Credits.plan(), Decimal.t() | nil) ::
          {:ok, map()} | {:error, {:budget_exceeded, %{layer: :subject | :no_credit}}}
  def reserve_plan(plan, requested_cost_usd) do
    requested = to_micro(requested_cost_usd)

    result =
      case pick_layer(plan) do
        :unlimited ->
          {:ok, no_credit_hold()}

        {:limit, _subject} ->
          hold_limit(plan, requested)

        {:topup, topup} ->
          hold_topup(plan, topup, requested)

        :no_credit ->
          {:error, {:budget_exceeded, %{layer: :no_credit}}}

        :subject ->
          {:error, {:budget_exceeded, %{layer: :subject}}}
      end

    # Aviso de Telegram en la TRANSICIÓN (un rechazo es raro; el cooldown del
    # evento se encarga de que un tope reventado no mande cientos de mensajes).
    notify_rejection(plan, result)

    # Un rechazo por contador también pide reconciliación: si el contador está
    # inflado por un hold FANTASMA (el proceso del request murió con `:kill`
    # entre el hold y el settle, así que nunca hubo settle que encolara el sync),
    # el sujeto queda con 402 permanente aunque la DB muestre remanente —
    # `ensure_limit_loaded` no re-siembra dentro del mismo ciclo. Debounced, así
    # que un sujeto martillando el tope encola a lo sumo un job por ventana.
    if match?({:error, _}, result), do: maybe_enqueue_credit_sync(plan.subject)

    result
  end

  @doc """
  Settles a plan hold to the real cost. `:topup` holds debit the top-up passed
  in the hold; the top-up row itself is untouched (its consumption is measured
  against `request_logs.credit_topup_id`).
  """
  @spec settle_credits(map(), Decimal.t() | nil) :: :ok
  def settle_credits(%{kind: kind} = hold, actual_cost_usd) do
    actual = to_micro(actual_cost_usd)
    period = Map.get(hold, :period, current_period_stamp(:monthly))

    case kind do
      # Guard por ESTADO del contador (no reloj): la absorción (`actual −
      # held`) solo aplica si la entrada que vio el hold sigue viva y en SU
      # ciclo. Un reset (o un rollover) la evictó ⇒ el settle tardío no toca
      # al contador sobreviviente: el re-seed del SyncWorker desde los logs
      # es el dueño de la verdad. Ni regala crédito ni va a negativos.
      :limit ->
        if credit_counter_live?(hold.grant_key, period) do
          bump_credit(hold.grant_key, actual - hold.subject_micro)
        end

      # Los bolsines de top-up NO son mensuales (el reset no los borra y su
      # `cycle_start` es nil): el settle SIEMPRE aterriza en el bolsín.
      :topup ->
        bump_credit(hold.grant_key, actual - hold.subject_micro)

      :no_credit ->
        :ok
    end

    # Reconciliación del contador del límite/top-up: sin esto, un drift del
    # ETS (crash entre hold y settle, doble release, hold fantasma) quedaba
    # vivo hasta reiniciar el nodo — y como la semilla es una sola vez por
    # ciclo mensual, un contador inflado rechazaba con 402 el resto del mes
    # aunque la DB mostrara crédito restante.
    case hold_subject(hold) do
      nil -> :ok
      subject -> maybe_enqueue_credit_sync(subject)
    end

    :ok
  end

  # Los holds de top-up no cargan `subject` (solo `topup`): la reconciliación
  # de esos bolsines la cubre `ensure_topup_loaded/1` con su semilla por uso.
  defp hold_subject(%{subject: %{} = subject}), do: subject
  defp hold_subject(%{subject: {_type, _id} = subject}), do: subject
  defp hold_subject(_), do: nil

  # El SyncWorker pide un `subject_id` binario (miembro o servicio). Los plans
  # traen `{:user, id} | {:service, id}`; `credit_subject` preserva el tipo
  # para que el worker re-siembre el contador correcto de la tabla de créditos.
  defp subject_key_id({:user, id}), do: id
  defp subject_key_id({:service, id}), do: id

  # Debounced enqueue del reconciliador, variante del plan de créditos: lleva
  # el sujeto TIPADO para que el SyncWorker además re-siembre
  # `{:limit, {:user, id}}` / `{:limit, {:service, id}}` desde la verdad
  # durable. El marcador dedup es el mismo `subject_id` binario.
  # Un plan sin id (`{:user, nil}`) no tiene contador que reconciliar y haría
  # que el worker consultara `IS NULL` (todos los sujetos de servicio).
  defp maybe_enqueue_credit_sync({_type, nil}), do: :ok

  defp maybe_enqueue_credit_sync(subject) do
    id = subject_key_id(subject)
    key = {:sync_pending, id}

    if :ets.insert_new(@table, {key, true}) do
      %{subject_id: id, credit_subject: [to_string(elem(subject, 0)), id]}
      |> Tokengate.Budgets.SyncWorker.new()
      |> Oban.insert()
      |> release_marker_on_failed_enqueue(key)
    end

    :ok
  end

  # Oban deduplica por `unique` (ventana de 60 s): si el job ya existe —o está
  # EJECUTÁNDOSE, que es el caso malo, porque el worker ya limpió el marcador al
  # arrancar— `insert` devuelve el existente sin agendar nada nuevo. Dejar el
  # marcador puesto ahí mataba la reconciliación de ese sujeto para siempre:
  # ningún settle futuro volvía a encolar. Se suelta el marcador para que el
  # próximo settle reintente cuando expire la ventana.
  defp release_marker_on_failed_enqueue({:ok, %Oban.Job{conflict?: false}}, _key), do: :ok
  defp release_marker_on_failed_enqueue({:ok, _job}, key), do: :ets.delete(@table, key)
  defp release_marker_on_failed_enqueue({:error, _reason}, key), do: :ets.delete(@table, key)

  @doc """
  Re-siembra el contador mensual del límite de un sujeto (tabla de créditos,
  clave `{:limit, subject}`) desde el log durable: lo gastado **debitado al
  límite** este mes (logs sin top-up).

  Es la corrección de drift que faltaba: `ensure_limit_loaded/1` solo siembra
  una vez por ciclo, así que un contador inflado (crash entre hold y settle,
  rollback duplicado) bloqueaba con 402 el resto del mes aunque la DB
  mostrara remanente. La llama el `SyncWorker` después de cada settle del
  plan de créditos (debounced).
  """
  @spec reseed_limit_counter(Tokengate.Credits.subject()) :: :ok
  def reseed_limit_counter(subject) do
    key = limit_key(subject)
    consumed = Tokengate.Credits.spend_debited_to_limit(subject)

    seed_credit_force(key, to_micro(consumed), nil, current_period_stamp(:monthly), nil, true)
  end

  @doc """
  Releases a plan hold without recording spend.
  """
  @spec release_credits(map()) :: :ok
  def release_credits(%{kind: kind} = hold) do
    period = Map.get(hold, :period, current_period_stamp(:monthly))

    if kind in [:limit, :topup] do
      # Mismo guard que el settle: el refund de un `:limit` no resucita una
      # entrada evictada por un reset (quedaría negativa); los bolsines
      # `:topup` siempre aterrizan (no son mensuales).
      refund? = kind == :topup or credit_counter_live?(hold.grant_key, period)

      if refund? do
        bump_credit(hold.grant_key, -hold.subject_micro)
      end
    end

    :ok
  end

  # Which layer the plan debits, in order. `:subject` = el límite existe y está
  # agotado (o en cero); `:no_credit` = no hay límite, ni ilimitado, ni top-up
  # utilizable (bloqueado de verdad).
  #
  # Importante: antes de decidir hay que **sembrar** los contadores desde la
  # verdad durable (`ensure_limit_loaded/1`, `ensure_topup_loaded/1`). Un
  # contador vacío en ETS lee 0 — con límite 0 o agotado eso elegiría la capa
  # equivocada y dejaría gastar al sujeto.
  defp pick_layer(%{unlimited?: true}), do: :unlimited

  defp pick_layer(%{limit_usd: limit} = plan) when is_struct(limit, Decimal) do
    subject = plan.subject
    key = limit_key(subject)
    ensure_limit_loaded(subject)

    # `0` = CERO (jamás ilimitado): no hay límite disponible, así que este plan
    # solo puede seguir por top-ups y, si no hay, queda `:subject`.
    if Decimal.compare(limit, 0) == :gt and read_credit(key, 2) < to_micro(limit) do
      {:limit, subject}
    else
      limit_exhausted(plan)
    end
  end

  defp pick_layer(%{limit_usd: nil} = plan), do: topups_only(plan, :no_credit)

  # El límite existe pero está agotado (o en cero): top-ups o `:subject`.
  defp limit_exhausted(plan), do: topups_only(plan, :subject)

  # Solo top-ups: el primero (orden de drenado) con remanente. Sin ninguno
  # utilizable, la capa que corresponda (`:subject` si había límite,
  # `:no_credit` si no había ninguno).
  defp topups_only(%{topups: []}, fallback), do: fallback

  defp topups_only(%{topups: topups}, fallback) do
    Enum.each(topups, &ensure_topup_loaded/1)

    case Enum.find(topups, &topup_has_room?/1) do
      nil -> fallback
      topup -> {:topup, topup}
    end
  end

  defp topup_has_room?(topup) do
    key = topup_key(topup)
    read_credit(key, 2) < to_micro(topup.amount_usd)
  end

  # Limit hold: the subject's own monthly counter (daily/monthly counters live
  # in the other table and are unrelated).
  #
  # `subject_micro` del hold es el DELTA retenido (`requested`), no el total
  # del contador tras el bump: settle/release restan exactamente eso. Cuando
  # guardábamos el total nuevo, el settle (`actual − total`) colapsaba el
  # contador al costo de la última request y el release (`−total`) lo mandaba
  # a 0 — se perdía el gasto acumulado del mes y el contador quedaba basura
  # en ambas direcciones (402 con crédito restante, o gasto de más).
  #
  # Gate atómico, espejo de `hold_counter/3`: bump primero y decisión contra
  # el valor ANTES de este bump (`new − requested >= tope` ⇒ el contador ya
  # estaba en/sobre el techo). El read de `pick_layer` solo ELIGE la capa;
  # aquí se re-valida sin ventana de carrera. Un pedido mayor al remanente
  # sigue pasando (es un hold; el settle lo corrige) pero bloquea al
  # siguiente concurrente. En rechazo: rollback del delta y caída a top-ups
  # con la misma capa de rechazo que dicta `limit_exhausted/1`.
  defp hold_limit(plan, requested) do
    subject = plan.subject
    key = limit_key(subject)
    ensure_limit_loaded(subject)

    new = bump_credit(key, requested)

    if new - requested >= to_micro(plan.limit_usd) do
      bump_credit(key, -requested)

      case topups_only(plan, :subject) do
        {:topup, topup} ->
          hold_topup(plan, topup, requested)

        :subject ->
          {:error, {:budget_exceeded, %{layer: :subject}}}
      end
    else
      {:ok,
       credit_hold(
         %{kind: :limit, grant_key: key, subject: subject, limit_usd: plan.limit_usd},
         requested
       )}
    end
  end

  # Top-up hold: mismo gate atómico contra el techo del bolsín. En rechazo:
  # rollback del delta y re-elección entre los bolsines restantes (`fallback`
  # = `:subject` si el plan tenía límite, `:no_credit` si no). Sin loop: tras
  # el rollback el bolsín queda en/sobre su amount, así que
  # `topup_has_room?/1` lo excluye naturalmente de la re-elección.
  defp hold_topup(plan, topup, requested) do
    key = topup_key(topup)
    ensure_topup_loaded(topup)

    new = bump_credit(key, requested)

    if new - requested >= to_micro(topup.amount_usd) do
      bump_credit(key, -requested)
      fallback = if plan.limit_usd != nil, do: :subject, else: :no_credit

      case topups_only(plan, fallback) do
        {:topup, next} ->
          hold_topup(plan, next, requested)

        layer when layer in [:subject, :no_credit] ->
          {:error, {:budget_exceeded, %{layer: layer}}}
      end
    else
      {:ok, credit_hold(%{kind: :topup, grant_key: key, topup: topup}, requested)}
    end
  end

  defp credit_hold(partial, held) do
    Map.merge(partial, %{
      subject_micro: held,
      # Stamps de período capturados AL RESERVAR: el guard de settle/release
      # compara contra el ESTADO del contador (entrada viva + mismo ciclo),
      # no contra el reloj (que no se mueve en un reset).
      period: current_period_stamp(:monthly)
    })
  end

  # ---------------------------------------------------------------------------
  # Internal — Telegram aviso en el rechazo
  # ---------------------------------------------------------------------------

  defp notify_rejection(plan, result) do
    case result do
      {:error, {:budget_exceeded, %{layer: layer}}} when layer in [:subject, :no_credit] ->
        event = if layer == :no_credit, do: :no_credit, else: :subject_limit_reached

        Tokengate.Notifications.emit(event, %{
          entity_type: "subject",
          entity_id: subject_key(plan),
          target_label: subject_key(plan)
        })

      _ ->
        :ok
    end
  end

  defp subject_key(%{subject: {:user, id}}), do: "user:" <> to_string(id)
  defp subject_key(%{subject: {:service, id}}), do: "service:" <> to_string(id)
  defp subject_key(_), do: "subject"

  # ETS keys: the subject's limit counter and each top-up's own pocket.
  defp limit_key({:user, user_id}), do: {:limit, {:user, user_id}}
  defp limit_key({:service, service_id}), do: {:limit, {:service, service_id}}
  defp topup_key(%{id: id}), do: {:topup, id}

  # ---------------------------------------------------------------------------
  # Seeds
  # ---------------------------------------------------------------------------

  # The limit counter seeds from the durable log: what the subject already spent
  # against its limit this month (top-up debits don't count against the limit).
  #
  # Es **mensual**: se re-siembra cuando el ciclo guardado no es el mes en curso.
  # Antes solo se sembraba si la clave no existía, y `cycle_start` se guardaba
  # `nil` y no se leía en ningún sitio — así que un sujeto que agotó su límite
  # un mes quedaba bloqueado (402 `:subject`) todo el mes siguiente, con gasto 0,
  # hasta reiniciar el nodo (que es lo único que vaciaba la tabla ETS).
  defp ensure_limit_loaded(subject) do
    key = limit_key(subject)
    cycle = current_period_stamp(:monthly)

    if limit_stale?(key, cycle) do
      consumed = Tokengate.Credits.spend_debited_to_limit(subject)
      seed_credit(key, to_micro(consumed), nil, cycle, nil, true)
    end
  end

  defp limit_stale?(key, cycle) do
    case :ets.lookup(@credits_table, key) do
      [] ->
        true

      [{^key, _consumed, _credited, stored_cycle, _loaded?, _units, _granting?}] ->
        stored_cycle != cycle
    end
  end

  # A top-up pocket seeds from the log attribution for that top-up.
  defp ensure_topup_loaded(topup) do
    key = topup_key(topup)

    if :ets.lookup(@credits_table, key) == [] do
      consumed = Tokengate.Credits.Topups.consumed_usd(topup)
      seed_credit(key, to_micro(consumed), to_micro(topup.amount_usd), nil, nil, false)
    end
  end

  # Semilla perezosa (ensure_*): NUNCA pisa un contador vivo del ciclo en
  # curso. La decisión "stale" se tomó antes de que bumps concurrentes
  # aterrizaran y el `:ets.insert` incondicional los borraba (cold-start
  # race: N procesos ven la clave ausente, todos leen la DB, todos insertan
  # el valor de DB encima del gasto ya cargado). El guard del handle_call
  # decide; un contador vivo del ciclo gana sobre la semilla perezosa.
  defp seed_credit(key, consumed_micro, credited_micro, cycle_start, units, granting?) do
    GenServer.call(
      __MODULE__,
      {:seed_credit, key, consumed_micro, credited_micro, cycle_start, units, granting?, false}
    )
  end

  # Variante forzada (re-seed del SyncWorker desde la verdad durable de los
  # logs): SÍ puede sobrescribir un contador vivo del mismo ciclo — es LA
  # corrección de drift (crash entre hold y settle, rollback duplicado).
  defp seed_credit_force(key, consumed_micro, credited_micro, cycle_start, units, granting?) do
    GenServer.call(
      __MODULE__,
      {:seed_credit, key, consumed_micro, credited_micro, cycle_start, units, granting?, true}
    )
  end

  @doc """
  Gasto del mes **debitado al límite** de un sujeto, desde el contador ETS
  (display/tests). `subject` es `{:user, id}` o `{:service, id}`.

  Devuelve `%{consumed_micro: n}` o `nil` si el contador no está cargado. Lo
  sembrado son los logs sin top-up: es lo que consume `monthly_spend_limit_usd`.
  """
  @spec limit_spend(Tokengate.Credits.subject()) :: %{consumed_micro: integer()} | nil
  def limit_spend(subject) do
    key = limit_key(subject)

    case :ets.lookup(@credits_table, key) do
      [{^key, consumed, _credited, _cycle_start, _loaded?, _units, _granting?}] ->
        %{consumed_micro: consumed}

      _ ->
        nil
    end
  end

  @doc """
  Consumo de un top-up desde su bolsín ETS. `nil` si no está cargado.
  """
  @spec topup_spend(term()) :: %{consumed_micro: integer()} | nil
  def topup_spend(topup_id) do
    key = {:topup, topup_id}

    case :ets.lookup(@credits_table, key) do
      [{^key, consumed, _credited, _cycle_start, _loaded?, _units, _granting?}] ->
        %{consumed_micro: consumed}

      _ ->
        nil
    end
  end

  # Pass-through hold: unlimited subjects have no subject gate to charge, so
  # the hold covers only `:no_credit` (nothing is retained) and the request
  # proceeds.
  defp no_credit_hold do
    %{
      kind: :no_credit,
      grant_key: nil,
      subject: nil,
      topup: nil,
      subject_micro: 0,
      period: current_period_stamp(:monthly)
    }
  end

  # ---------------------------------------------------------------------------
  # Internal — credit table read/bump
  # ---------------------------------------------------------------------------

  # Object: {key, consumed, credited, cycle_start, loaded?, units, granting?}
  # — pos 2 = consumed, pos 3 = credited. Default 0 when the key is missing.
  defp read_credit(key, position) do
    :ets.lookup_element(@credits_table, key, position, 0)
  end

  # Bumps position 2 (consumed_micro) by `inc` and returns the NEW value. The
  # default object covers the rare race where the entry was evicted between the
  # ensure and here. Positions 2/3 must stay put — `read_credit/2` indexes them.
  defp bump_credit(key, inc) when is_integer(inc) do
    default = {key, 0, 0, nil, false, 0, false}
    :ets.update_counter(@credits_table, key, {2, inc}, default)
  end

  # ---------------------------------------------------------------------------
  # Internal — guards de settle/release por ESTADO del contador
  # ---------------------------------------------------------------------------

  # Guard del contador de créditos (pos 4 = `cycle_start` en ambas formas de
  # la entrada): la entrada existe y su ciclo coincide con el del hold.
  # Ausente ⇒ un reset la evictó; distinto ⇒ hubo rollover. En ambos casos el
  # contador sobreviviente (o el re-seed desde logs) es la verdad y el
  # settle/release tardío no lo toca.
  defp credit_counter_live?(key, period) do
    :ets.lookup_element(@credits_table, key, 4, :missing) == period
  end

  # Guard mensual del camino legacy (@table, pos 4 = {y, m} guardado).
  defp monthly_counter_live?(subject_id, period) do
    :ets.lookup_element(@table, {subject_id, :monthly}, 4, :missing) == period
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
  # UTC day boundary (display)
  # ---------------------------------------------------------------------------

  @doc """
  Start of the current UTC day as a `DateTime.t()`.

  Shared by the daily seed and display callers so both agree on the window.
  """
  @spec utc_day_start() :: DateTime.t()
  def utc_day_start, do: period_start(:daily)

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
  Deletes every spend counter from the ETS table: monthly AND daily, per
  subject. Used by the maintenance reset (`Logs.truncate_request_logs/0`)
  and by `Budgets.ResetWorker` on cycle boundaries. The next
  `reserve/3` or `spend/1` for each subject lazy-loads from DB, which
  effectively starts each counter at 0.
  """
  @spec reset_monthly_counters() :: integer()
  def reset_monthly_counters do
    # Every entry of the spend table: {subject, :monthly} and {subject, :daily}.
    spend =
      :ets.select_delete(@table, [
        {{{:_, :monthly}, :_, :_, :_}, [], [true]},
        {{{:_, :daily}, :_, :_, :_}, [], [true]}
      ])

    # El contador del límite mensual vive en **otra** tabla (`@credits_table`,
    # clave `{:limit, subject}`) y no se borraba aquí: quedaba con el consumo del
    # mes anterior hasta reiniciar el nodo. El `cycle_start` ya lo invalida de
    # forma perezosa (ver `ensure_limit_loaded/1`); este borrado además deja el
    # display correcto sin esperar a la primera request del mes.
    #
    # OJO: los bolsines `{:topup, id}` NO se borran aquí a propósito — el consumo
    # de un top-up no es mensual (es de un solo uso con expiración propia), así
    # que el ciclo mensual debe conservarlos. El reset de Mantenimiento
    # (`clear_topup_counters/0` desde `Logs.truncate_request_logs/0`) sí los
    # borra: con los logs truncados, ese consumo ya no existe.
    credits =
      if :ets.whereis(@credits_table) == :undefined do
        0
      else
        :ets.select_delete(@credits_table, [
          {{{:limit, :_}, :_, :_, :_, :_, :_, :_}, [], [true]}
        ])
      end

    spend + credits
  end

  @doc """
  Deletes every top-up pocket (`{:topup, id}`) from the credits ETS table.

  Sólo para el reset de Mantenimiento (`Logs.truncate_request_logs/0`): el
  consumo de un top-up se mide contra `request_logs`, así que con la tabla
  truncada un bolsín con consumo pre-reset quedaría congelado hasta reiniciar
  el nodo — y como `ensure_topup_loaded/1` sólo siembra cuando la clave no
  existe, el enforcement seguiría viendo gasto inexistente (402 contra un
  top-up con saldo limpio). Tras el borrado, el siguiente uso re-siembra desde
  la DB (ya vacía) en 0. El ciclo mensual del `ResetWorker` NO llama esto.
  """
  @spec clear_topup_counters() :: integer()
  def clear_topup_counters do
    if :ets.whereis(@credits_table) == :undefined do
      0
    else
      :ets.select_delete(@credits_table, [
        {{{:topup, :_}, :_, :_, :_, :_, :_, :_}, [], [true]}
      ])
    end
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
  def handle_call(
        {:seed_credit, key, consumed_micro, credited_micro, cycle_start, units, granting?,
         force?},
        _from,
        state
      ) do
    # Guard anti-clobber: escribe solo si la clave falta (primera siembra),
    # su ciclo guardado difiere del entrante (re-siembra legítima de
    # rollover) o la semilla es forzada (re-seed del SyncWorker). Un contador
    # VIVO del ciclo en curso gana sobre la semilla perezosa.
    write? =
      force? or
        case :ets.lookup(@credits_table, key) do
          [] ->
            true

          [{^key, _consumed, _credited, stored_cycle, _loaded?, _units, _granting?}] ->
            stored_cycle != cycle_start
        end

    if write? do
      :ets.insert(
        @credits_table,
        {key, consumed_micro, credited_micro, cycle_start, true, units, granting?}
      )
    end

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

  # Credits table. Object:
  # {key, consumed_micro, credited_micro, cycle_start, loaded?, units, granting?}
  # where key = {:limit, subject} (el contador del límite mensual del sujeto) o
  # {:topup, topup_id} (el bolsín de un top-up). `credited` es nil para el
  # límite (su techo lo impone `plan.limit_usd`, no la entrada).
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
      %{subject_id: subject_id}
      |> Tokengate.Budgets.SyncWorker.new()
      |> Oban.insert()
      |> release_marker_on_failed_enqueue(key)
    end

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
