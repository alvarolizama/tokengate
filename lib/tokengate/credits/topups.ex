defmodule Tokengate.Credits.Topups do
  @moduledoc """
  Top-ups de crédito: CRUD y **drenado**.

  Un top-up es crédito extra de un solo uso, por usuario o servicio, con
  expiración opcional contada desde su creación (`expires_in_days` nil ⇒ nunca
  vence).  A diferencia del modelo viejo, el monto vive en USD y el **consumo se
  mide contra un contador durable** (`topup_consumption_counters`, que el
  trigger de `request_logs` mantiene exacto), no contra una suscripción ni
  contra los logs crudos — esos se podan a los 90 días y un top-up longevo
  resucitaba crédito ya gastado.

  ## Orden de drenado

  Cuando el sujeto agota su límite mensual, el gasto se cubre con top-ups:
  **primero el que expira antes** (`expires_at ASC NULLS LAST`; los que nunca
  vencen van al final). Este módulo es la única autoridad sobre ese orden y
  sobre qué top-up tiene remanente.
  """

  import Ecto.Query

  alias Tokengate.Credits.Topup
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.TopupConsumptionCounter
  alias Tokengate.Repo

  # ---------------------------------------------------------------------------
  # Lectura
  # ---------------------------------------------------------------------------

  @doc "Top-ups de un usuario (cualquier estado), más recientes primero."
  def list_for_user(user_id) do
    Topup
    |> where([t], t.user_id == ^user_id)
    |> order_by([t], desc: t.inserted_at)
    |> preload([:user, :service])
    |> Repo.all()
  end

  @doc "Top-ups de un servicio (cualquier estado), más recientes primero."
  def list_for_service(service_id) do
    Topup
    |> where([t], t.service_id == ^service_id)
    |> order_by([t], desc: t.inserted_at)
    |> preload([:user, :service])
    |> Repo.all()
  end

  @doc "Todos los top-ups, con el dueño (usuario/servicio) precargado."
  def list_all do
    Topup
    |> order_by([t], desc: t.inserted_at)
    |> preload([:user, :service])
    |> Repo.all()
  end

  def get_topup(id), do: Repo.get(Topup, id)

  def get_topup!(id), do: Repo.get!(Topup, id)

  @doc "Fetches a top-up with `:user` and `:service` preloaded."
  def get_topup_with_owner(id) do
    Topup
    |> preload([:user, :service])
    |> Repo.get(id)
  end

  @doc """
  Top-ups **vigentes** de un sujeto, en el orden de drenado (expira antes
  primero; los sin expiración al final).

  `subject` es `{:user, user_id}` o `{:service, service_id}`.
  """
  def draining_order({:user, user_id}) do
    run_draining(query_for_user(user_id))
  end

  def draining_order({:service, service_id}) do
    run_draining(query_for_service(service_id))
  end

  defp query_for_user(user_id), do: from(t in Topup, where: t.user_id == ^user_id)
  defp query_for_service(service_id), do: from(t in Topup, where: t.service_id == ^service_id)

  defp run_draining(query) do
    now = DateTime.utc_now()

    query
    |> where([t], t.status == "active")
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> order_by([t], asc_nulls_last: t.expires_at, asc: t.inserted_at)
    |> Repo.all()
  end

  # `request_logs` is partitioned by `inserted_at` and keeps ~90 daily
  # partitions, so an unbounded `SUM ... WHERE credit_topup_id = ?` walks all
  # of them. This read runs on the proxy's reserve path
  # (`Budgets.Manager.ensure_topup_loaded/1`) and again on the admin pages
  # every 5s, so the partition walk is the whole cost. A top-up can only be
  # debited AFTER it exists, so the read is bounded by its creation instant.
  #
  # The grace window covers the two orderings the bound must not cut:
  #
  #   * a request that started before the top-up was created and was settled
  #     against it afterwards (the log carries the request start time), and
  #   * the WriteWorker flush lag plus clock skew between nodes.
  #
  # One extra day of partitions costs a single extra range scan; scanning the
  # full retention window is what this avoids.
  @consumption_grace_hours 24

  @doc """
  Consumo de un top-up: el total durable del contador
  (`topup_consumption_counters`), que el trigger de `request_logs` mantiene
  exacto en la misma transacción del log.

  **Por qué NO se suma sobre los logs**: `request_logs` conserva 90 días
  (`PartitionWorker`). Un top-up sin expiración más viejo que la retención
  perdía sus débitos con las particiones, su remanente volvía a subir y el
  sujeto recuperaba crédito ya gastado (`remaining_usd/1` → `grants_credit?/2`),
  y encima el re-seed del `Budgets.Manager` consolidaba el valor inflado.

  Fallback: si el top-up no tiene fila de contador se suma sobre los logs
  acotados por `consumption_floor/1` (ver el doc). Sólo aplica a filas sin
  consumo registrado — con la migración que crea el contador ya backfilleado,
  todo débito vivo tiene fila.
  """
  def consumed_usd(%Topup{id: id} = topup) do
    case counted_consumed_micro(id) do
      nil -> consumed_usd_from_logs(topup)
      micro -> micro_to_usd(micro)
    end
  end

  defp counted_consumed_micro(nil), do: nil

  defp counted_consumed_micro(topup_id) do
    TopupConsumptionCounter
    |> where([t], t.topup_id == ^topup_id)
    |> select([t], t.consumed_micro)
    |> Repo.one()
  end

  #  Suma sobre los logs con cota inferior (creación del top-up − gracia): sin
  #  la cota, cada lectura es un seq scan de todas las particiones vivas.
  defp consumed_usd_from_logs(topup) do
    RequestLog
    |> where([rl], rl.credit_topup_id == ^topup.id)
    |> consume_since(consumption_floor(topup))
    |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> Repo.one()
    |> Decimal.new()
  end

  # Nothing to bound against an unsaved struct (no `inserted_at` yet).
  defp consumption_floor(%Topup{inserted_at: %DateTime{} = inserted_at}) do
    inserted_at
    |> DateTime.add(-@consumption_grace_hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  defp consumption_floor(_topup), do: nil

  defp consume_since(query, nil), do: query
  defp consume_since(query, %DateTime{} = from), do: where(query, [rl], rl.inserted_at >= ^from)

  @doc """
  Remanente de un top-up en USD (nunca negativo).
  """
  def remaining_usd(%Topup{amount_usd: amount} = topup) do
    remaining = Decimal.sub(amount, consumed_usd(topup))
    if Decimal.compare(remaining, 0) == :lt, do: Decimal.new(0), else: remaining
  end

  @doc "¿El top-up otorga crédito ahora? (activo, no vencido, con remanente)"
  def grants_credit?(%Topup{} = topup, now \\ DateTime.utc_now()) do
    topup.status == "active" and
      (is_nil(topup.expires_at) or DateTime.compare(topup.expires_at, now) == :gt) and
      Decimal.compare(remaining_usd(topup), 0) == :gt
  end

  @doc """
  Resumen de crédito de un sujeto: `%{limit_usd, has_limit?, unlimited?,
  topups: [...], remaining_topup_usd, has_grant?}`.

  `subject` es `{:user, user_id}` o `{:service, service_id}`. El límite mensual
  del sujeto lo resuelve el llamador (perfil de límites para usuarios, propio para
  servicios); aquí solo se leen los top-ups.
  """
  def summary({:user, user_id} = subject) do
    _ = user_id
    summarize(subject, draining_order(subject))
  end

  def summary({:service, service_id} = subject) do
    _ = service_id
    summarize(subject, draining_order(subject))
  end

  defp summarize(_subject, topups) do
    rows =
      Enum.map(topups, fn topup ->
        consumed = consumed_usd(topup)
        remaining = Decimal.sub(topup.amount_usd, consumed)

        %{
          topup: topup,
          consumed_usd: consumed,
          remaining_usd:
            if(Decimal.compare(remaining, 0) == :lt, do: Decimal.new(0), else: remaining)
        }
      end)

    remaining =
      Enum.reduce(rows, Decimal.new(0), fn row, acc -> Decimal.add(acc, row.remaining_usd) end)

    %{
      topups: rows,
      remaining_topup_usd: remaining,
      has_grant?: Decimal.compare(remaining, 0) == :gt
    }
  end

  @doc """
  Resúmenes de varios sujetos en una pasada: 2 queries agrupadas, nunca una por
  sujeto. Devuelve `%{subject => %{topups: [...], remaining_topup_usd: Decimal}}`.
  """
  def summaries(subjects) when is_list(subjects) do
    user_ids = for {:user, id} <- subjects, do: id
    service_ids = for {:service, id} <- subjects, do: id

    topups =
      all_draining(user_ids, service_ids)
      |> Enum.group_by(fn topup ->
        if topup.user_id, do: {:user, topup.user_id}, else: {:service, topup.service_id}
      end)

    consumed =
      topups
      |> Map.values()
      |> List.flatten()
      |> consumed_by_topup_ids()

    Map.new(subjects, fn subject ->
      rows =
        (Map.get(topups, subject) || [])
        |> Enum.map(fn topup -> row(topup, Map.get(consumed, topup.id, Decimal.new(0))) end)

      remaining =
        Enum.reduce(rows, Decimal.new(0), fn r, acc -> Decimal.add(acc, r.remaining_usd) end)

      {subject, %{topups: rows, remaining_topup_usd: remaining}}
    end)
  end

  defp all_draining([], []), do: []

  defp all_draining(user_ids, service_ids) do
    now = DateTime.utc_now()

    from(t in Topup,
      where: t.status == "active",
      where: is_nil(t.expires_at) or t.expires_at > ^now,
      where: t.user_id in ^user_ids or t.service_id in ^service_ids,
      order_by: [asc_nulls_last: t.expires_at, asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Batch consumption in USD for a list of top-ups, reading `topup_consumption_counters`
  first and falling back to bounded `request_logs` only when no counter row exists.
  """
  def consumed_by_topup_ids([]), do: %{}

  # Counters first (one query for the whole batch). Only the top-ups WITHOUT a
  # counter row fall back to the log sum — that is the pre-backfill case: the
  # migration backfills every top-up the retention still holds, so in practice
  # the fallback only covers a top-up created between the backfill and its first
  # debit, where the log sum and the counter agree anyway.
  def consumed_by_topup_ids(topups) do
    ids = Enum.map(topups, & &1.id)
    counted = counted_micro_by_ids(ids)

    from_logs =
      case Enum.reject(topups, &Map.has_key?(counted, &1.id)) do
        [] -> %{}
        missing -> consumed_by_topup_ids_from_logs(missing)
      end

    Map.new(topups, fn topup ->
      micro =
        case Map.fetch(counted, topup.id) do
          {:ok, micro} -> micro
          :error -> Map.get(from_logs, topup.id, 0)
        end

      {topup.id, micro_to_usd(micro)}
    end)
  end

  defp counted_micro_by_ids(ids) do
    TopupConsumptionCounter
    |> where([t], t.topup_id in ^ids)
    |> select([t], {t.topup_id, t.consumed_micro})
    |> Repo.all()
    |> Map.new()
  end

  defp consumed_by_topup_ids_from_logs(topups) do
    ids = Enum.map(topups, & &1.id)

    RequestLog
    |> where([rl], rl.credit_topup_id in ^ids)
    |> consume_since(earliest_consumption_floor(topups))
    |> group_by([rl], rl.credit_topup_id)
    |> select([rl], {rl.credit_topup_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} ->
      # Log sums are USD; normalize to micro so the caller has one unit.
      {id,
       cost
       |> Decimal.mult(Decimal.new(1_000_000))
       |> Decimal.round(0, :half_up)
       |> Decimal.to_integer()}
    end)
  end

  # micro-USD -> USD with the same 6 decimals `numeric(12,6)` stores, so the
  # value is byte-identical to what the old log sum returned.
  defp micro_to_usd(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> Decimal.round(6, :half_up)
  end

  defp earliest_consumption_floor(topups) do
    topups
    |> Enum.map(&consumption_floor/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp row(topup, consumed) do
    remaining = Decimal.sub(topup.amount_usd, consumed)

    %{
      topup: topup,
      consumed_usd: consumed,
      remaining_usd: if(Decimal.compare(remaining, 0) == :lt, do: Decimal.new(0), else: remaining)
    }
  end

  # ---------------------------------------------------------------------------
  # Invalidación de caché (constraint del contrato)
  # ---------------------------------------------------------------------------

  # El `ApiKeyCache` guarda el PLAN del sujeto (límite + top-ups vigentes) con
  # TTL de 60s. Crear, revocar, reactivar o editar un top-up cambia ese plan:
  # sin invalidar, el proxy seguiría usando el plan viejo (un top-up recién
  # creado no se vería hasta un minuto después, y uno revocado seguiría
  # otorgando). Se invalida por el sujeto dueño.
  defp invalidate_for({:user, user_id}) do
    safe_invalidate(fn -> Tokengate.Accounts.ApiKeyCache.invalidate_user(user_id) end)
  end

  defp invalidate_for({:service, service_id}) do
    safe_invalidate(fn -> Tokengate.Accounts.ApiKeyCache.invalidate_member(service_id) end)
  end

  defp subject_of(%Topup{user_id: user_id}) when is_binary(user_id), do: {:user, user_id}
  defp subject_of(%Topup{service_id: service_id}), do: {:service, service_id}

  defp safe_invalidate(fun) do
    if :ets.whereis(Tokengate.Accounts.ApiKeyCache.table()) != :undefined, do: fun.()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Escritura
  # ---------------------------------------------------------------------------

  @doc "Crea un top-up (usuario o servicio) con su label y expiración."
  def create(attrs) do
    result =
      %Topup{}
      |> Topup.changeset(attrs)
      |> Repo.insert()

    with {:ok, topup} <- result do
      invalidate_for(subject_of(topup))
    end

    result
  end

  def change_topup(%Topup{} = topup, attrs \\ %{}), do: Topup.changeset(topup, attrs)

  @doc "Actualiza un top-up (label, nota, expiración)."
  def edit_topup(%Topup{} = topup, attrs) do
    result =
      topup
      |> Topup.changeset(attrs)
      |> Repo.update()

    with {:ok, updated} <- result do
      invalidate_for(subject_of(updated))
    end

    result
  end

  @doc "Revoca un top-up: deja de otorgar; lo ya consumido vive en los logs."
  def revoke(%Topup{} = topup) do
    edit_topup(topup, %{status: "revoked"})
  end

  @doc "Reactiva un top-up revocado o agotado."
  def reactivate(%Topup{} = topup) do
    edit_topup(topup, %{status: "active"})
  end

  def delete(%Topup{} = topup) do
    result = Repo.delete(topup)
    invalidate_for(subject_of(topup))
    result
  end
end
