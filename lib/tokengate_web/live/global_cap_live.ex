defmodule TokengateWeb.GlobalCapLive do
  @moduledoc """
  Admin page for the **tope diario global** — the kill-switch cap on total
  spend per UTC day, plus the subjects exempt from it.

  Vive en la sección Presupuesto (`/budget/global`) porque es una palanca de
  presupuesto (un tope y sus exenciones), no una acción de mantenimiento: la
  página de Mantenimiento conserva solo la zona de precaución y la de peligro.
  La tarjeta «Tope diario global» de Estadísticas mide la misma ventana UTC.

  Dos secciones:

    * **El tope** — monto por día UTC; al alcanzarse, toda request nueva se
      rechaza con 402 hasta el día siguiente. El medidor muestra el gasto real
      de `request_logs` (misma fuente que Estadísticas) y, solo cuando
      discrepa, el contador ETS de enforcement como referencia de drift.
    * **Exclusiones al tope** — usuarios, perfiles de límites o servicios cuyo
      gasto no cuenta para el tope global (sigue contando para su propio
      presupuesto mensual o top-up).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Exemption
  alias Tokengate.Budgets.Exemptions
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.GlobalSettings
  alias Tokengate.Logs

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Tope diario global · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:global_subject_type, "user")
      |> assign(:groups, Accounts.list_groups())
      |> assign(:services, Accounts.list_services())
      |> assign(:users, Accounts.list_users())
      |> assign_global_settings()
      |> assign_exemptions()
      |> require_admin_hook()

    {:ok, socket}
  end

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Events -----------------------------------------------------------------

  @impl true
  def handle_event("save_global_cap", %{"global_settings" => params}, socket) do
    case GlobalSettings.update(params) do
      {:ok, _settings} ->
        audit(socket, "budget.update_global_daily_cap", "global_settings", "global", params)

        {:noreply,
         socket
         |> assign_global_settings()
         |> put_flash(:info, "Tope diario global actualizado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :global_form, to_form(changeset, as: :global_settings))}
    end
  end

  @impl true
  def handle_event("change_global_subject", %{"global_subject" => %{"subject_type" => t}}, socket) do
    {:noreply, assign(socket, :global_subject_type, t)}
  end

  def handle_event("add_global_exemption", %{"global_subject" => params}, socket) do
    subject_type = params["subject_type"]
    subject_id = params["subject_id"]

    cond do
      subject_type in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Selecciona un tipo de sujeto.")}

      subject_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Selecciona a quién excluir.")}

      true ->
        attrs =
          %{"scope" => "global_daily", "subject_type" => subject_type}
          |> Map.put(to_string(Exemption.subject_field(subject_type)), subject_id)

        case Exemptions.add(attrs) do
          {:ok, exemption} ->
            audit(socket, "exemption.add", "exemption", exemption.id, attrs)

            {:noreply, socket |> assign_exemptions() |> put_flash(:info, "Exención agregada.")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, exemption_error(changeset))}
        end
    end
  end

  def handle_event("remove_global_exemption", %{"id" => id}, socket) do
    Exemptions.remove(id)

    audit(socket, "exemption.remove", "exemption", id, %{})

    {:noreply, socket |> assign_exemptions() |> put_flash(:info, "Exención eliminada.")}
  end

  ## Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <.header>
          Tope diario global
          <:subtitle>
            Tope de gasto por día UTC para todos los sujetos, y quién queda exento
          </:subtitle>
        </.header>

        <%!-- Sección 1: el tope (kill-switch) --%>
        <div class="card bg-base-100 border border-base-300" id="global-cap-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-globe-americas" class="w-5 h-5" /> El tope
            </h2>
            <p class="text-sm text-base-content/60">
              Tope máximo de gasto total por día (UTC), sumando todos los sujetos.
              Cuando se alcanza, toda nueva request se rechaza con 402 hasta el día
              siguiente. Vacío = sin tope.
            </p>

            <.form for={@global_form} id="global-cap-form" phx-submit="save_global_cap">
              <.input
                field={@global_form[:daily_max_spend_usd]}
                type="number"
                step="0.01"
                min="0"
                label="USD por día"
                hint="Ej: 50.00 — se corta todo cuando el gasto total del día llega a este monto."
              />
              <div class="flex gap-2 mt-3">
                <button type="submit" class="btn btn-primary btn-sm" id="save-global-cap-btn">
                  Guardar
                </button>
              </div>
            </.form>

            <div class="mt-4">
              <div class="flex justify-between text-sm">
                <span class="text-base-content/60">Gastado hoy (total)</span>
                <span class="font-mono font-semibold">
                  ${Decimal.round(@global_daily_spend, 2)}
                  <%= if @global_daily_cap do %>
                    / ${Decimal.round(@global_daily_cap, 2)}
                  <% end %>
                </span>
              </div>
              <%= if @global_daily_cap && @global_daily_pct do %>
                <progress
                  class={
                    if @global_daily_pct >= 90,
                      do: "progress progress-error w-full mt-1",
                      else: "progress progress-warning w-full mt-1"
                  }
                  value={@global_daily_pct}
                  max="100"
                />
              <% end %>
              <p class="text-xs text-base-content/40 mt-1">
                Gasto real de <code>request_logs</code>, día UTC
                (misma fuente que Estadísticas).
              </p>
              <%= if @global_daily_enforcement && drift?(@global_daily_enforcement, @global_daily_spend) do %>
                <p class="text-xs text-warning mt-1" id="global-enforcement-drift">
                  Contador de enforcement:
                  <span class="font-mono">
                    ${Decimal.round(@global_daily_enforcement, 2)}
                  </span>
                  — incluye los holds de las requests en vuelo.
                  <%= if Decimal.compare(@global_daily_enforcement, @global_daily_spend) == :gt do %>
                    Si no baja en unos minutos, es drift: el <code>GlobalSyncWorker</code>
                    lo reconcilia contra la DB.
                  <% else %>
                    Se sincroniza contra la DB al vuelo.
                  <% end %>
                </p>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Sección 2: exclusiones al tope --%>
        <div class="card bg-base-100 border border-base-300" id="global-exemptions-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-shield-exclamation" class="w-5 h-5 text-warning" />
              Exclusiones al tope
            </h2>
            <p class="text-sm text-base-content/60">
              El gasto de estos sujetos no cuenta para el tope global (sigue
              contando para su propio presupuesto mensual o top-up).
            </p>

            <.form
              for={%{}}
              phx-submit="add_global_exemption"
              phx-change="change_global_subject"
              id="global-exemption-form"
              class="flex flex-wrap gap-2 items-end"
            >
              <div>
                <label class="text-xs text-base-content/60 block mb-1">Tipo</label>
                <select name="global_subject[subject_type]" class="select select-bordered select-sm">
                  <option value="user" selected={@global_subject_type == "user"}>Usuario</option>
                  <option value="group" selected={@global_subject_type == "group"}>
                    Perfil de límites
                  </option>
                  <option value="service" selected={@global_subject_type == "service"}>
                    Servicio
                  </option>
                </select>
              </div>
              <div class="flex-1 min-w-48">
                <label class="text-xs text-base-content/60 block mb-1">Sujeto</label>
                <select
                  name="global_subject[subject_id]"
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">
                    {if @global_subject_type == "user",
                      do: "Usuario…",
                      else:
                        if(@global_subject_type == "group",
                          do: "Perfil de límites…",
                          else: "Servicio…"
                        )}
                  </option>
                  <%= for {label, id} <- subject_options(@global_subject_type, assigns) do %>
                    <option value={id}>{label}</option>
                  <% end %>
                </select>
              </div>
              <button type="submit" class="btn btn-primary btn-sm" id="add-global-exemption-btn">
                Excluir
              </button>
            </.form>

            <div :if={@global_exemptions != []} class="overflow-x-auto mt-3" id="global-exemptions">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Sujeto</th>
                    <th>Tipo</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={e <- @global_exemptions} id={"global-exemption-" <> e.id}>
                    <td class="font-medium">{Exemptions.subject_name(e)}</td>
                    <td>
                      <span class="badge badge-sm badge-ghost">
                        {Exemptions.subject_type_label(e)}
                      </span>
                    </td>
                    <td class="text-right">
                      <button
                        type="button"
                        phx-click="remove_global_exemption"
                        phx-value-id={e.id}
                        class="btn btn-ghost btn-xs text-error"
                        aria-label="Quitar exención"
                        id={"remove-global-exemption-" <> e.id}
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" /> Quitar
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div
              :if={@global_exemptions == []}
              class="text-center py-8 text-base-content/40"
              id="global-exemptions-empty"
            >
              <.icon name="hero-shield-check" class="w-8 h-8 mx-auto mb-2 opacity-40" />
              <p class="text-sm">Sin exclusiones — todos los sujetos cuentan para el tope global.</p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Helpers ----------------------------------------------------------------

  defp assign_global_settings(socket) do
    settings = GlobalSettings.get!()
    # Two different numbers, on purpose:
    #
    #   * `:global_daily_spend` — REAL spend from `request_logs` over the UTC
    #     day, the same source `/stats` displays. This is what the kill-switch
    #     compares against, so it is the number an operator must see here.
    #   * `:global_daily_enforcement` — the live ETS enforcement counter
    #     (`Budgets.Manager`). It carries the `$max_request_cost_usd` holds of
    #     in-flight requests, so it "breathes" with traffic and can hold a
    #     phantom peak if a request dies between hold and settle. Kept only as
    #     a drift reference, rendered when it disagrees with the real spend.
    real_spend =
      %{from: Budgets.utc_day_start()}
      |> Logs.cost_summary()
      |> Map.get(:total_cost_usd, Decimal.new(0))

    daily_cap = settings.daily_max_spend_usd

    daily_pct =
      if daily_cap && Decimal.compare(daily_cap, Decimal.new(0)) == :gt do
        real_spend
        |> Decimal.div(daily_cap)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(1)
        |> Decimal.to_float()
      else
        nil
      end

    socket
    |> assign(
      :global_form,
      to_form(GlobalSettings.changeset(settings, %{}), as: :global_settings)
    )
    |> assign(:global_daily_spend, real_spend)
    |> assign(:global_daily_cap, daily_cap)
    |> assign(:global_daily_pct, daily_pct)
    |> assign(:global_daily_enforcement, enforcement_counter_spend())
  end

  # True when the enforcement counter and the real DB spend disagree by more
  # than half a cent — below that the difference is rounding noise between an
  # exact Decimal sum and the micro-USD ETS counter, not drift worth showing.
  defp drift?(enforcement, real_spend) do
    enforcement
    |> Decimal.sub(real_spend)
    |> Decimal.abs()
    |> Decimal.compare(Decimal.new("0.005")) == :gt
  end

  # The ETS enforcement counter as a Decimal, or `nil` when it cannot be read
  # (table not up yet on a cold boot). Never raises: the card is informational.
  defp enforcement_counter_spend do
    try do
      Budgets.global_daily_spend()
    rescue
      ArgumentError -> nil
    end
  end

  defp assign_exemptions(socket) do
    assign(socket, :global_exemptions, Exemptions.list_for_scope("global_daily"))
  end

  defp exemption_error(changeset) do
    case changeset.errors do
      [] ->
        "No se pudo agregar la exención."

      errors ->
        "No se pudo agregar la exención: " <>
          (errors |> Enum.map(fn {_, {m, _}} -> m end) |> Enum.join(", "))
    end
  end

  defp subject_options("user", assigns),
    do: Enum.map(assigns.users, &{"#{&1.name} — #{&1.email}", &1.id})

  defp subject_options("group", assigns), do: Enum.map(assigns.groups, &{&1.name, &1.id})
  defp subject_options("service", assigns), do: Enum.map(assigns.services, &{&1.name, &1.id})
  defp subject_options(_, _assigns), do: []
end
