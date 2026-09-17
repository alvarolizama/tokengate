defmodule TokengateWeb.KeysPanel do
  @moduledoc """
  Panel de claves API compartido por usuarios y servicios (homologación de UX).

  Usuarios y servicios gestionan sus claves exactamente igual: lista de N
  claves con etiqueta, alta con etiqueta, revocación por clave, token nuevo
  (visible una sola vez) y limpieza del ruteo sticky del sujeto. El markup es
  literalmente el mismo en ambas páginas; solo cambia `subject_kind`
  (`"user"` / `"service"`), que parametriza los ids dependientes del sujeto
  (`clear-<kind>-sticky-btn`) y el evento de limpieza.

  El botón de conteo de la tabla (`keys_badge/1`) también vive aquí para que
  ambas tablas lo rendericen igual y en la misma columna.
  """

  use Phoenix.Component

  import TokengateWeb.CoreComponents

  @doc """
  Botón de la columna «Claves»: cuenta las claves activas del sujeto y abre el
  panel. Id determinista `keys-<subject_id>` idéntico en ambas tablas.
  """
  attr :subject_id, :string, required: true
  attr :count, :integer, required: true
  attr :open_event, :string, required: true

  def keys_badge(assigns) do
    ~H"""
    <button
      phx-click={@open_event}
      phx-value-id={@subject_id}
      class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-colors cursor-pointer"
      id={"keys-#{@subject_id}"}
      title="Gestionar claves API"
      aria-label="Gestionar claves API"
    >
      <.icon name="hero-key" class="w-3 h-3" />
      {@count} claves
    </button>
    """
  end

  @doc """
  Cuerpo del panel de claves. Se renderiza dentro de un `admin_modal`.

  Eventos esperados en el LiveView:
    * `@create_event` — `phx-submit` del form con `%{"key" => %{"label" => _}}`.
    * `@revoke_event` — `phx-click` con `phx-value-key-id`.
    * `@dismiss_event` — oculta el token nuevo.
    * `@sticky_event` — opcional; limpia el ruteo sticky del sujeto
      (`phx-value-id` = `@subject_id`).
  """
  attr :subject_kind, :string, required: true, doc: ~s("user" | "service")
  attr :subject_id, :string, required: true
  attr :keys, :list, required: true
  attr :spend, :map, default: %{}
  attr :new_token, :string, default: nil
  attr :create_event, :string, required: true
  attr :revoke_event, :string, required: true
  attr :dismiss_event, :string, required: true
  attr :sticky_event, :string, default: nil
  attr :empty_text, :string, default: "Este sujeto no tiene claves activas."

  def keys_panel(assigns) do
    ~H"""
    <div
      :if={@sticky_event}
      class="flex items-center justify-between gap-3 p-3 mb-4 rounded-lg bg-base-200/50"
    >
      <div class="min-w-0">
        <p class="text-sm font-medium">Ruteo sticky</p>
        <p class="text-xs text-base-content/60">
          Fuerza que su próxima petición re-evalúe proveedores en vez de quedarse
          pegado a uno degradado.
        </p>
      </div>
      <button
        type="button"
        phx-click={@sticky_event}
        phx-value-id={@subject_id}
        class="btn btn-ghost btn-sm shrink-0"
        id={"clear-#{@subject_kind}-sticky-btn"}
        title="Limpiar sticky routes del sujeto (todas sus keys)"
      >
        <.icon name="hero-arrow-path" class="w-4 h-4" /> Limpiar sticky
      </button>
    </div>

    <div :if={@new_token} class="alert alert-success mb-4 py-2" id="new-key-token">
      <div class="w-full">
        <p class="text-xs mb-1 font-semibold">
          Cópiala ahora: no se vuelve a mostrar.
        </p>
        <code class="text-xs font-mono break-all">{@new_token}</code>
        <div class="flex justify-end mt-2">
          <button
            type="button"
            phx-click={@dismiss_event}
            class="btn btn-xs btn-ghost"
            id="dismiss-new-key-token"
          >
            Listo
          </button>
        </div>
      </div>
    </div>

    <div class="space-y-2 mb-4">
      <div
        :for={key <- @keys}
        class="flex items-center justify-between gap-2 p-2 rounded-lg bg-base-200/50"
        id={"key-#{key.id}"}
      >
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold truncate">{key.label || "sin etiqueta"}</span>
            <span class={[
              "badge badge-xs",
              if(key.status == "active", do: "badge-success", else: "badge-ghost")
            ]}>
              {if key.status == "active", do: "Activa", else: "Revocada"}
            </span>
          </div>
          <div class="text-xs font-mono text-base-content/50">
            {key.key_prefix}•••• <% spend = Map.get(@spend, key.id) %>
            <span class="ml-2 text-base-content/40">
              {if spend,
                do: "#{spend.requests} req · $#{fmt_money(spend.cost_usd)}",
                else: "sin consumo"}
            </span>
          </div>
        </div>
        <button
          :if={key.status == "active"}
          type="button"
          phx-click={@revoke_event}
          phx-value-key-id={key.id}
          class="btn btn-xs btn-ghost text-error shrink-0"
          id={"revoke-key-#{key.id}"}
          title="Revocar esta clave"
          aria-label="Revocar esta clave"
          data-confirm="¿Revocar esta clave? El token deja de funcionar."
        >
          Revocar
        </button>
      </div>
      <p :if={@keys == []} class="text-sm text-base-content/50 py-2" id="no-keys">
        {@empty_text}
      </p>
    </div>

    <.form
      for={%{}}
      id="new-key-form"
      phx-submit={@create_event}
      class="border-t border-base-300 pt-3"
    >
      <div class="flex items-end gap-2">
        <div class="flex-1">
          <label class="label py-1" for="new-key-label">
            <span class="label-text text-xs">Nueva clave</span>
          </label>
          <input
            type="text"
            name="key[label]"
            id="new-key-label"
            class="input input-sm input-bordered w-full"
            placeholder="ci, laptop, server..."
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm" id="create-key-btn">
          Crear clave
        </button>
      </div>
    </.form>
    """
  end

  # Formatea costo en USD (Decimal) para la línea de consumo de la clave.
  defp fmt_money(%Decimal{} = d), do: d |> Decimal.round(4) |> Decimal.to_string()
  defp fmt_money(nil), do: "0"
  defp fmt_money(other), do: to_string(other)
end
