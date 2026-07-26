defmodule TokengateWeb.PricingLive do
  @moduledoc """
  Admin CRUD for model_pricing records per alias_provider.

  Only alias_providers whose provider has billing_type == "pay_per_token"
  are listed — subscription providers don't have per-token pricing.

  Pricing records are versioned via effective_from. Creating a new pricing
  with a later effective_from date creates a new version without deleting
  the old one.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers
  alias Tokengate.Providers.{AliasProvider, ModelPricing}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Pricing · Tokengate")
      |> assign(:form, nil)
      |> assign(:editing_pricing_id, nil)
      |> assign(:pricing_ap_id, nil)
      |> load_pricing()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_pricing(socket) do
    alias_providers = Providers.list_pay_per_token_alias_providers()

    # Group by alias_provider for display, preloading pricing entries
    ap_ids = Enum.map(alias_providers, & &1.id)

    pricing_entries =
      if ap_ids == [] do
        []
      else
        from(p in ModelPricing,
          where: p.alias_provider_id in ^ap_ids,
          order_by: [desc: p.effective_from]
        )
        |> Repo.all()
      end

    # Build a map of alias_provider_id -> [pricing entries]
    pricing_by_ap =
      Enum.group_by(pricing_entries, & &1.alias_provider_id)

    socket
    |> stream(:alias_providers, alias_providers, reset: true)
    |> assign(:alias_providers_empty?, alias_providers == [])
    |> assign(:pricing_by_ap, pricing_by_ap)
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("new_pricing", %{"ap_id" => ap_id}, socket) do
    ap = get_alias_provider_with_provider!(ap_id)

    changeset =
      Providers.change_model_pricing(%ModelPricing{
        alias_provider_id: ap_id,
        effective_from: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :model_pricing))
     |> assign(:editing_pricing_id, :new)
     |> assign(:pricing_ap_id, ap_id)
     |> assign(:current_ap, ap)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_pricing_id, nil)
     |> assign(:pricing_ap_id, nil)
     |> assign(:current_ap, nil)}
  end

  def handle_event("edit_pricing", %{"id" => pricing_id}, socket) do
    pricing = Providers.get_model_pricing!(pricing_id)
    changeset = Providers.change_model_pricing(pricing)
    ap = get_alias_provider_with_provider!(pricing.alias_provider_id)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :model_pricing))
     |> assign(:editing_pricing_id, pricing.id)
     |> assign(:pricing_ap_id, pricing.alias_provider_id)
     |> assign(:current_ap, ap)}
  end

  def handle_event("save_pricing", %{"model_pricing" => pricing_params}, socket) do
    save_pricing(socket, socket.assigns.editing_pricing_id, pricing_params)
  end

  def handle_event("delete_pricing", %{"id" => pricing_id}, socket) do
    pricing = Providers.get_model_pricing!(pricing_id)

    case Providers.delete_model_pricing(pricing) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pricing eliminado.")
         |> load_pricing()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el pricing.")}
    end
  end

  ## Private helpers — save_pricing ---------------------------------------

  defp save_pricing(socket, :new, pricing_params) do
    case Providers.create_model_pricing(pricing_params) do
      {:ok, _pricing} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pricing creado.")
         |> assign(:form, nil)
         |> assign(:editing_pricing_id, nil)
         |> assign(:pricing_ap_id, nil)
         |> assign(:current_ap, nil)
         |> load_pricing()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_pricing))}
    end
  end

  defp save_pricing(socket, pricing_id, pricing_params) when is_binary(pricing_id) do
    pricing = Providers.get_model_pricing!(pricing_id)

    case Providers.update_model_pricing(pricing, pricing_params) do
      {:ok, _pricing} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pricing actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_pricing_id, nil)
         |> assign(:pricing_ap_id, nil)
         |> assign(:current_ap, nil)
         |> load_pricing()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_pricing))}
    end
  end

  ## Private helpers — data fetching -------------------------------------

  defp get_alias_provider_with_provider!(ap_id) do
    from(ap in AliasProvider,
      where: ap.id == ^ap_id,
      preload: [:provider, :model_alias]
    )
    |> Repo.one!()
  end

  ## Helpers ---------------------------------------------------------------

  @doc "Pricing entries for an alias_provider (from the preloaded map)"
  def pricing_entries(ap_id, pricing_by_ap) do
    Map.get(pricing_by_ap, ap_id, [])
  end

  @doc "Format a decimal for display"
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc "Format a datetime for display"
  def fmt_dt(nil), do: "—"

  def fmt_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  @doc "Label for whether a pricing entry is current (latest effective_from)"
  def current_label(true), do: {"badge-success", "Actual"}
  def current_label(false), do: {"badge-ghost", "Histórico"}

  @doc "Check if a pricing entry is the current (latest) one for its alias_provider"
  def is_current?(pricing, pricing_by_ap) do
    entries = Map.get(pricing_by_ap, pricing.alias_provider_id, [])

    case Enum.at(entries, 0) do
      nil -> false
      latest -> latest.id == pricing.id
    end
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Pricing
          <:subtitle>Gestiona los precios por token de los proveedores pay-per-token</:subtitle>
        </.header>

        <div id="alias-providers" phx-update="stream">
          <div
            :if={@alias_providers_empty?}
            id="alias-providers-empty"
            class="text-center py-12 text-base-content/40"
          >
            <.icon name="hero-currency-dollar" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay proveedores pay-per-token configurados.</p>
            <p class="text-xs mt-1">Asigna proveedores a aliases primero en la sección Aliases.</p>
          </div>

          <div
            :for={{id, ap} <- @streams.alias_providers}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body p-5">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="font-semibold text-base-content">
                    {ap.provider.name}
                  </h3>
                  <p class="text-sm text-base-content/60 mt-0.5">
                    Modelo: <code class="text-sm">{ap.provider_model}</code>
                  </p>
                  <p class="text-xs text-base-content/40 mt-1">
                    Alias: {if ap.model_alias, do: ap.model_alias.name, else: "—"}
                  </p>
                </div>
                <button
                  phx-click="new_pricing"
                  phx-value-ap_id={ap.id}
                  class="btn btn-primary btn-sm"
                  id={"new-pricing-#{ap.id}"}
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Nuevo Pricing
                </button>
              </div>

              <div class="mt-4">
                <%!-- Pricing entries for this alias_provider --%>
                <div
                  :if={pricing_entries(ap.id, @pricing_by_ap) == []}
                  class="text-sm text-base-content/40 py-3"
                >
                  No hay pricing configurado todavía.
                </div>
                <div :if={pricing_entries(ap.id, @pricing_by_ap) != []} class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Desde</th>
                        <th>Entrada /1M</th>
                        <th>Salida /1M</th>
                        <th>Cache Read /1M</th>
                        <th>Cache Creation /1M</th>
                        <th>Estado</th>
                        <th>Acciones</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={p <- pricing_entries(ap.id, @pricing_by_ap)} id={"pricing-#{p.id}"}>
                        <td>{fmt_dt(p.effective_from)}</td>
                        <td>{fmt_dec(p.input_price_per_1m)}</td>
                        <td>{fmt_dec(p.output_price_per_1m)}</td>
                        <td>{fmt_dec(p.cache_read_price_per_1m)}</td>
                        <td>{fmt_dec(p.cache_creation_price_per_1m)}</td>
                        <td>
                          <span class={[
                            "badge",
                            "badge-sm",
                            elem(current_label(is_current?(p, @pricing_by_ap)), 0)
                          ]}>
                            {elem(current_label(is_current?(p, @pricing_by_ap)), 1)}
                          </span>
                        </td>
                        <td>
                          <div class="flex gap-1">
                            <button
                              phx-click="edit_pricing"
                              phx-value-id={p.id}
                              class="btn btn-xs btn-ghost"
                              id={"edit-pricing-#{p.id}"}
                            >
                              <.icon name="hero-pencil-square" class="w-3 h-3" />
                            </button>
                            <button
                              phx-click="delete_pricing"
                              phx-value-id={p.id}
                              data-confirm="¿Eliminar este pricing?"
                              class="btn btn-xs btn-ghost text-error"
                              id={"delete-pricing-#{p.id}"}
                            >
                              <.icon name="hero-trash" class="w-3 h-3" />
                            </button>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Pricing form (new/edit) --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_pricing_id == :new, do: "Nuevo Pricing", else: "Editar Pricing"}
              </h2>

              <%!-- Show which alias_provider this pricing belongs to --%>
              <%= if @current_ap do %>
                <div class="alert alert-info py-2 px-3 mb-3 text-sm">
                  <.icon name="hero-information-circle" class="w-4 h-4 shrink-0" />
                  <span>
                    Proveedor: <strong>{@current_ap.provider.name}</strong> ·
                    Modelo: <code>{@current_ap.provider_model}</code>
                  </span>
                </div>
              <% end %>

              <.form for={@form} id="pricing-form" phx-submit="save_pricing">
                <.input
                  field={@form[:alias_provider_id]}
                  type="hidden"
                />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@form[:input_price_per_1m]}
                    type="number"
                    label="Precio entrada /1M (USD)"
                    step="any"
                    required
                  />
                  <.input
                    field={@form[:output_price_per_1m]}
                    type="number"
                    label="Precio salida /1M (USD)"
                    step="any"
                    required
                  />
                </div>
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@form[:cache_read_price_per_1m]}
                    type="number"
                    label="Cache read /1M (opcional)"
                    step="any"
                  />
                  <.input
                    field={@form[:cache_creation_price_per_1m]}
                    type="number"
                    label="Cache creation /1M (opcional)"
                    step="any"
                  />
                </div>
                <.input
                  field={@form[:effective_from]}
                  type="datetime-local"
                  label="Efectivo desde"
                  required
                />

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-pricing-btn">
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
