defmodule TokengateWeb.CreditHelpers do
  @moduledoc """
  Helpers compartidos por las dos páginas de la sección Crédito
  (`SubscriptionsLive` y `TopupsLive`): búsqueda de usuarios (chips), orden de
  tabla, celda de consumo, etiqueta de objetivo y el predicado de auto-archivo
  de top-ups.

  Vive en un solo módulo —y no duplicado en cada LiveView— por el mismo motivo
  por el que `Credits.expired?/1` es único: dos copias de la misma regla
  terminan discrepando (la UI decía "vencida" mientras el proxy seguía
  otorgando el saldo).

  Convención de uso:
      alias TokengateWeb.CreditHelpers, as: Credit
      import TokengateWeb.CreditHelpers, only: [sort_button: 1]
  """

  use TokengateWeb, :html

  alias Tokengate.Accounts
  alias Tokengate.Credits
  alias Tokengate.Credits.Subscription

  ## Picker de usuarios -----------------------------------------------------

  @doc "Coincidencias del buscador de usuarios, excluyendo los ya elegidos."
  def users_search(query, selected_ids) do
    if is_binary(query) and String.trim(query) != "" do
      query
      |> String.trim()
      |> Accounts.search_users(25)
      |> Enum.reject(&(&1.id in selected_ids))
    else
      []
    end
  end

  @doc "Chip `%{id: id, label: label}` del usuario `user_id`, o `[]` si no aplica."
  def user_tag(_users, nil), do: []

  def user_tag(users, user_id) do
    case Enum.find(users, &(&1.id == user_id)) do
      nil -> [%{id: user_id, label: "Usuario"}]
      u -> [%{id: user_id, label: u.name || u.email}]
    end
  end

  ## Orden de tabla ---------------------------------------------------------

  def to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  def toggle_sort_direction(:asc), do: :desc
  def toggle_sort_direction(:desc), do: :asc

  def default_direction_for(field, desc_fields),
    do: if(field in desc_fields, do: :desc, else: :asc)

  @doc """
  Ordena `rows` según `value_fun` y `direction`. Los valores nil se ordenan
  primero (orden de términos de Erlang: átomo `nil` < structs).
  """
  def sort_rows(rows, direction, value_fun) do
    Enum.sort_by(rows, value_fun, fn a, b ->
      if direction == :asc, do: compare_vals(a, b) != :gt, else: compare_vals(a, b) != :lt
    end)
  end

  defp compare_vals(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)

  defp compare_vals(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  ## Etiquetas de estado ----------------------------------------------------

  def status_label("active"), do: "Activa"
  def status_label("paused"), do: "Pausada"
  def status_label(other), do: other || "—"

  def topup_status_label("active"), do: "Activo"
  def topup_status_label("paused"), do: "Pausado"
  def topup_status_label(other), do: other || "—"

  ## Auto-archivo (top-ups) -------------------------------------------------

  @doc """
  ¿Este top-up se auto-archiva en el listado vigente?

  Top-ups (`recurrence = "none"`) **vencidos** (su `expires_at` ya pasó) o
  **agotados** (todo el crédito otorgado fue consumido: remanente = 0). Las
  subs mensuales se reciclan cada ciclo, así que nunca se auto-archivan.

  El vencimiento se delega en `Credits.expired?/1` — el MISMO predicado que
  usa el gate de crédito: duplicar la comparación fue lo que dejó que el
  badge dijera "vencido" mientras el proxy seguía otorgando el saldo.
  """
  def expired_or_drained?(%Subscription{recurrence: "none"} = sub) do
    expired? = Credits.expired?(sub)

    drained? =
      sub.units > 0 and sub.units * 1_000_000 <= Credits.lifetime_spend_micro(sub.id)

    expired? or drained?
  end

  def expired_or_drained?(%Subscription{}), do: false

  @doc "¿Esta sub está auto-archivada en el listado vigente?"
  def archived?(%Subscription{} = sub, archived_ids),
    do: MapSet.member?(archived_ids, sub.id)

  @doc "Motivo del badge de archivo: Vencido/Agotado para top-ups, Archivada si no."
  def archived_reason(%Subscription{} = sub) do
    drained? =
      sub.units > 0 and sub.units * 1_000_000 <= Credits.lifetime_spend_micro(sub.id)

    cond do
      Credits.expired?(sub) -> "Vencido"
      drained? -> "Agotado"
      true -> "Archivado"
    end
  end

  ## Consumo ----------------------------------------------------------------

  @doc "Consumo del ciclo vigente por sub: `%{sub.id => {usage, sub}}`."
  def usage_by_sub(subs) do
    Map.new(subs, fn sub -> {sub.id, {Credits.subscription_usage(sub), sub}} end)
  end

  # "%{credited_micro, consumed_micro}" → "X / Y (Z%)" en créditos
  # (micro-USD → USD; 1 crédito = $1). "—" cuando la sub no otorga crédito.
  def usage_label(%{credited_micro: 0}, _sub), do: "—"

  def usage_label(%{consumed_micro: consumed_micro}, sub) do
    used =
      Decimal.new(consumed_micro)
      |> Decimal.div(Decimal.new(1_000_000))
      |> Decimal.round(2)

    allocated = Decimal.new(sub.units)

    cond do
      Decimal.compare(used, allocated) == :gt -> "#{used} / #{allocated} (excedido)"
      Decimal.compare(allocated, 0) == :eq -> "#{used} / 0"
      true -> "#{used} / #{allocated} (#{pct_label(used, allocated)}%)"
    end
  end

  defp pct_label(used, allocated) do
    Decimal.mult(Decimal.div(used, allocated), 100) |> Decimal.round(0)
  end

  # Celda de la columna "Consumo": label + barra de progreso (colores del
  # dashboard: verde < 70%, ámbar < 90%, rojo ≥ 90%).
  def render_usage_cell(sub, assigns) do
    assigns =
      case Map.get(assigns.usage_by_sub, sub.id) do
        nil -> %{usage: nil, sub: sub}
        {usage, sub} -> %{usage: usage, sub: sub}
      end

    assigns =
      Map.put(assigns, :label, usage_label(assigns.usage || %{credited_micro: 0}, sub))

    assigns =
      Map.put(
        assigns,
        :pct,
        case assigns.usage do
          nil -> nil
          %{credited_micro: 0} -> nil
          %{credited_micro: c, consumed_micro: k} -> Float.round(k / c * 100, 1)
        end
      )

    assigns =
      Map.put(
        assigns,
        :bar_class,
        cond do
          is_nil(assigns.pct) -> "bg-base-300"
          assigns.pct >= 90 -> "bg-error"
          assigns.pct >= 70 -> "bg-warning"
          true -> "bg-success"
        end
      )

    assigns =
      Map.put(
        assigns,
        :width,
        if(is_nil(assigns.pct), do: "width: 0%", else: "width: #{min(assigns.pct, 100)}%")
      )

    ~H"""
    <div class="text-xs font-mono">{@label}</div>
    <div class="mt-1 h-1.5 rounded-full bg-base-200 overflow-hidden">
      <div class={["h-full rounded-full transition-all", @bar_class]} style={@width}></div>
    </div>
    """
  end

  @doc "Etiqueta del objetivo: los grupos (default) o el usuario directo."
  def target_label(sub, assigns) do
    case Map.get(assigns.groups_by_sub || %{}, sub.id, []) do
      [] ->
        if sub.user_id do
          case Enum.find(assigns.users, &(&1.id == sub.user_id)) do
            nil -> "Usuario"
            u -> "Usuario: #{u.name || u.email}"
          end
        else
          "Sin grupo asignado"
        end

      groups ->
        Enum.map_join(groups, ", ", & &1.name)
    end
  end

  ## Componentes ------------------------------------------------------------

  attr :event, :string, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :current, :atom, required: true
  attr :direction, :atom, required: true
  attr :align, :string, default: "left"

  def sort_button(assigns) do
    ~H"""
    <button
      phx-click={@event}
      phx-value-field={@field}
      class={[
        "flex items-center gap-1 hover:text-primary",
        @align == "right" && "justify-end w-full"
      ]}
      id={"sort-#{@field}"}
    >
      {@label}
      <span class="inline-block w-3 text-center">
        <%= if @current == @field do %>
          {if @direction == :asc, do: "▲", else: "▼"}
        <% end %>
      </span>
    </button>
    """
  end
end
