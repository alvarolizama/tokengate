defmodule Tokengate.Budgets do
  @moduledoc """
  Budget visibility: per-member spend vs effective limits.

  The enforcement hot path lives in `Tokengate.Budgets.Manager` (ETS
  counters). This context is the read side for dashboards: it combines
  `Tokengate.Accounts.effective_limits/1` with the manager's spend
  counters into a single `member_budget` map per group member.

  A member is **exhausted** when their daily or monthly spend reached the
  effective limit — the proxy already rejects their requests with 402.
  """

  import Ecto.Query
  alias Tokengate.{Accounts, Repo}
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Budgets.{Exemptions, Manager}
  alias Tokengate.GlobalSettings
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Periods

  @default_timezone "Etc/UTC"

  @type member_budget :: %{
          member: GroupMember.t(),
          daily_spend_usd: Decimal.t(),
          monthly_spend_usd: Decimal.t(),
          daily_limit_usd: Decimal.t() | nil,
          monthly_limit_usd: Decimal.t() | nil,
          daily_pct: float() | nil,
          monthly_pct: float() | nil,
          daily_exhausted?: boolean(),
          monthly_exhausted?: boolean(),
          exhausted?: boolean(),
          real_monthly_spend_usd: Decimal.t(),
          has_credit?: boolean(),
          credit_remaining_usd: Decimal.t() | nil,
          unlimited?: boolean(),
          remaining_topup_usd: Decimal.t()
        }

  @doc """
  Lists a `member_budget` map for every group member (user and group
  preloaded on `:member`), ordered by most recently created first.

  `list_member_budgets/1` computes daily/monthly spend from Postgres using
  **local calendar boundaries** for the given timezone (2 aggregate queries,
  independent of member count). `list_member_budgets/0` keeps the legacy
  ETS-counter behavior (UTC periods).

  El **límite** de cada miembro es el efectivo (propio o el del grupo, vía
  `Credits.summaries/1`, resuelto en lote) y el gasto que cuenta contra él es
  el del mes UTC. Los top-ups vigentes son el segundo camino de gasto;
  `unlimited_spend` es el único camino a ilimitado.
  """
  @spec list_member_budgets() :: [member_budget()]
  def list_member_budgets do
    members = list_members_with_group_and_user()
    credits = Tokengate.Credits.summaries(members)

    Enum.map(members, fn member ->
      member_budget(member, Manager.spend(member.id), Map.get(credits, member.id))
    end)
  end

  @spec list_member_budgets(String.t()) :: [member_budget()]
  def list_member_budgets(timezone) do
    members = list_members_with_group_and_user()
    spend = spend_by_member_ids(Enum.map(members, & &1.id), timezone)
    credits = Tokengate.Credits.summaries(members)

    Enum.map(members, &member_budget(&1, spend, Map.get(credits, &1.id)))
  end

  defp list_members_with_group_and_user do
    GroupMember
    |> preload([:user, :group])
    |> order_by([tm], desc: tm.inserted_at)
    |> Repo.all()
  end

  @doc """
  Monthly spend per service from Postgres using LOCAL calendar boundaries
  for the given timezone. One aggregate query total.

  Each row:

      %{
        service: Service.t(),
        monthly_spend_usd: Decimal.t(),
        monthly_limit_usd: Decimal.t() | nil,
        monthly_pct: float() | nil,
        exhausted?: boolean()
      }

  Ordered by highest monthly spend first.
  """
  @spec list_service_budgets() :: [service_budget()]
  def list_service_budgets do
    services = Repo.all(from(s in Accounts.Service))
    summaries = Tokengate.Credits.service_summaries(services)

    services
    |> Enum.map(fn service ->
      summary = Map.fetch!(summaries, service.id)

      # El camino de gasto del servicio: ilimitado, límite con remanente, o
      # top-ups. Sin ninguno de los tres, `has_path?` es false y el proxy
      # responde 402 con la capa `:no_credit`.
      #
      # Mismo shape de crédito que `member_budget/1`: `has_credit?` = el
      # sujeto tiene límite mensual definido (el del servicio, que no hereda
      # de nadie), `credit_remaining_usd` = lo que le queda de ese límite.
      # `monthly_spend_usd` es, en ambos, el gasto debitado al LÍMITE
      # (`summary.limit_spend_usd`), no el gasto real del mes.
      %{
        service: service,
        monthly_spend_usd: summary.limit_spend_usd,
        monthly_limit_usd: summary.limit_usd,
        monthly_pct: pct(summary.limit_spend_usd, summary.limit_usd),
        exhausted?: not summary.has_path?,
        real_monthly_spend_usd: summary.spend_usd,
        has_credit?: not is_nil(summary.limit_usd),
        credit_remaining_usd: summary.remaining_limit_usd,
        unlimited?: summary.unlimited?,
        remaining_topup_usd: summary.remaining_topup_usd
      }
    end)
    |> Enum.sort_by(fn row -> Decimal.to_float(row.monthly_spend_usd) end, :desc)
  end

  @typedoc """
  Service-level budget view: the service's own monthly cap vs its real
  spend in the UTC month.

  Mismo shape de crédito que `t:member_budget/0` (`has_credit?`,
  `credit_remaining_usd`, `unlimited?`, `remaining_topup_usd`): la clave de
  identidad (`:service` vs `:member`) y las columnas de día local del miembro
  (`daily_*`, `monthly_exhausted?`, que en el miembro son display legacy) son
  las únicas diferencias. Un servicio no tiene ventana diaria.
  """
  @type service_budget :: %{
          service: Tokengate.Accounts.Service.t(),
          monthly_spend_usd: Decimal.t(),
          monthly_limit_usd: Decimal.t() | nil,
          monthly_pct: float() | nil,
          exhausted?: boolean(),
          real_monthly_spend_usd: Decimal.t(),
          has_credit?: boolean(),
          credit_remaining_usd: Decimal.t() | nil,
          unlimited?: boolean(),
          remaining_topup_usd: Decimal.t()
        }

  @doc """
  Org-wide global daily cap summary — the honest replacement for the old
  monthly budget rollup: the monthly limit belongs to each subject (never to
  the org), and the only org-wide spend guard is the
  **global daily cap** (`GlobalSettings.daily_max_spend_usd`, kill-switch
  layer 2, UTC day).

  The spend is real spend from `request_logs` (via `Logs.cost_summary/1`)
  over `from` (default: start of the current UTC day), NOT the live ETS
  enforcement counter — that one includes in-flight `$max_request_cost_usd`
  holds and drifts on crashes, so it "breathes" (jumps $20 per in-flight
  request, drops on settle) and must never back a display number. It still
  backs enforcement itself (`Budgets.Manager`) and the maintenance screen.

  Exempted subjects (`global_daily` exemptions) skip the kill-switch layer
  in the proxy but their spend IS included here — the card reports real
  money spent — they are listed separately as `exempt_count`.

  `nil` cap means unlimited (no kill-switch configured).

  La ventana es siempre la del tope (día UTC): no acepta un `from` arbitrario
  porque cualquier otro rango haría que la barra y el % compararan un gasto
  contra un cap que mide otro período.
  """
  @spec global_daily_budget_summary() :: %{
          daily_spend_usd: Decimal.t(),
          daily_cap_usd: Decimal.t() | nil,
          daily_pct: float() | nil,
          exempt_count: non_neg_integer()
        }
  def global_daily_budget_summary do
    spend =
      %{from: Manager.utc_day_start()}
      |> Logs.cost_summary()
      |> Map.get(:total_cost_usd, Decimal.new(0))

    %{
      daily_spend_usd: spend,
      daily_cap_usd: GlobalSettings.get_daily_cap(),
      daily_pct: nil,
      exempt_count: Exemptions.count_for_scope("global_daily")
    }
    |> put_daily_pct()
  end

  defp put_daily_pct(%{daily_cap_usd: nil} = summary), do: summary

  defp put_daily_pct(%{daily_spend_usd: spend, daily_cap_usd: cap} = summary) do
    %{summary | daily_pct: pct(spend, cap)}
  end

  @doc "Lists only the member budgets that hit a daily or monthly limit."
  @spec list_exhausted_member_budgets() :: [member_budget()]
  def list_exhausted_member_budgets do
    list_member_budgets() |> Enum.filter(& &1.exhausted?)
  end

  @spec list_exhausted_member_budgets(String.t()) :: [member_budget()]
  def list_exhausted_member_budgets(timezone) do
    list_member_budgets(timezone) |> Enum.filter(& &1.exhausted?)
  end

  @doc "Number of members currently blocked by a budget limit."
  @spec count_exhausted() :: non_neg_integer()
  def count_exhausted do
    list_exhausted_member_budgets() |> length()
  end

  @spec count_exhausted(String.t()) :: non_neg_integer()
  def count_exhausted(timezone) do
    list_exhausted_member_budgets(timezone) |> length()
  end

  @typedoc """
  Group-level budget rollup: the monthly cap is the SUM of each member's
  effective monthly limit, and the spend is the SUM of each member's
  monthly spend (real). Members without a monthly limit don't add to the
  cap and set `has_unlimited?`.
  """
  @type group_budget :: %{
          group: Tokengate.Accounts.Group.t(),
          member_count: non_neg_integer(),
          monthly_limit_usd: Decimal.t() | nil,
          monthly_spend_usd: Decimal.t(),
          monthly_pct: float() | nil,
          has_unlimited?: boolean(),
          real_monthly_spend_usd: Decimal.t()
        }

  @doc """
  Rolls `list_member_budgets/0` up to the group level. Groups without
  members don't appear. Ordered by highest monthly spend first.

  `list_group_budgets/1` uses timezone-local spend from Postgres.
  """
  @spec list_group_budgets() :: [group_budget()]
  def list_group_budgets do
    list_member_budgets() |> rollup_group_budgets()
  end

  @spec list_group_budgets(String.t()) :: [group_budget()]
  def list_group_budgets(timezone) do
    list_member_budgets(timezone) |> rollup_group_budgets()
  end

  @doc """
  Rolls a list of member budgets (from `list_member_budgets/0,1`) up to the
  group level. Exposed so callers that already loaded member budgets (e.g.
  CreditsLive) can derive the group rollup without re-querying members and
  recomputing spend.
  """
  def rollup_group_budgets(member_budgets) do
    member_budgets
    |> Enum.group_by(fn mb -> mb.member.group_id end)
    |> Enum.map(fn {_group_id, budgets} ->
      limits = Enum.map(budgets, & &1.monthly_limit_usd)

      monthly_limit_usd =
        if Enum.all?(limits, &is_nil/1) do
          nil
        else
          limits |> Enum.reject(&is_nil/1) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        end

      monthly_spend_usd =
        Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.monthly_spend_usd, &2))

      real_monthly_spend_usd =
        Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.real_monthly_spend_usd, &2))

      %{
        group: hd(budgets).member.group,
        member_count: length(budgets),
        monthly_limit_usd: monthly_limit_usd,
        monthly_spend_usd: monthly_spend_usd,
        real_monthly_spend_usd: real_monthly_spend_usd,
        monthly_pct: pct(monthly_spend_usd, monthly_limit_usd),
        # `nil` ya NO significa ilimitado: lo dice el flag del sujeto.
        has_unlimited?: Enum.any?(budgets, &Map.get(&1, :unlimited?, false))
      }
    end)
    |> Enum.sort_by(fn row -> Decimal.to_float(row.monthly_spend_usd) end, :desc)
  end

  @doc """
  Lists `member_budget` maps for every group membership of a single user —
  the per-user read behind the personal topbar chip (each user sees only
  their own data). Ordered by most recently created first.

  `list_member_budgets_for_user/2` uses timezone-local spend from Postgres.
  """
  @spec list_member_budgets_for_user(term()) :: [member_budget()]
  def list_member_budgets_for_user(user_id) do
    members =
      GroupMember
      |> where([tm], tm.user_id == ^user_id)
      |> preload([:user, :group])
      |> order_by([tm], desc: tm.inserted_at)
      |> Repo.all()

    credits = Tokengate.Credits.summaries(members)

    Enum.map(members, fn member ->
      member_budget(member, Manager.spend(member.id), Map.get(credits, member.id))
    end)
  end

  @spec list_member_budgets_for_user(term(), String.t()) :: [member_budget()]
  def list_member_budgets_for_user(user_id, timezone) do
    members =
      GroupMember
      |> where([tm], tm.user_id == ^user_id)
      |> preload([:user, :group])
      |> order_by([tm], desc: tm.inserted_at)
      |> Repo.all()

    spend = spend_by_member_ids(Enum.map(members, & &1.id), timezone)
    credits = Tokengate.Credits.summaries(members)

    Enum.map(members, &member_budget(&1, spend, Map.get(credits, &1.id)))
  end

  @doc """
  Per-user spend rollup across all their group memberships.

  Returns `%{user_id => %{daily_usd: Decimal, monthly_usd: Decimal,
  exhausted?: boolean}}` — used by the admin users page.
  """
  @spec spend_by_user() :: %{
          term() => %{
            monthly_usd: Decimal.t(),
            exhausted?: boolean()
          }
        }
  def spend_by_user do
    list_member_budgets() |> rollup_user_spend()
  end

  @spec spend_by_user(String.t()) :: %{
          term() => %{
            monthly_usd: Decimal.t(),
            exhausted?: boolean()
          }
        }
  def spend_by_user(timezone) do
    list_member_budgets(timezone) |> rollup_user_spend()
  end

  defp rollup_user_spend(member_budgets) do
    member_budgets
    |> Enum.group_by(fn mb -> mb.member.user_id end)
    |> Map.new(fn {user_id, budgets} ->
      monthly_limit =
        budgets
        |> Enum.map(& &1.monthly_limit_usd)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          limits -> Enum.reduce(limits, &Decimal.add/2)
        end

      # Cada membresía reporta el gasto del MISMO sujeto (el usuario), así que
      # sumarlas lo contaría N veces: se toma el valor (idéntico) una sola vez.
      monthly_usd = budgets |> Enum.map(& &1.monthly_spend_usd) |> Enum.max()

      real_monthly_usd = budgets |> Enum.map(& &1.real_monthly_spend_usd) |> Enum.max()

      {user_id,
       %{
         daily_usd: Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.daily_spend_usd, &2)),
         monthly_usd: monthly_usd,
         real_monthly_usd: real_monthly_usd,
         monthly_limit_usd: monthly_limit,
         monthly_pct: pct(monthly_usd, monthly_limit),
         exhausted?: Enum.all?(budgets, & &1.exhausted?)
       }}
    end)
  end

  @doc "Builds the budget status map for a single group member (ETS counters)."
  @spec member_budget(GroupMember.t()) :: member_budget()
  def member_budget(%GroupMember{} = member) do
    credits = Tokengate.Credits.summaries([member])

    member_budget(member, Manager.spend(member.id), Map.get(credits, member.id))
  end

  # Variante por lotes: el resumen del sujeto ya viene resuelto
  # (`Credits.summaries/1`) para no disparar queries por miembro.
  #
  # El límite es el efectivo (propio o del grupo) y el gasto que cuenta contra
  # él es el del mes UTC; los top-ups son el segundo camino. `exhausted?` es
  # «sin camino de gasto»: límite agotado/sin límite, no ilimitado y sin
  # top-ups — exactamente lo que el proxy bloquea con 402.
  defp member_budget(%GroupMember{} = member, spend, summary) do
    {daily_usd, monthly_usd} = member_spend(spend, member.id)

    case summary do
      %{limit_usd: limit_usd, unlimited?: unlimited?, limit_spend_usd: spent_usd} = summary ->
        %{
          member: member,
          daily_spend_usd: daily_usd,
          monthly_spend_usd: spent_usd,
          daily_limit_usd: nil,
          monthly_limit_usd: limit_usd,
          daily_pct: nil,
          monthly_pct: pct(spent_usd, limit_usd),
          daily_exhausted?: false,
          monthly_exhausted?: not summary.has_path?,
          exhausted?: not summary.has_path?,
          real_monthly_spend_usd: monthly_usd,
          # `has_credit?` = el sujeto tiene límite mensual definido (propio o
          # heredado). Un sujeto ilimitado o sin límite no lo tiene.
          has_credit?: not is_nil(limit_usd),
          credit_remaining_usd: summary.remaining_limit_usd,
          unlimited?: unlimited?,
          remaining_topup_usd: summary.remaining_topup_usd
        }

      nil ->
        # Sin resumen (no debería pasar): sin límite ni camino conocido.
        %{
          member: member,
          daily_spend_usd: daily_usd,
          monthly_spend_usd: monthly_usd,
          daily_limit_usd: nil,
          monthly_limit_usd: nil,
          daily_pct: nil,
          monthly_pct: nil,
          daily_exhausted?: false,
          monthly_exhausted?: true,
          exhausted?: true,
          real_monthly_spend_usd: monthly_usd,
          has_credit?: false,
          credit_remaining_usd: nil,
          unlimited?: false,
          remaining_topup_usd: Decimal.new(0)
        }
    end
  end

  # Gastos del miembro: del contador ETS (`%{daily_usd:, monthly_usd:}`) o del
  # mapa de Postgres por lotes (`%{daily: %{member_id => _}, monthly: ...}`).
  defp member_spend(%{daily_usd: daily, monthly_usd: monthly}, _member_id), do: {daily, monthly}

  defp member_spend(%{} = spend, member_id) do
    {get_in(spend, [:daily, member_id]) || Decimal.new(0),
     get_in(spend, [:monthly, member_id]) || Decimal.new(0)}
  end

  @doc """
  Daily/monthly spend per member from Postgres. Daily uses the viewer's LOCAL
  day (display-only: members have no daily cap to agree with); monthly uses the
  UTC month — the window the monthly budget actually resets on. Two aggregate
  queries total (independent of member count). Returns
  `%{daily: %{member_id => Decimal}, monthly: %{member_id => Decimal}}`.
  """
  @spec spend_by_member_ids([term()], String.t()) :: %{
          daily: %{term() => Decimal.t()},
          monthly: %{term() => Decimal.t()}
        }
  def spend_by_member_ids(member_ids, timezone \\ @default_timezone)

  def spend_by_member_ids([], _timezone), do: %{daily: %{}, monthly: %{}}

  def spend_by_member_ids(member_ids, timezone) do
    %{
      daily: member_spend_map(member_ids, Periods.start_of_day_utc(timezone)),
      # Mes UTC: la ventana en que resetea el presupuesto mensual de cada
      # sujeto (Budgets.Manager), no el mes local del visor.
      monthly: member_spend_map(member_ids, Periods.start_of_month_utc("Etc/UTC"))
    }
  end

  @doc "Monthly spend for a single member in the UTC month (display)."
  def monthly_spend_for_member(member_id) do
    member_spend_map([member_id], Periods.start_of_month_utc("Etc/UTC"))
    |> Map.get(member_id, Decimal.new(0))
  end

  @doc "Daily spend for a single member in the local day (display)."
  def daily_spend_for_member(member_id, timezone \\ @default_timezone) do
    member_spend_map([member_id], Periods.start_of_day_utc(timezone))
    |> Map.get(member_id, Decimal.new(0))
  end

  defp member_spend_map(member_ids, from) do
    RequestLog
    |> where([rl], rl.group_member_id in ^member_ids and rl.inserted_at >= ^from)
    |> group_by([rl], rl.group_member_id)
    |> select([rl], {rl.group_member_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
  end

  @doc """
  Per-service monthly spend (UTC month). Returns
  `%{service_id => Decimal.t()}` — used by the admin services page for the
  "Gasto mensual" column. Services have no `group_member_id`; their logs carry
  `service_id`.
  """
  @spec spend_by_service() :: %{term() => Decimal.t()}
  def spend_by_service do
    service_spend_map(Periods.start_of_month_utc("Etc/UTC"))
  end

  defp service_spend_map(from) do
    RequestLog
    |> where([rl], not is_nil(rl.service_id) and rl.inserted_at >= ^from)
    |> group_by([rl], rl.service_id)
    |> select([rl], {rl.service_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
  end

  @doc """
  Last request timestamp per member, across all time.
  Returns `%{member_id => DateTime.t()}` — members without requests are missing.
  """
  @spec last_requests_by_member_ids([term()]) :: %{term() => DateTime.t()}
  def last_requests_by_member_ids(member_ids) do
    RequestLog
    |> where([rl], rl.group_member_id in ^member_ids)
    |> group_by([rl], rl.group_member_id)
    |> select([rl], {rl.group_member_id, max(rl.inserted_at)})
    |> Repo.all()
    |> Map.new()
  end

  # Percentage of the limit consumed. `nil` limit = unlimited (no bar).
  # A zero (or negative) limit blocks every request, so it reads as 100%.
  defp pct(_spend, nil), do: nil

  defp pct(spend, limit) do
    if Decimal.compare(limit, Decimal.new(0)) == :gt do
      spend
      |> Decimal.div(limit)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.to_float()
      |> Float.round(1)
    else
      100.0
    end
  end
end
