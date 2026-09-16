defmodule Tokengate.Credits do
  @moduledoc """
  Resolución del gasto por sujeto: **límite mensual + top-ups**.

  Reemplaza al modelo de suscripciones. Cada request autenticado resuelve su
  crédito contra el sujeto que lo paga:

    * **usuario** — límite propio (`users.monthly_spend_limit_usd`) o, si no
      define el suyo, el de su grupo; `unlimited_spend` (propio o heredado del
      grupo) lo exime del tope; sus top-ups son el segundo camino de gasto.
    * **servicio** — límite propio (`services.monthly_spend_limit_usd`) con su
      `unlimited_spend`, más sus top-ups.

  ## Semántica de nulos y ceros (el único lugar donde se decide)

  | estado | significado |
  |---|---|
  | `monthly_spend_limit_usd IS NULL` | **sin límite propio**: el usuario hereda el de su grupo; un grupo/servicio sin límite no deja gastar salvo top-ups |
  | `monthly_spend_limit_usd = 0` | **cero**: no hay límite disponible (jamás «ilimitado») |
  | `monthly_spend_limit_usd > 0` | límite mensual del sujeto, en USD |
  | `unlimited_spend = true` | único camino a ilimitado; gana sobre límite y top-ups |

  El **ciclo** es el mes calendario UTC. No hay `reset_day` (era del modelo viejo).

  ## Orden de drenado

  El límite primero; agotado (o en cero/ausente), se drena el top-up que
  **expira antes** (`Credits.Topups.draining_order/1`, `NULLS LAST`).
  """

  import Ecto.Query

  alias Tokengate.Accounts.{Group, GroupMember, Service, User}
  alias Tokengate.Credits.Topups
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Repo

  # ---------------------------------------------------------------------------
  # Límite efectivo
  # ---------------------------------------------------------------------------

  @typedoc """
  Límite de gasto efectivo: `limit_usd` nil con `unlimited?: false` ⇒ sin
  límite y solo top-ups; `source` dice de dónde salió (`nil` = de nadie).
  """
  @type limit :: %{limit_usd: Decimal.t() | nil, unlimited?: boolean(), source: atom() | nil}

  @doc """
  Límite efectivo del miembro: el suyo si lo define, si no el del grupo.
  """
  @spec user_limit(GroupMember.t()) :: limit()
  def user_limit(%GroupMember{} = member) do
    member = Repo.preload(member, [:user, :group])
    user_limit(member.user, member.group)
  end

  @spec user_limit(User.t(), Group.t() | nil) :: limit()
  def user_limit(%User{} = user, group) do
    cond do
      user.unlimited_spend ->
        %{limit_usd: nil, unlimited?: true, source: :user}

      not is_nil(user.monthly_spend_limit_usd) ->
        %{limit_usd: user.monthly_spend_limit_usd, unlimited?: false, source: :user}

      group && group.unlimited_spend ->
        %{limit_usd: nil, unlimited?: true, source: :group}

      group && not is_nil(group.monthly_spend_limit_usd) ->
        %{limit_usd: group.monthly_spend_limit_usd, unlimited?: false, source: :group}

      true ->
        %{limit_usd: nil, unlimited?: false, source: nil}
    end
  end

  @doc "Límite efectivo del servicio: el propio (no hereda de nadie)."
  @spec service_limit(Service.t()) :: limit()
  def service_limit(%Service{} = service) do
    case {service.monthly_spend_limit_usd, service.unlimited_spend} do
      {_, true} -> %{limit_usd: nil, unlimited?: true, source: :service}
      {limit, false} -> %{limit_usd: limit, unlimited?: false, source: :service}
    end
  end

  # ---------------------------------------------------------------------------
  # Plan de gasto (lo que el Manager reserva)
  # ---------------------------------------------------------------------------

  @typedoc """
  Plan de gasto de un sujeto: límite efectivo + top-ups vigentes en orden de
  drenado. Es lo que el pre-flight del proxy entrega al Manager.
  """
  @type plan :: %{
          subject: subject(),
          limit_usd: Decimal.t() | nil,
          unlimited?: boolean(),
          topups: [Tokengate.Credits.Topup.t()]
        }

  @type subject :: {:user, term()} | {:service, term()}

  @doc """
  Plan de gasto de un miembro (usuario, o el servicio detrás de un
  virtual member).
  """
  @spec plan(GroupMember.t() | Service.t()) :: plan()
  def plan(%Service{} = service) do
    limit = service_limit(service)

    %{
      subject: {:service, service.id},
      limit_usd: limit.limit_usd,
      unlimited?: limit.unlimited?,
      topups: Topups.draining_order({:service, service.id})
    }
  end

  def plan(%GroupMember{service_name: name} = member) when is_binary(name) do
    case Repo.get(Service, member.id) do
      %Service{} = service -> plan(service)
      nil -> plan_for_user(member.user_id)
    end
  end

  def plan(%GroupMember{user_id: user_id} = member) do
    member = Repo.preload(member, [:user, :group])
    limit = user_limit(member.user, member.group)

    %{
      subject: {:user, user_id},
      limit_usd: limit.limit_usd,
      unlimited?: limit.unlimited?,
      topups: Topups.draining_order({:user, user_id})
    }
  end

  defp plan_for_user(user_id) do
    user = Repo.get(User, user_id)
    group = group_for_user(user_id)
    limit = if user, do: user_limit(user, group), else: %{limit_usd: nil, unlimited?: false, source: nil}

    %{
      subject: {:user, user_id},
      limit_usd: limit.limit_usd,
      unlimited?: limit.unlimited?,
      topups: Topups.draining_order({:user, user_id})
    }
  end

  # ---------------------------------------------------------------------------
  # Gasto (verdad durable: request_logs)
  # ---------------------------------------------------------------------------

  @doc """
  Gasto del ciclo vigente (mes calendario UTC) del sujeto, desde los logs.
  """
  @spec monthly_spend_usd(subject()) :: Decimal.t()
  def monthly_spend_usd(subject) do
    subject
    |> spend_query(nil)
    |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> Repo.one()
    |> Decimal.new()
  end

  @doc """
  Gasto del sujeto **debitado al límite** (los logs sin top-up). Es el consumo
  que cuenta contra `monthly_spend_limit_usd`.
  """
  @spec spend_debited_to_limit(subject(), DateTime.t() | nil) :: Decimal.t()
  def spend_debited_to_limit(subject, from \\ nil) do
    subject
    |> spend_query(from)
    |> where([rl], is_nil(rl.credit_topup_id))
    |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> Repo.one()
    |> Decimal.new()
  end

  @doc """
  Gasto de varios sujetos en una query por tipo: `%{subject => usd}`.

  `opts[:only_limit]` cuenta solo lo **debitado al límite** (logs sin top-up),
  que es lo que consume `monthly_spend_limit_usd`. Los sujetos ausentes del
  resultado gastaron 0.
  """
  def spend_by_subjects(subjects, opts \\ []) do
    users = for {:user, id} <- subjects, do: id
    services = for {:service, id} <- subjects, do: id
    only_limit = Keyword.get(opts, :only_limit, false)

    user_spend = spend_grouped_users(users, only_limit)
    service_spend = spend_grouped_services(services, only_limit)

    Map.new(subjects, fn
      {:user, id} = subject -> {subject, Map.get(user_spend, id, Decimal.new(0))}
      {:service, id} = subject -> {subject, Map.get(service_spend, id, Decimal.new(0))}
    end)
  end

  defp spend_grouped_users([], _only_limit), do: %{}

  defp spend_grouped_users(user_ids, only_limit) do
    query =
      RequestLog
      |> join(:inner, [rl], gm in GroupMember, on: gm.id == rl.group_member_id)
      |> where([rl, gm], gm.user_id in ^user_ids)

    query
    |> since(nil)
    |> only_limit_filter(only_limit)
    |> group_by([_rl, gm], gm.user_id)
    |> select([rl, gm], {gm.user_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
  end

  defp spend_grouped_services([], _only_limit), do: %{}

  defp spend_grouped_services(service_ids, only_limit) do
    RequestLog
    |> where([rl], rl.service_id in ^service_ids)
    |> since(nil)
    |> only_limit_filter(only_limit)
    |> group_by([rl], rl.service_id)
    |> select([rl], {rl.service_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
  end

  defp only_limit_filter(query, false), do: query
  defp only_limit_filter(query, true), do: where(query, [rl], is_nil(rl.credit_topup_id))

  defp spend_query({:service, service_id}, from) do
    RequestLog
    |> where([rl], rl.service_id == ^service_id)
    |> since(from)
  end

  defp spend_query({:user, user_id}, from) do
    RequestLog
    |> join(:inner, [rl], gm in GroupMember, on: gm.id == rl.group_member_id)
    |> where([rl, gm], gm.user_id == ^user_id)
    |> since(from)
  end

  defp since(query, nil) do
    from = Tokengate.Periods.start_of_month_utc("Etc/UTC")
    where(query, [rl], rl.inserted_at >= ^from)
  end

  defp since(query, %DateTime{} = from), do: where(query, [rl], rl.inserted_at >= ^from)

  # ---------------------------------------------------------------------------
  # Resumen (display + pre-flight)
  # ---------------------------------------------------------------------------

  @doc """
  Resumen del sujeto: límite, gasto del mes, remanente de límite y top-ups
  vigentes con su remanente.
  """
  @spec summary(subject(), limit() | plan()) :: map()
  def summary(subject, %{limit_usd: limit_usd, unlimited?: unlimited?}) do
    spend = monthly_spend_usd(subject)
    against_limit = spend_debited_to_limit(subject)
    topups = Topups.summary(subject)

    remaining_limit =
      case limit_usd do
        nil -> nil
        limit_usd -> max_decimal(Decimal.sub(limit_usd, against_limit), Decimal.new(0))
      end

    %{
      subject: subject,
      limit_usd: limit_usd,
      unlimited?: unlimited?,
      spend_usd: spend,
      limit_spend_usd: against_limit,
      remaining_limit_usd: remaining_limit,
      topups: topups.topups,
      remaining_topup_usd: topups.remaining_topup_usd,
      has_path?: has_path?(unlimited?, remaining_limit, topups.remaining_topup_usd)
    }
  end

  @doc "¿Queda algún camino de gasto? (ilimitado, límite con remanente o top-up)"
  def has_path?(unlimited?, remaining_limit, remaining_topup)
  def has_path?(true, _limit, _topup), do: true

  def has_path?(false, %Decimal{} = limit, _topup), do: Decimal.compare(limit, 0) == :gt

  def has_path?(false, nil, %Decimal{} = topup), do: Decimal.compare(topup, 0) == :gt

  @doc """
  Resúmenes de varias membresías en lote (para los tableros): 3 queries fijas,
  nunca una por miembro. `%{member_id => summary}` con las mismas llaves que
  `summary/2`, más `:member`.
  """
  def summaries(members) when is_list(members) do
    members = Enum.map(members, &Repo.preload(&1, [:user, :group]))
    subjects = Enum.map(members, &{:user, &1.user_id})
    spend = spend_by_subjects(subjects)
    limit_spend = spend_by_subjects(subjects, only_limit: true)
    topups = Topups.summaries(subjects)

    Map.new(members, fn member ->
      subject = {:user, member.user_id}
      limit = user_limit(member.user, member.group)
      {limit_usd, unlimited?} = {limit.limit_usd, limit.unlimited?}
      spent = Map.get(spend, subject, Decimal.new(0))
      against_limit = Map.get(limit_spend, subject, Decimal.new(0))

      remaining_limit =
        case limit_usd do
          nil -> nil
          limit_usd -> max_decimal(Decimal.sub(limit_usd, against_limit), Decimal.new(0))
        end

      topup = Map.get(topups, subject, %{topups: [], remaining_topup_usd: Decimal.new(0)})

      {member.id,
       %{
         member: member,
         subject: subject,
         limit_usd: limit_usd,
         unlimited?: unlimited?,
         spend_usd: spent,
         limit_spend_usd: against_limit,
         remaining_limit_usd: remaining_limit,
         topups: topup.topups,
         remaining_topup_usd: topup.remaining_topup_usd,
         has_path?: has_path?(unlimited?, remaining_limit, topup.remaining_topup_usd)
       }}
    end)
  end

  def summaries([]), do: %{}

  @doc """
  Resumen de los servicios en lote, indexado por `service_id`.
  """
  def service_summaries(services) when is_list(services) do
    subjects = Enum.map(services, &{:service, &1.id})
    spend = spend_by_subjects(subjects)
    limit_spend = spend_by_subjects(subjects, only_limit: true)
    topups = Topups.summaries(subjects)

    Map.new(services, fn service ->
      subject = {:service, service.id}
      limit = service_limit(service)
      spent = Map.get(spend, subject, Decimal.new(0))
      against_limit = Map.get(limit_spend, subject, Decimal.new(0))

      remaining_limit =
        case limit.limit_usd do
          nil -> nil
          limit_usd -> max_decimal(Decimal.sub(limit_usd, against_limit), Decimal.new(0))
        end

      topup = Map.get(topups, subject, %{topups: [], remaining_topup_usd: Decimal.new(0)})

      {service.id,
       %{
         service: service,
         subject: subject,
         limit_usd: limit.limit_usd,
         unlimited?: limit.unlimited?,
         spend_usd: spent,
         limit_spend_usd: against_limit,
         remaining_limit_usd: remaining_limit,
         topups: topup.topups,
         remaining_topup_usd: topup.remaining_topup_usd,
         has_path?: has_path?(limit.unlimited?, remaining_limit, topup.remaining_topup_usd)
       }}
    end)
  end

  def service_summaries([]), do: %{}

  # ---------------------------------------------------------------------------
  # Auxiliares
  # ---------------------------------------------------------------------------

  @doc "El grupo de un usuario, o `nil` (un usuario pertenece a un solo grupo)."
  def group_for_user(user_id) do
    Repo.one(
      from(gm in GroupMember,
        join: g in Group,
        on: g.id == gm.group_id,
        where: gm.user_id == ^user_id,
        select: g,
        limit: 1
      )
    )
  end

  @doc """
  Sujetos que hoy no tienen camino de gasto (sin límite, sin ilimitado, sin
  top-up vigente) — para la vigilancia de mantenimiento.
  """
  def blocked_users do
    users = Repo.all(from u in User)
    summaries = summaries(Enum.flat_map(users, &Repo.preload(&1, :group_members).group_members))

    users
    |> Enum.filter(fn user ->
      membership = Enum.find(Repo.preload(user, :group_members).group_members, & &1.user_id)
      case membership do
        nil -> true
        member -> Map.get(summaries, member.id, %{has_path?: false}).has_path? == false
      end
    end)
  end

  defp max_decimal(a, b) do
    if Decimal.compare(a, b) == :lt, do: b, else: a
  end
end
