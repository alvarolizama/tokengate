defmodule TokengateWeb.TopupHelpers do
  @moduledoc """
  Helpers de la página de Top-ups: formateo, estado y consumo.

  El crédito extra de un solo uso vive en `credit_topups` (usuario **o**
  servicio, con expiración opcional). El consumo se mide contra los logs
  (`request_logs.credit_topup_id`), no contra un contador.
  """

  use Phoenix.Component

  alias Tokengate.Credits.Topups

  # ---------------------------------------------------------------------------
  # Botón de orden
  # ---------------------------------------------------------------------------

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort_field, :atom, required: true
  attr :sort_direction, :atom, required: true

  def sort_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="sort_topups"
      phx-value-field={@field}
      class="inline-flex items-center gap-1 hover:text-primary transition-colors"
    >
      {@label}
      <%= cond do %>
        <% @sort_field != @field -> %>
          <span class="opacity-30">↕</span>
        <% @sort_direction == :asc -> %>
          <span>↑</span>
        <% true -> %>
          <span>↓</span>
      <% end %>
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Etiquetas y estado
  # ---------------------------------------------------------------------------

  @doc "Nombre del dueño del top-up (usuario o servicio)."
  def owner_label(%{user: %{email: email}}) when is_binary(email), do: email
  def owner_label(%{service: %{name: name}}) when is_binary(name), do: name
  def owner_label(%{user_id: id}) when is_binary(id), do: "usuario"
  def owner_label(_), do: "—"

  @doc "Tipo de dueño, para la columna."
  def owner_type(%{user_id: id}) when is_binary(id), do: "Usuario"
  def owner_type(_), do: "Servicio"

  @doc "Etiqueta legible de la expiración."
  def expires_label(nil), do: "Nunca"

  def expires_label(%DateTime{} = dt) do
    dt |> DateTime.to_date() |> Date.to_string()
  end

  @doc """
  Estado efectivo del top-up: el declarado, o `expired`/`exhausted` cuando el
  tiempo o el consumo ya lo desactivaron (aunque la fila siga `active`).
  """
  def state(topup) do
    cond do
      topup.status == "revoked" -> :revoked
      expired?(topup) -> :expired
      exhausted?(topup) -> :exhausted
      true -> :active
    end
  end

  def state_label(:active), do: "Activo"
  def state_label(:revoked), do: "Revocado"
  def state_label(:expired), do: "Vencido"
  def state_label(:exhausted), do: "Agotado"

  def state_badge_class(:active), do: "badge-success"
  def state_badge_class(:revoked), do: "badge-error"
  def state_badge_class(:expired), do: "badge-warning"
  def state_badge_class(:exhausted), do: "badge-ghost"

  @doc "¿Venció? (nil = nunca vence)."
  def expired?(%{expires_at: nil}), do: false

  def expired?(%{expires_at: %DateTime{} = dt}),
    do: DateTime.compare(dt, DateTime.utc_now()) != :gt

  @doc "¿Se agotó el remanente?"
  def exhausted?(topup), do: Decimal.compare(Topups.remaining_usd(topup), 0) != :gt

  @doc "¿Se archiva (vencido o agotado)?"
  def archived?(topup), do: state(topup) in [:expired, :exhausted]

  @doc "Motivo del archivo, para el badge."
  def archived_reason(topup) do
    case state(topup) do
      :expired -> "Venció"
      :exhausted -> "Agotado"
      :revoked -> "Revocado"
      _ -> nil
    end
  end

  @doc "Opciones del selector de expiración (nil = sin expiración)."
  def expiry_options do
    [
      {"Sin expiración", ""},
      {"1 día", "1"},
      {"3 días", "3"},
      {"7 días", "7"},
      {"14 días", "14"},
      {"30 días", "30"},
      {"60 días", "60"},
      {"90 días", "90"}
    ]
  end

  @doc "Formatea un Decimal USD con dos decimales."
  def usd(nil), do: "—"

  def usd(%Decimal{} = d) do
    d
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> then(&"$#{&1}")
  end

  @doc "Porcentaje consumido del monto otorgado (0-100)."
  def consumed_pct(topup) do
    amount = topup.amount_usd
    consumed = Topups.consumed_usd(topup)

    if Decimal.compare(amount, 0) != :gt do
      0.0
    else
      consumed
      |> Decimal.div(amount)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_float()
      |> min(100.0)
    end
  end
end
