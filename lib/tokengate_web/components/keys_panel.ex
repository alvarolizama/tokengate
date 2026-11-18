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

  ## Contrato de eventos (W6/W7/W8)

  El panel no escribe: emite eventos y el LiveView decide. Los eventos
  obligatorios y el lifecycle que deben cablear:

    * `@create_event` — `phx-submit` con `%{"key" => %{"label" => _}}`. El
      LiveView crea la key y guarda el token en `new_token`.
    * `@revoke_event` — `phx-click` con `phx-value-key-id`. **Revocar = emitir
      una nueva y anular la anterior**: el handler llama
      `Accounts.revoke_and_replace_api_key/1` y deja el token nuevo en
      `new_token` (se muestra una sola vez aquí). No hay botón de "regenerar"
      ni de "reactivar": ese es el ciclo de vida completo.
    * `@dismiss_event` — oculta el token nuevo.
    * `@sticky_event` — opcional; limpia el ruteo sticky del sujeto
      (`phx-value-id` = `@subject_id`).
    * `@rename_event` / `@cancel_rename_event` — **opt-in**: con
      `@rename_event` presente, cada fila activa muestra un lápiz que abre el
      form inline (payload `%{"key-id" => _, "key" => %{"label" => _}}`);
      `@editing_key_id` marca la fila en edición. El handler debe llamar
      `Accounts.rename_api_key/3` con el `:user_id`/`:service_id` del panel
      (el contexto hace el chequeo de pertenencia y audita `api_key.rename`).
    * `@hide_event` — **opt-in**: botón «Borrar» por fila (`phx-value-key-id`).
      Borrar es **soft-hide**: el handler llama `Accounts.hide_api_key/1` (o
      `delete_api_key/1`, que es el mismo camino) y recarga el panel. La fila
      desaparece de todas las superficies y el histórico de `request_logs`
      conserva su atribución.

  `@reactivate_event` se conserva declarado sólo para los llamadores viejos
  que todavía lo pasan: el panel **no** renderiza ningún control de
  reactivación y el attr se ignora (W6/W7 lo quitan).

  ## Nunca renderiza la clave

  El panel no tiene acceso al token guardado: las filas muestran únicamente
  `key_prefix` y la etiqueta. El único token que aparece es el recién emitido
  (`@new_token`), que el LiveView pone en el assign al crear/revocar y limpia
  con `@dismiss_event`.
  """

  use Phoenix.Component
  use Gettext, backend: TokengateWeb.Gettext

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
      title={gettext("Manage API keys")}
      aria-label={gettext("Manage API keys")}
    >
      <.icon name="hero-key" class="w-3 h-3" />
      {gettext("%{count} keys", count: @count)}
    </button>
    """
  end

  @doc """
  Cuerpo del panel de claves. Se renderiza dentro de un `<.modal>`.

  Ver el moduledoc para el contrato de eventos y el ciclo de vida.
  """
  attr :subject_kind, :string, required: true, doc: ~s("user" | "service")
  attr :subject_id, :string, required: true
  attr :keys, :list, required: true
  attr :spend, :map, default: %{}
  attr :new_token, :string, default: nil
  attr :create_event, :string, required: true
  attr :revoke_event, :string, required: true

  attr :reactivate_event, :string,
    default: nil,
    doc: "Deprecated and ignored: reactivating a token is not part of the lifecycle."

  attr :revoked_keys, :list, default: []
  attr :dismiss_event, :string, required: true
  attr :sticky_event, :string, default: nil
  attr :rename_event, :string, default: nil
  attr :cancel_rename_event, :string, default: nil
  attr :hide_event, :string, default: nil
  attr :editing_key_id, :string, default: nil
  attr :empty_text, :string, default: "This subject has no active keys."

  def keys_panel(assigns) do
    ~H"""
    <div
      :if={@sticky_event}
      class="flex items-center justify-between gap-3 p-3 mb-4 rounded-lg bg-base-200/50"
    >
      <div class="min-w-0">
        <p class="text-sm font-medium">{gettext("Sticky routing")}</p>
        <p class="text-xs text-base-content/60">
          {gettext(
            "Forces its next request to re-evaluate providers instead of staying glued to a degraded one."
          )}
        </p>
      </div>
      <button
        type="button"
        phx-click={@sticky_event}
        phx-value-id={@subject_id}
        class="btn btn-ghost btn-sm shrink-0"
        id={"clear-#{@subject_kind}-sticky-btn"}
        title={gettext("Clear the subject sticky routes (all its keys)")}
      >
        <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Clear sticky")}
      </button>
    </div>

    <div :if={@new_token} class="alert alert-success mb-4 py-2" id="new-key-token">
      <div class="w-full">
        <p class="text-xs mb-1 font-semibold">
          {gettext("Copy it now: it is not shown again.")}
        </p>
        <code class="text-xs font-mono break-all">{@new_token}</code>
        <div class="flex justify-end mt-2">
          <button
            type="button"
            phx-click={@dismiss_event}
            class="btn btn-xs btn-ghost"
            id="dismiss-new-key-token"
          >
            {gettext("Done")}
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
          <div
            :if={@rename_event && @editing_key_id == key.id}
            class="flex items-center gap-1"
            id={"rename-key-form-#{key.id}"}
          >
            <.form
              for={%{}}
              as={nil}
              id={"rename-key-inline-#{key.id}"}
              phx-submit={@rename_event}
              class="flex items-center gap-1 flex-1"
            >
              <input type="hidden" name="key-id" value={key.id} />
              <input
                type="text"
                name="key[label]"
                value={key.label || ""}
                maxlength="64"
                placeholder={gettext("ci, laptop, server...")}
                class="input input-xs input-bordered w-full font-mono"
                autofocus
              />
              <button type="submit" class="btn btn-xs btn-primary" title={gettext("Save")}>
                <.icon name="hero-check" class="w-3.5 h-3.5" />
              </button>
            </.form>
            <button
              type="button"
              phx-click={@cancel_rename_event}
              class="btn btn-xs btn-ghost"
              id={"cancel-rename-key-#{key.id}"}
              title={gettext("Cancel")}
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </div>
          <div :if={@editing_key_id != key.id}>
            <div class="flex items-center gap-2">
              <span class="text-sm font-semibold truncate">{key.label || gettext("no label")}</span>
              <span class={[
                "badge badge-xs",
                if(key.status == "active", do: "badge-success", else: "badge-ghost")
              ]}>
                {if key.status == "active", do: gettext("Active"), else: gettext("Revoked")}
              </span>
            </div>
            <div class="text-xs font-mono text-base-content/50">
              {key.key_prefix}•••• <% spend = Map.get(@spend, key.id) %>
              <span class="ml-2 text-base-content/40">
                {if spend,
                  do: "#{spend.requests} req · $#{fmt_money(spend.cost_usd)}",
                  else: gettext("no usage")}
              </span>
            </div>
          </div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            :if={@rename_event && key.status == "active" && @editing_key_id != key.id}
            type="button"
            phx-click={@rename_event}
            phx-value-key-id={key.id}
            class="btn btn-xs btn-ghost shrink-0"
            id={"rename-key-#{key.id}"}
            title={gettext("Rename this key")}
            aria-label={gettext("Rename this key")}
          >
            <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
          </button>
          <button
            :if={key.status == "active"}
            type="button"
            phx-click={@revoke_event}
            phx-value-key-id={key.id}
            class="btn btn-xs btn-ghost text-error shrink-0"
            id={"revoke-key-#{key.id}"}
            title={gettext("Revoke this key")}
            aria-label={gettext("Revoke this key")}
            data-confirm={
              gettext("Revoke this key? A new one is issued and this token stops working.")
            }
          >
            {gettext("Revoke")}
          </button>
          <button
            :if={@hide_event}
            type="button"
            phx-click={@hide_event}
            phx-value-key-id={key.id}
            class="btn btn-xs btn-ghost shrink-0"
            id={"hide-key-#{key.id}"}
            title={gettext("Delete this key")}
            aria-label={gettext("Delete this key")}
            data-confirm={
              gettext(
                "Delete this key? It disappears from the listings and its token stops working; historical consumption is preserved."
              )
            }
          >
            {gettext("Delete key")}
          </button>
        </div>
      </div>
      <p :if={@keys == []} class="text-sm text-base-content/50 py-2" id="no-keys">
        {TokengateWeb.Gettext.translate(@empty_text)}
      </p>
    </div>

    <%!-- Revocadas: la fila sigue existiendo (revocar no la borra) para que el
         histórico y el consumo sigan atribuidos. Es sólo lectura: no hay
         reactivación — el lifecycle emite una nueva. --%>
    <div :if={@revoked_keys != []} class="space-y-2 mb-4" id="revoked-keys">
      <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
        {gettext("Revoked keys")}
      </p>
      <div
        :for={key <- @revoked_keys}
        class="flex items-center justify-between gap-2 p-2 rounded-lg bg-base-200/30"
        id={"revoked-key-#{key.id}"}
      >
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold truncate text-base-content/60">
              {key.label || gettext("no label")}
            </span>
            <span class="badge badge-xs badge-ghost">{gettext("Revoked")}</span>
          </div>
          <div class="text-xs font-mono text-base-content/40">{key.key_prefix}••••</div>
        </div>
      </div>
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
            <span class="label-text text-xs">{gettext("New key")}</span>
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
          {gettext("Create key")}
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
