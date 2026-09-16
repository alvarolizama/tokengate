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

  Los **services** no dependen de grupos: su sub es directa
  (`services.subscription_id`) vía `service_grants/1`, y cada service drena
  su **propio** bolsín aunque comparta sub con otro service. Sin sub el
  consumo es ilimitado (tier 3).
  """

  import Ecto.Query

  alias Tokengate.Accounts.{Group, GroupMember, Service}
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
    result =
      subscription
      |> Subscription.changeset(attrs)
      |> Repo.update()

    # Status/units changes affect the auth cache of every subject with a
    # grant on this sub (group members + linked services).
    with {:ok, _} <- result do
      Tokengate.Routing.Cache.invalidate_all()
      groups = group_ids_for(subscription)
      Enum.each(groups, &Tokengate.Accounts.ApiKeyCache.invalidate_group/1)

      subscription.id
      |> linked_services()
      |> Enum.each(&Tokengate.Accounts.ApiKeyCache.invalidate_member(&1.id))
    end

    result
  end

  # Services directly linked to a subscription (their own grant pocket).
  defp linked_services(subscription_id) do
    import Ecto.Query, only: [from: 2]

    Tokengate.Repo.all(
      from s in Tokengate.Accounts.Service, where: s.subscription_id == ^subscription_id
    )
  end

  def change_subscription(%Subscription{} = subscription, attrs \\ %{}) do
    Subscription.changeset(subscription, attrs)
  end

  def delete_subscription(%Subscription{} = subscription) do
    Repo.delete(subscription)
  end

  @doc """
  Micro-USD gastados por una suscripción desde su inicio (cota abierta hacia
  atrás). Se usa para detectar top-ups agotados.
  """
  def lifetime_spend_micro(subscription_id) do
    micro(spend_for_subscription(subscription_id, nil))
  end

  @doc """
  Fija (o limpia, con `nil`) la suscripción default de un grupo.
  Varios grupos pueden apuntar a la misma sub.

  `nil` **siempre escribe en la BD**: el `Repo.update/1` de un changeset sin
  cambios es un no-op, así que un `group` con el struct obsoleto (p. ej.
  cargado antes de vincular) "desvinculaba" sin tocar la fila y el grupo seguía
  apuntando a la sub — un vínculo fantasma, invisible en la UI pero activo en
  el gate de crédito.
  """
  def set_group_default(%Group{} = group, %Subscription{} = subscription) do
    put_group_link(group, subscription.id)
  end

  def set_group_default(%Group{} = group, nil) do
    put_group_link(group, nil)
  end

  defp put_group_link(%Group{} = group, subscription_id) do
    {count, _} =
      from(g in Group, where: g.id == ^group.id)
      |> Repo.update_all(
        set: [
          default_subscription_id: subscription_id,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

    invalidate_member_auth_cache(group.id)

    if count == 1 do
      {:ok, %{group | default_subscription_id: subscription_id}}
    else
      {:error, :not_found}
    end
  end

  # The auth cache stores the resolved `credit_grants` alongside the member
  # (TTL 60s). Changing a group's default subscription changes every member's
  # grants, so the cache MUST be dropped or the new credit only applies after
  # the TTL — members keep debiting the old grant (or stay on tier 3 unlimited)
  # for up to a minute. Same invalidation `update_subscription/2` performs.
  defp invalidate_member_auth_cache(group_id) do
    case :ets.whereis(Tokengate.Accounts.ApiKeyCache.table()) do
      :undefined -> :ok
      _ -> Tokengate.Accounts.ApiKeyCache.invalidate_group(group_id)
    end

    :ok
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

    * tier 1 (si existe): la sub default del grupo — esté activa o pausada; si
      está pausada el grant vale 0 crédito y bloquea (`grant_state/2`), que es
      lo que debe pasar al pausar: revocar, no liberar;
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

  @doc """
  Grants a intentar para un service: su sub directa, o `[]` (ilimitado, tier 3).

  El grant es `(subscription, service)` — cada service drena su propio
  bolsín aunque la sub la comparta con otros services.
  """
  @spec service_grants(Service.t() | nil) :: [
          %{subscription: Subscription.t(), tier: 1, service_id: term()}
        ]
  def service_grants(nil), do: []

  def service_grants(%Service{} = service) do
    case service_subscription(service) do
      %Subscription{} = subscription ->
        [%{subscription: subscription, tier: 1, service_id: service.id}]

      nil ->
        []
    end
  end

  @doc """
  La sub directa de un service, o `nil` si no tiene ninguna vinculada.

  Cualquier `status`: una sub pausada sigue vinculada y cuenta como grant con 0
  crédito (no como ilimitado). Acepta también un virtual member
  (`service_name` seteado) o un id.
  """
  def service_subscription(%Service{} = service) do
    Repo.preload(service, [:subscription]).subscription
  end

  def service_subscription(%GroupMember{service_name: name} = member)
      when is_binary(name),
      do: member.id |> Repo.get!(Service) |> service_subscription()

  def service_subscription(service_id) when is_binary(service_id) do
    case Repo.get(Service, service_id) do
      nil -> nil
      service -> service_subscription(service)
    end
  end

  @doc """
  La sub default de un grupo, o `nil` si el grupo no tiene ninguna vinculada.

  Devuelve la sub **sea cual sea su `status`**: una sub pausada sigue vinculada
  y debe seguir contando como grant (con 0 crédito, ver `grant_state/2`) en vez
  de desaparecer y dejar a los miembros en tier 3 (ilimitado). Lo que devuelve
  `nil` es desvincular el grupo (o borrar la sub).
  """
  def group_subscription(nil), do: nil

  def group_subscription(group_id) do
    from(g in Group,
      join: s in Subscription,
      on: s.id == g.default_subscription_id,
      where: g.id == ^group_id,
      select: s
    )
    |> Repo.one()
  end

  @doc """
  Sub default **vigente** de un grupo: `nil` si no hay ninguna vinculada o si
  la vinculada está pausada. Para saber si el grupo tiene algo vinculado — y
  por tanto si sus miembros están gateados por crédito — usa
  `group_subscription/1`.
  """
  def active_group_subscription(group_id) do
    case group_subscription(group_id) do
      %Subscription{status: "active"} = subscription -> subscription
      _ -> nil
    end
  end

  @doc """
  Las subs directas del usuario (incluye top-ups), **cualquier status**: una
  sub pausada sigue siendo grant con 0 crédito (ver `grant_state/2`), no un
  permiso para consumir sin tope.
  """
  def direct_subscriptions(nil), do: []

  def direct_subscriptions(user_id) do
    Repo.all(from s in Subscription, where: s.user_id == ^user_id)
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
  ¿La sub ya venció (`expires_at` ≤ `now`)?

  Único lugar donde se decide: lo usan el gate de crédito
  (`grants_credit?/2`) y el badge de top-ups vencidos de la UI, que antes
  duplicaba la comparación y por eso podían discrepar.
  """
  @spec expired?(Subscription.t(), DateTime.t()) :: boolean()
  def expired?(%Subscription{} = subscription, now \\ DateTime.utc_now()) do
    not is_nil(subscription.expires_at) and DateTime.compare(subscription.expires_at, now) != :gt
  end

  @doc """
  ¿La sub otorga crédito ahora mismo? `false` si está pausada, vencida
  (`expired?/2`) o si todavía no empieza (`starts_at` en el futuro).

  `starts_at`/`expires_at` solo los usan en la práctica los top-ups
  (`recurrence = "none"`), pero una fecha explícita se respeta en cualquier
  recurrencia.

  Una sub que no otorga **sigue vinculada y sigue contando como grant, con 0
  crédito** (ver `grant_state/2`): revoca, no libera. El Manager lo consulta en
  cada `ensure_grant_loaded/1` para que pausar/vencer surta efecto sin esperar
  al cambio de ciclo (la entrada de ETS de un grant ya sembrado guardaba el
  crédito viejo).
  """
  @spec grants_credit?(Subscription.t(), DateTime.t()) :: boolean()
  def grants_credit?(%Subscription{} = subscription, now \\ DateTime.utc_now()) do
    subscription.status == "active" and started?(subscription, now) and
      not expired?(subscription, now)
  end

  # Cota abierta cuando `starts_at` es nil.
  defp started?(%Subscription{} = subscription, now) do
    is_nil(subscription.starts_at) or DateTime.compare(subscription.starts_at, now) != :gt
  end

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
  # Service grant: the pocket is (subscription, service) — spend is measured
  # by the service's own request logs.
  def grant_state(%Subscription{} = subscription, subject) do
    %{start: cycle_start} = cycle_bounds(subscription, Date.utc_today())
    {credited, consumed} = credit_state(subscription, subject, cycle_start)

    %{
      credited_micro: credited,
      consumed_micro: consumed,
      cycle_start: cycle_start
    }
  end

  # Sub que otorga crédito: `units` del ciclo + lo arrastrado por rollover.
  #
  # Si no otorga (pausada, vencida o aún no empezada) el grant **sigue
  # existiendo con 0 crédito** en vez de desaparecer. Así el sujeto queda
  # bloqueado (`:budget_exceeded` / 402) y no cae a tier 3 (ilimitado): pausar
  # o vencer revoca el crédito, no lo libera. El consumo se reporta real para
  # que la UI siga mostrando lo gastado.
  defp credit_state(%Subscription{} = subscription, subject, cycle_start) do
    consumed = micro(spend_between(subscription.id, subject, cycle_start, nil))

    if grants_credit?(subscription) do
      credited =
        subscription.units * @credit_micro + carried_micro(subscription, subject, cycle_start)

      {credited, consumed}
    else
      {0, consumed}
    end
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

  @doc """
  Consumo agregado de una suscripción en su ciclo vigente.

  Devuelve `%{credited_micro, consumed_micro, remaining_micro, grants,
  cycle_start}` donde `grants` es el número de grants que la suscripción
  cubre (usuarios con membresía en los grupos que la referencian, o 1 para
  una sub directa). `credited_micro` = `units × grants` (sin rollover, que
  es per-grant y se ve en el dashboard).
  """
  @spec subscription_usage(Subscription.t()) :: %{
          credited_micro: integer(),
          consumed_micro: integer(),
          remaining_micro: integer(),
          grants: non_neg_integer(),
          cycle_start: Date.t() | nil
        }
  def subscription_usage(%Subscription{} = subscription) do
    %{start: cycle_start} = cycle_bounds(subscription, Date.utc_today())
    grants = grant_count(subscription)
    credited = subscription.units * @credit_micro * grants
    consumed = micro(spend_for_subscription(subscription.id, cycle_start))

    %{
      credited_micro: credited,
      consumed_micro: consumed,
      remaining_micro: max(0, credited - consumed),
      grants: grants,
      cycle_start: cycle_start
    }
  end

  @doc """
  Crédito vigente de un usuario: **suma sobre sus grants únicos** (subs
  default de sus grupos, deduplicadas, + subs directas). A diferencia de
  `member_credit/1`, no cuenta dos veces una sub compartida por varios
  grupos del mismo usuario.
  """
  @spec user_credit(term()) :: %{
          credited_micro: integer(),
          consumed_micro: integer(),
          remaining_micro: integer(),
          has_credit?: boolean()
        }
  def user_credit(user_id) do
    group_ids =
      Repo.all(from gm in GroupMember, where: gm.user_id == ^user_id, select: gm.group_id)

    group_subs =
      group_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&group_subscription/1)
      |> Enum.reject(&is_nil/1)

    grants =
      (group_subs ++ direct_subscriptions(user_id))
      |> Enum.uniq_by(& &1.id)

    {credited, consumed} =
      Enum.reduce(grants, {0, 0}, fn sub, {c, k} ->
        state = grant_state(sub, user_id)
        {c + state.credited_micro, k + state.consumed_micro}
      end)

    %{
      credited_micro: credited,
      consumed_micro: consumed,
      remaining_micro: max(0, credited - consumed),
      has_credit?: grants != []
    }
  end

  @doc """
  Crédito vigente de varias membresías en una pasada acotada: **2 queries por
  lote + 1 (o 2) por suscripción distinta**, nunca una por miembro.

  Versión por lotes de `member_credit/1` para los tableros de presupuesto (que
  pintaban "sin límite" porque el límite venía hardcodeado a `nil`). Misma
  forma de retorno, indexada por `member_id`:
  `%{member_id => %{credited_micro, consumed_micro, remaining_micro, has_credit?}}`.
  """
  @spec member_credits([GroupMember.t()]) :: %{term() => map()}
  def member_credits([]), do: %{}

  def member_credits(members) when is_list(members) do
    user_ids = members |> Enum.map(& &1.user_id) |> Enum.uniq()
    group_ids = members |> Enum.map(& &1.group_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    group_subs = group_subscriptions(group_ids)
    direct_subs = subscriptions_by_user_id(user_ids)

    # `%{member_id => {user_id, [subscription]}}` — el sujeto del grant es el
    # usuario, igual que en `grants_for/1`.
    grants =
      Map.new(members, fn member ->
        subs =
          ([Map.get(group_subs, member.group_id)] ++ Map.get(direct_subs, member.user_id, []))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.id)

        {member.id, {member.user_id, subs}}
      end)

    subs =
      grants
      |> Map.values()
      |> Enum.flat_map(fn {_user_id, subs} -> subs end)
      |> Enum.uniq_by(& &1.id)

    consumed = Map.new(subs, &{&1.id, consumed_by_user(&1, user_ids)})
    carried = Map.new(subs, &{&1.id, carried_by_user(&1, user_ids)})

    Map.new(grants, fn {member_id, {user_id, subs}} ->
      {credited, spent} =
        Enum.reduce(subs, {0, 0}, fn sub, {c, k} ->
          {
            c + credited_micro(sub, user_id, Map.get(carried, sub.id, %{})),
            k + Map.get(Map.get(consumed, sub.id, %{}), user_id, 0)
          }
        end)

      {member_id,
       %{
         credited_micro: credited,
         consumed_micro: spent,
         remaining_micro: max(0, credited - spent),
         has_credit?: subs != []
       }}
    end)
  end

  @doc """
  Subs default de varios grupos en una query: `%{group_id => Subscription.t()}`.
  Incluye las pausadas (siguen vinculadas).
  """
  @spec group_subscriptions([term()]) :: %{term() => Subscription.t()}
  def group_subscriptions([]), do: %{}

  def group_subscriptions(group_ids) do
    from(g in Group,
      join: s in Subscription,
      on: s.id == g.default_subscription_id,
      where: g.id in ^group_ids,
      select: {g.id, s}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp subscriptions_by_user_id([]), do: %{}

  defp subscriptions_by_user_id(user_ids) do
    from(s in Subscription, where: s.user_id in ^user_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
  end

  # Crédito del ciclo para un grant. No otorga (pausada / vencida / sin
  # empezar) ⇒ 0 (ver `grants_credit?/2`).
  defp credited_micro(%Subscription{} = subscription, user_id, carried) do
    if grants_credit?(subscription) do
      subscription.units * @credit_micro + Map.get(carried, user_id, 0)
    else
      0
    end
  end

  # `%{user_id => micro}` — consumo asentado de la sub en su ciclo vigente, en
  # una query agrupada por usuario.
  defp consumed_by_user(%Subscription{} = subscription, user_ids) do
    %{start: cycle_start} = cycle_bounds(subscription, Date.utc_today())
    spend_by_user(subscription.id, user_ids, cycle_start, nil)
  end

  # `%{user_id => micro}` — remanente del ciclo anterior arrastrable, solo para
  # subs con rollover (si no, sin query).
  defp carried_by_user(
         %Subscription{recurrence: "monthly", rollover_mode: "rollover"} = subscription,
         user_ids
       ) do
    %{start: cycle_start} = cycle_bounds(subscription, Date.utc_today())
    prev_start = prev_cycle_start(subscription, cycle_start)
    spent = spend_by_user(subscription.id, user_ids, prev_start, cycle_start)

    Map.new(spent, fn {user_id, micro} ->
      unused = max(0, subscription.units * @credit_micro - micro)
      raw = div(unused * (subscription.rollover_pct || 0), 100)

      {user_id,
       case subscription.rollover_cap_units do
         nil -> raw
         cap -> min(raw, cap * @credit_micro)
       end}
    end)
  end

  defp carried_by_user(%Subscription{}, _user_ids), do: %{}

  # `%{user_id => micro}` del gasto atribuido a `subscription_id` en [from, to).
  defp spend_by_user(_subscription_id, [], _from, _to), do: %{}

  defp spend_by_user(subscription_id, user_ids, from, to) do
    RequestLog
    |> join(:inner, [rl], gm in GroupMember, on: gm.id == rl.group_member_id)
    |> where(
      [rl, gm],
      rl.credit_subscription_id == ^subscription_id and gm.user_id in ^user_ids
    )
    |> time_window(from, to)
    |> group_by([_rl, gm], gm.user_id)
    |> select([rl, gm], {gm.user_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {user_id, cost} -> {user_id, micro(cost)} end)
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

  # Gasto asentado de (suscripción, sujeto) en [from, to). `from`/`to` nil →
  # cota abierta (top-ups sin `starts_at` suman todo lo atribuido). El sujeto
  # es el usuario (grant por membresía) o `{:service, id}` (grant por service).
  defp spend_between(subscription_id, {:service, service_id} = _subject, from, to) do
    query =
      RequestLog
      |> where(
        [rl],
        rl.credit_subscription_id == ^subscription_id and rl.service_id == ^service_id
      )

    query = time_window(query, from, to)
    aggregate(query)
  end

  defp spend_between(subscription_id, user_id, from, to) do
    query =
      RequestLog
      |> join(:inner, [rl], gm in GroupMember, on: gm.id == rl.group_member_id)
      |> where([rl, gm], rl.credit_subscription_id == ^subscription_id and gm.user_id == ^user_id)

    query = time_window(query, from, to)
    aggregate(query)
  end

  defp time_window(query, from, to) do
    query =
      if from do
        where(query, [rl], rl.inserted_at >= ^to_datetime(from))
      else
        query
      end

    if to do
      where(query, [rl], rl.inserted_at < ^to_datetime(to))
    else
      query
    end
  end

  defp aggregate(query) do
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

  # Número de grants que cubre una suscripción: los miembros de los grupos
  # que la referencian + los services vinculados directamente, o 1 para una
  # sub directa de usuario.
  defp grant_count(%Subscription{user_id: nil} = subscription),
    do: subscription |> grant_subjects() |> length()

  defp grant_count(%Subscription{user_id: user_id}) when not is_nil(user_id), do: 1

  # Sujetos con grant de una sub de grupo: los usuarios de los grupos que la
  # referencian + los services con `subscription_id` directa.
  defp grant_subjects(subscription) do
    group_ids = group_ids_for(subscription)

    user_ids =
      if group_ids == [] do
        []
      else
        Repo.all(from gm in GroupMember, where: gm.group_id in ^group_ids, select: gm.user_id)
        |> Enum.uniq()
      end

    service_ids =
      Repo.all(
        from s in Tokengate.Accounts.Service,
          where: s.subscription_id == ^subscription.id,
          select: {:service, s.id}
      )

    user_ids ++ service_ids
  end

  # Gasto agregado de TODA la suscripción (todos sus grants) desde `from`
  # (`nil` → cota abierta).
  defp spend_for_subscription(subscription_id, from) do
    query =
      RequestLog
      |> where([rl], rl.credit_subscription_id == ^subscription_id)

    query =
      if from do
        where(query, [rl], rl.inserted_at >= ^to_datetime(from))
      else
        query
      end

    query
    |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> Repo.one()
  end

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
