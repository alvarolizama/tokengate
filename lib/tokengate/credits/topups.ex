defmodule Tokengate.Credits.Topups do
  @moduledoc """
  Top-ups de crédito: CRUD y **drenado**.

  Un top-up es crédito extra de un solo uso, por usuario o servicio, con
  expiración opcional contada desde su creación (`expires_in_days` nil ⇒ nunca
  vence). A diferencia del modelo viejo, el monto vive en USD y el **consumo se
  mide contra los logs** (`request_logs.credit_topup_id`), no contra una
  suscripción.

  ## Orden de drenado

  Cuando el sujeto agota su límite mensual, el gasto se cubre con top-ups:
  **primero el que expira antes** (`expires_at ASC NULLS LAST`; los que nunca
  vencen van al final). Este módulo es la única autoridad sobre ese orden y
  sobre qué top-up tiene remanente.
  """

  import Ecto.Query

  alias Tokengate.Credits.Topup
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Repo

  # ---------------------------------------------------------------------------
  # Lectura
  # ---------------------------------------------------------------------------

  @doc "Top-ups de un usuario (cualquier estado), más recientes primero."
  def list_for_user(user_id) do
    Repo.all(
      from t in Topup,
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "Top-ups de un servicio (cualquier estado), más recientes primero."
  def list_for_service(service_id) do
    Repo.all(
      from t in Topup,
        where: t.service_id == ^service_id,
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "Todos los top-ups, con el dueño precargado."
  def list_all do
    Repo.all(from t in Topup, order_by: [desc: t.inserted_at])
  end

  def get_topup(id), do: Repo.get(Topup, id)

  def get_topup!(id), do: Repo.get!(Topup, id)

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

  @doc """
  Consumo de un top-up: la suma de lo asentado en los logs con su id.
  """
  def consumed_usd(%Topup{id: id}) do
    RequestLog
    |> where([rl], rl.credit_topup_id == ^id)
    |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> Repo.one()
    |> Decimal.new()
  end

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
  del sujeto lo resuelve el llamador (grupo para usuarios, propio para
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
          remaining_usd: if(Decimal.compare(remaining, 0) == :lt, do: Decimal.new(0), else: remaining)
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
      |> Enum.map(& &1.id)
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

  def summaries([]), do: %{}

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

  defp consumed_by_topup_ids([]), do: %{}

  defp consumed_by_topup_ids(ids) do
    RequestLog
    |> where([rl], rl.credit_topup_id in ^ids)
    |> group_by([rl], rl.credit_topup_id)
    |> select([rl], {rl.credit_topup_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
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
