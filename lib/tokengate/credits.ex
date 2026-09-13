defmodule Tokengate.Credits do
  @moduledoc """
  Suscripciones de crédito: la *policy* (config) y la **resolución de grants**
  que usa el pre-flight del proxy.

  Un **grant** es `(subscription, user)` — no se materializa en una tabla:

    * sub **de grupo** (`subscription.user_id == nil`): cada miembro de un grupo
      que la referencia vía `groups.default_subscription_id` queda auto-asignado
      al mismo grant. Si un usuario está en varios grupos que comparten la MISMA
      sub, tiene **un solo grant** (no se crea uno por grupo).
    * sub **directa** (`subscription.user_id` seteado): grant del dueño
      (incluye top-ups, `recurrence = "none"`).

  Orden de débito para un request autenticado con una membresía `(user, group)`:

    1. el grant de la suscripción default del grupo (`default_subscription_id`),
    2. si el grupo no tiene sub — o el grant del tier 1 se agotó — el crédito
       **directo** del usuario (subs directas + top-ups),

  y dentro de cada tier **se drena primero lo que se reinicia/vence antes**.
  """

  import Ecto.Query

  alias Tokengate.Accounts.{Group, GroupMember}
  alias Tokengate.Credits.Subscription
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Repo

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

  def list_subscriptions do
    Repo.all(from s in Subscription, order_by: [desc: s.inserted_at])
  end

  @doc "Subs de grupo (defaults), con el grupo que las referencia."
  def list_group_subscriptions do
    Repo.all(
      from s in Subscription,
        where: is_nil(s.user_id),
        order_by: [desc: s.inserted_at]
    )
  end

  @doc "Subs directas de un usuario."
  def list_user_subscriptions(user_id) do
    Repo.all(
      from s in Subscription, where: s.user_id == ^user_id, order_by: [desc: s.inserted_at]
    )
  end

  def get_subscription(id), do: Repo.get(Subscription, id)

  def get_subscription!(id), do: Repo.get!(Subscription, id)

  def create_subscription(attrs) do
    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert()
  end

  def update_subscription(%Subscription{} = subscription, attrs) do
    subscription
    |> Subscription.changeset(attrs)
    |> Repo.update()
  end

  def change_subscription(%Subscription{} = subscription, attrs \\ %{}) do
    Subscription.changeset(subscription, attrs)
  end

  def delete_subscription(%Subscription{} = subscription) do
    Repo.delete(subscription)
  end

  @doc """
  Fija (o limpia, con `nil`) la suscripción default de un grupo.
  Varios grupos pueden apuntar a la misma sub.
  """
  def set_group_default(%Group{} = group, %Subscription{} = subscription) do
    group
    |> Ecto.Changeset.change(default_subscription_id: subscription.id)
    |> Repo.update()
  end

  def set_group_default(%Group{} = group, nil) do
    group
    |> Ecto.Changeset.change(default_subscription_id: nil)
    |> Repo.update()
  end

  @doc "Ids de los grupos que referencian esta sub como default."
  def group_ids_for(%Subscription{id: id}) do
    Repo.all(from g in Group, where: g.default_subscription_id == ^id, select: g.id)
  end

  @doc "Grupos con default, agrupados por `subscription_id`."
  def groups_by_subscription do
    Repo.all(from g in Group, where: not is_nil(g.default_subscription_id))
    |> Enum.group_by(& &1.default_subscription_id)
  end

  @doc """
  Sincroniza qué grupos referencian a `subscription` como su default: fija los
  nuevos, limpia los que ya no están.
  """
  def assign_groups(%Subscription{} = subscription, group_ids) do
    wanted = Enum.map(group_ids, &to_string/1)
    current = group_ids_for(subscription)

    Enum.each(wanted -- current, &put_group_default(&1, subscription))
    Enum.each(current -- wanted, &put_group_default(&1, nil))

    :ok
  end

  defp put_group_default(nil, _sub), do: :ok

  defp put_group_default(group_id, sub) do
    case Repo.get(Group, group_id) do
      nil -> :ok
      group -> set_group_default(group, sub)
    end
  end

  # ---------------------------------------------------------------------------
  # Resolución de grants
  # ---------------------------------------------------------------------------

  @doc """
  Grants a intentar para una membresía, mejor primero.

  Devuelve `[%{subscription: %Subscription{}, tier: 1 | 2}]`:

    * tier 1 (si existe): la sub default del grupo;
    * tier 2: las subs directas del usuario (subs + top-ups), ordenadas por
      próximo reset/vencimiento ascendente (se drena primero lo que vence antes).
  """
  @spec grants_for(GroupMember.t()) :: [%{subscription: Subscription.t(), tier: 1 | 2}]
  def grants_for(%GroupMember{} = member) do
    tier1 =
      case group_subscription(member.group_id) do
        %Subscription{} = subscription ->
          [%{subscription: subscription, tier: 1, user_id: member.user_id}]

        nil ->
          []
      end

    tier2 =
      member.user_id
      |> direct_subscriptions()
      |> Enum.sort_by(&next_reset/1, Date)
      |> Enum.map(&%{subscription: &1, tier: 2, user_id: member.user_id})

    tier1 ++ tier2
  end

  @doc "La sub default de un grupo (o `nil` si no tiene o está pausada)."
  def group_subscription(nil), do: nil

  def group_subscription(group_id) do
    from(g in Group,
      join: s in Subscription,
      on: s.id == g.default_subscription_id,
      where: g.id == ^group_id and s.status == "active",
      select: s
    )
    |> Repo.one()
  end

  @doc "Las subs directas activas de un usuario (incluye top-ups)."
  def direct_subscriptions(nil), do: []

  def direct_subscriptions(user_id) do
    Repo.all(
      from s in Subscription,
        where: s.user_id == ^user_id and s.status == "active"
    )
  end

  # ---------------------------------------------------------------------------
  # Ciclo
  # ---------------------------------------------------------------------------

  @doc """
  Fronteras del ciclo vigente para `date`:

    * `recurrence = "monthly"` → anclado en `reset_day`, clampeado al último
      día del mes cuando no existe (p.ej. 31 en febrero). `%{start: Date.t(),
      end: Date.t()}` donde `end` es el **próximo** reset.
    * `recurrence = "none"` → `%{start: starts_at, end: expires_at}` (cada uno
      puede ser `nil`).
  """
  @spec cycle_bounds(Subscription.t(), Date.t()) :: %{start: Date.t() | nil, end: Date.t() | nil}
  def cycle_bounds(%Subscription{recurrence: "none"} = subscription, _date) do
    %{start: to_date(subscription.starts_at), end: to_date(subscription.expires_at)}
  end

  def cycle_bounds(%Subscription{reset_day: day}, date) do
    this_month = reset_on(date.year, date.month, day)

    start =
      if Date.compare(this_month, date) in [:lt, :eq] do
        this_month
      else
        prev = Date.add(Date.new!(date.year, date.month, 1), -1)
        reset_on(prev.year, prev.month, day)
      end

    {ny, nm} = next_month(start.year, start.month)
    %{start: start, end: reset_on(ny, nm, day)}
  end

  @doc """
  Fecha del próximo reset de la sub (o su vencimiento, para las no recurrentes).
  Se usa para drenar primero lo que antes se reinicia/vence.
  """
  @spec next_reset(Subscription.t()) :: Date.t()
  def next_reset(%Subscription{recurrence: "none"} = subscription) do
    to_date(subscription.expires_at) || ~D[9999-12-31]
  end

  def next_reset(%Subscription{} = subscription) do
    %{end: e} = cycle_bounds(subscription, Date.utc_today())
    e || ~D[9999-12-31]
  end

  # ---------------------------------------------------------------------------
  # Estado del grant (derivado de request_logs + config)
  # ---------------------------------------------------------------------------

  # 1 crédito = $1 (1_000_000 micro-USD). Cambiar aquí si se quiere otra
  # denominación (la unidad se mantiene en la misma escala que el costo).
  @credit_micro 1_000_000

  @doc """
  Estado vigente de un grant `(suscripción, usuario)`, derivado de
  `request_logs` (la verdad durable) + la config de la suscripción.

  Devuelve `%{credited_micro: integer, consumed_micro: integer, cycle_start: Date.t() | nil}`:

    * `consumed_micro` — gasto del ciclo vigente (requests ya asentados con este
      `credit_subscription_id` para este usuario);
    * `credited_micro` — `units` del ciclo + arrastre de rollover;
    * `cycle_start` — inicio del ciclo vigente.

  Rollover (Fase A): arrastra un `%` de lo **no gastado del ciclo anterior**
  sobre la asignación base (`units`), con tope opcional. Sin acumulación
  compuesta — si el grant estuvo inactivo varios ciclos, no se compone.
  """
  @spec grant_state(Subscription.t(), term()) :: %{
          credited_micro: integer(),
          consumed_micro: integer(),
          cycle_start: Date.t() | nil
        }
  def grant_state(%Subscription{} = subscription, user_id) do
    %{start: cycle_start} = cycle_bounds(subscription, Date.utc_today())

    %{
      credited_micro:
        subscription.units * @credit_micro + carried_micro(subscription, user_id, cycle_start),
      consumed_micro: micro(spend_between(subscription.id, user_id, cycle_start, nil)),
      cycle_start: cycle_start
    }
  end

  @doc "Micro-USD de `units` créditos."
  def units_to_micro(units) when is_integer(units), do: units * @credit_micro

  @doc """
  Crédito vigente de una membresía: **suma sobre sus grants** (default de grupo
  → crédito directo).

  Devuelve `%{credited_micro, consumed_micro, remaining_micro, has_credit?}`.
  `has_credit?` es `false` cuando no hay ninguna suscripción aplicable (tier 3:
  sin límite de crédito).
  """
  @spec member_credit(GroupMember.t()) :: %{
          credited_micro: integer(),
          consumed_micro: integer(),
          remaining_micro: integer(),
          has_credit?: boolean()
        }
  def member_credit(%GroupMember{} = member) do
    grants = grants_for(member)

    {credited, consumed} =
      Enum.reduce(grants, {0, 0}, fn %{subscription: subscription, user_id: user_id}, {c, k} ->
        state = grant_state(subscription, user_id)
        {c + state.credited_micro, k + state.consumed_micro}
      end)

    %{
      credited_micro: credited,
      consumed_micro: consumed,
      remaining_micro: max(0, credited - consumed),
      has_credit?: grants != []
    }
  end

  defp carried_micro(
         %Subscription{recurrence: "monthly", rollover_mode: "rollover"} = subscription,
         user_id,
         cycle_start
       ) do
    prev_start = prev_cycle_start(subscription, cycle_start)
    consumed_prev = micro(spend_between(subscription.id, user_id, prev_start, cycle_start))
    unused = max(0, subscription.units * @credit_micro - consumed_prev)
    raw = div(unused * (subscription.rollover_pct || 0), 100)

    case subscription.rollover_cap_units do
      nil -> raw
      cap -> min(raw, cap * @credit_micro)
    end
  end

  defp carried_micro(_subscription, _user_id, _cycle_start), do: 0

  # Gasto asentado de (suscripción, usuario) en [from, to). `to = nil` → abierto.
  # El usuario sale del grupo_member de cada request (el grant es por usuario,
  # compartido por sus membresías).
  defp spend_between(subscription_id, user_id, from, to) do
    query =
      RequestLog
      |> join(:inner, [rl], gm in GroupMember, on: gm.id == rl.group_member_id)
      |> where(
        [rl, gm],
        rl.credit_subscription_id == ^subscription_id and gm.user_id == ^user_id and
          rl.inserted_at >= ^to_datetime(from)
      )

    query =
      if to do
        where(query, [rl], rl.inserted_at < ^to_datetime(to))
      else
        query
      end

    query
    |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> Repo.one()
  end

  defp prev_cycle_start(subscription, cycle_start) do
    %{start: previous} = cycle_bounds(subscription, Date.add(cycle_start, -1))
    previous
  end

  defp micro(%Decimal{} = usd) do
    usd
    |> Decimal.mult(Decimal.new(@credit_micro))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp micro(nil), do: 0

  defp to_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp to_datetime(%DateTime{} = dt), do: dt

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Día `day` del mes `month`, clampeado al último día existente.
  defp reset_on(year, month, day) do
    d = min(day, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, d)
  end

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}

  defp to_date(nil), do: nil
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%Date{} = d), do: d
end
