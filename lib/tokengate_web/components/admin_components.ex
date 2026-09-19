defmodule TokengateWeb.AdminComponents do
  @moduledoc """
  Componentes compartidos por las vistas de administración (Usuarios,
  Servicios, ...). Estandarizan el header con búsqueda, la tabla, la celda
  de identidad, los estados vacíos y los modales, para que las páginas se
  vean y se comporten igual.

  Se importan explícitamente en cada LiveView que los usa:

      import TokengateWeb.AdminComponents
  """

  use Phoenix.Component
  use Gettext, backend: TokengateWeb.Gettext

  import TokengateWeb.CoreComponents

  # ---------------------------------------------------------------------------
  # Búsqueda de header
  # ---------------------------------------------------------------------------

  @doc """
  Form de búsqueda del header (icono + input), idéntico en todas las páginas.
  Emite el evento `@event` con `%{"q" => valor}`.
  """
  attr :event, :string, required: true, doc: "evento phx-change/phx-submit"
  attr :value, :string, default: "", doc: "valor actual del input"
  attr :placeholder, :string, required: true
  attr :input_id, :string, required: true

  def admin_search(assigns) do
    ~H"""
    <.form for={%{}} phx-change={@event} phx-submit={@event} id="search-form">
      <div class="relative">
        <.icon
          name="hero-magnifying-glass"
          class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
        />
        <input
          type="text"
          name="q"
          placeholder={@placeholder}
          value={@value}
          phx-debounce="300"
          class="input input-sm input-bordered pl-9 w-64"
          id={@input_id}
        />
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # Botón de ordenamiento de columna
  # ---------------------------------------------------------------------------

  @doc """
  Header de columna ordenable. Emite `@event` con `%{"field" => @field}` y
  muestra ▲/▼ según `@current`/`@direction`. Id determinista `sort-<field>`.
  """
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

  # ---------------------------------------------------------------------------
  # Celda de identidad (avatar + título + subtítulo)
  # ---------------------------------------------------------------------------

  @doc """
  Celda de identidad de fila: avatar circular + línea principal + secundaria.
  El avatar muestra `@initials` (texto) o `@icon` (heroicon).
  """
  attr :initials, :string, default: nil
  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :truncate, :boolean, default: false

  def admin_identity(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <div class="avatar avatar-placeholder">
        <div class="w-8 rounded-full bg-primary text-primary-content">
          <span :if={@initials} class="text-xs font-semibold">{@initials}</span>
          <.icon :if={@icon} name={@icon} class="w-4 h-4" />
        </div>
      </div>
      <div class={[@truncate && "min-w-0"]}>
        <p class={["font-medium text-sm", @truncate && "truncate"]}>{@title}</p>
        <p :if={@subtitle} class="text-xs text-base-content/50">{@subtitle}</p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Confirmación de borrado destructivo (compone la primitiva <.modal>)
  # ---------------------------------------------------------------------------

  @doc """
  Confirmación de borrado destructivo: la primitiva `<.modal>` (Commons C7.1)
  con el detalle de lo que se borra. El caller la gatea con `:if` sobre el
  assign del objetivo, y `on_close` lo limpia.

  Es a propósito más explícita que el `data-confirm` de una confirmación simple:
  nombra el objetivo y lo que se pierde (Custom — TokenGate).
  """
  attr :id, :string, required: true
  attr :on_close, :string, required: true
  attr :title, :string, required: true
  attr :target_label, :string, default: nil
  attr :target_span_id, :string, default: nil
  attr :confirm_event, :string, required: true
  attr :confirm_value, :string, default: nil
  attr :confirm_button_id, :string, required: true
  attr :cancel_button_id, :string, required: true
  attr :confirm_label, :string, default: "Yes, delete permanently"
  attr :warning_title, :string, default: "This action is irreversible."
  attr :warning_intro, :string, default: nil
  attr :warning_items, :list, default: []

  def admin_delete_modal(assigns) do
    ~H"""
    <.modal id={@id} title={@title} on_close={@on_close} max_w="max-w-md">
      <div class="space-y-3">
        <p :if={@target_label} class="text-sm">
          {gettext("Are you sure you want to delete")} <span
            class="font-semibold"
            id={@target_span_id}
          >{@target_label}</span>?
        </p>
        <div class="alert alert-warning text-sm">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold">{TokengateWeb.Gettext.translate(@warning_title)}</p>
            <p :if={TokengateWeb.Gettext.translate(@warning_intro)} class="mt-1">
              {@warning_intro}
            </p>
            <ul
              :if={@warning_items != []}
              class="mt-1 list-disc list-inside space-y-0.5 text-xs"
            >
              <li :for={item <- @warning_items}>{TokengateWeb.Gettext.translate(item)}</li>
            </ul>
          </div>
        </div>
      </div>
      <div class="flex items-center justify-end gap-2 pt-2">
        <button
          type="button"
          phx-click={@on_close}
          class="btn btn-ghost btn-sm"
          id={@cancel_button_id}
        >
          {gettext("Cancel")}
        </button>
        <button
          phx-click={@confirm_event}
          phx-value-id={@confirm_value}
          class="btn btn-ghost btn-sm text-error"
          id={@confirm_button_id}
        >
          <.icon name="hero-trash" class="w-4 h-4" /> {TokengateWeb.Gettext.translate(@confirm_label)}
        </button>
      </div>
    </.modal>
    """
  end

  # ---------------------------------------------------------------------------
  # Paginado de tabla
  # ---------------------------------------------------------------------------

  @doc """
  Pie de paginado: rango visible y navegación (ventana alrededor de la página
  actual). El tamaño de página lo fija quien lo usa.

  Emite `go_to_page` con `%{"page" => n}`. No pinta nada cuando `@total` es 0.
  """
  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :total_pages, :integer, required: true

  def admin_pagination(assigns) do
    assigns =
      assign(assigns,
        from: (assigns.page - 1) * assigns.per_page + 1,
        to: min(assigns.page * assigns.per_page, assigns.total),
        window: page_window(assigns.page, assigns.total_pages)
      )

    ~H"""
    <div
      :if={@total > 0}
      id={@id}
      class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 px-4 py-3"
    >
      <div class="flex items-center gap-2 text-xs text-base-content/60">
        <span id={"#{@id}-range"}>{@from}–{@to} de {@total}</span>
      </div>

      <div class="flex items-center gap-1" id={"#{@id}-nav"}>
        <button
          phx-click="go_to_page"
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          class="btn btn-ghost btn-xs"
          id={"#{@id}-prev"}
          title={gettext("Previous page")}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </button>

        <%= for p <- @window do %>
          <%= if p == :gap do %>
            <span class="px-1 text-xs text-base-content/40">…</span>
          <% else %>
            <button
              phx-click="go_to_page"
              phx-value-page={p}
              class={["btn btn-xs", p == @page && "btn-primary", p != @page && "btn-ghost"]}
              id={"#{@id}-page-#{p}"}
              aria-current={p == @page && "page"}
            >
              {p}
            </button>
          <% end %>
        <% end %>

        <button
          phx-click="go_to_page"
          phx-value-page={@page + 1}
          disabled={@page >= @total_pages}
          class="btn btn-ghost btn-xs"
          id={"#{@id}-next"}
          title={gettext("Next page")}
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  # Ventana de páginas: `1 … n-1 n n+1 … última`, con `:gap` en los saltos.
  # Con 7 páginas o menos se muestran todas.
  defp page_window(_page, total_pages) when total_pages <= 7, do: Enum.to_list(1..total_pages)

  defp page_window(page, total_pages) do
    start = max(2, min(page - 1, total_pages - 3))
    middle = Enum.to_list(start..min(start + 2, total_pages - 1))

    [1] ++
      gap_when(List.first(middle) > 2) ++
      middle ++ gap_when(List.last(middle) < total_pages - 1) ++ [total_pages]
  end

  defp gap_when(true), do: [:gap]
  defp gap_when(false), do: []
end
