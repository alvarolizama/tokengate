defmodule TokengateWeb.SubscriptionsLive do
  @moduledoc """
  Admin CRUD for provider subscriptions, grouped by provider.

  Lists each provider's subscriptions (name, cost, billing_cycle,
  start/end, billing_day, status) with active subs highlighted.
  Supports creating, editing, and marking cancelled/exhausted.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers
  alias Tokengate.Providers.{Provider, Subscription}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Subscripciones · Tokengate")
      |> assign(:form, nil)
      |> assign(:editing_subscription_id, nil)
      |> load_subscriptions()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_subscriptions(socket) do
    providers =
      from(p in Provider,
        left_join: s in assoc(p, :subscriptions),
        preload: [subscriptions: s],
        order_by: [asc: p.name]
      )
      |> Repo.all()

    socket
    |> assign(:providers, providers)
    |> assign(:subs_empty?, Enum.all?(providers, fn p -> p.subscriptions == [] end))
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("new_subscription", %{"provider_id" => provider_id}, socket) do
    changeset =
      Providers.change_subscription(%Subscription{
        provider_id: provider_id,
        billing_cycle: "monthly",
        status: "active",
        start_date: Date.utc_today()
      })

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :subscription))
     |> assign(:editing_subscription_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_subscription_id, nil)}
  end

  def handle_event("edit_subscription", %{"id" => sub_id}, socket) do
    sub = Providers.get_subscription!(sub_id)
    changeset = Providers.change_subscription(sub)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :subscription))
     |> assign(:editing_subscription_id, sub.id)}
  end

  def handle_event("save_subscription", %{"subscription" => sub_params}, socket) do
    save_subscription(socket, socket.assigns.editing_subscription_id, sub_params)
  end

  def handle_event("mark_cancelled", %{"id" => sub_id}, socket) do
    sub = Providers.get_subscription!(sub_id)

    case Providers.update_subscription(sub, %{status: "cancelled"}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscripción cancelada.")
         |> load_subscriptions()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar.")}
    end
  end

  def handle_event("mark_exhausted", %{"id" => sub_id}, socket) do
    sub = Providers.get_subscription!(sub_id)

    case Providers.update_subscription(sub, %{status: "exhausted"}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscripción marcada como agotada.")
         |> load_subscriptions()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar.")}
    end
  end

  ## Private helpers — save_subscription ---------------------------------

  defp save_subscription(socket, :new, sub_params) do
    case Providers.create_subscription(sub_params) do
      {:ok, _sub} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscripción creada.")
         |> assign(:form, nil)
         |> assign(:editing_subscription_id, nil)
         |> load_subscriptions()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :subscription))}
    end
  end

  defp save_subscription(socket, sub_id, sub_params) when is_binary(sub_id) do
    sub = Providers.get_subscription!(sub_id)

    case Providers.update_subscription(sub, sub_params) do
      {:ok, _sub} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscripción actualizada.")
         |> assign(:form, nil)
         |> assign(:editing_subscription_id, nil)
         |> load_subscriptions()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :subscription))}
    end
  end

  ## Helpers ---------------------------------------------------------------

  @doc "Billing cycle options"
  def billing_cycle_options do
    [{"Mensual", "monthly"}, {"Anual", "yearly"}]
  end

  @doc "Status options"
  def status_options do
    [{"Activa", "active"}, {"Agotada", "exhausted"}, {"Cancelada", "cancelled"}]
  end

  @doc "Active if status is active and end_date is nil or >= today"
  def sub_active?(%{status: "active", end_date: nil}), do: true

  def sub_active?(%{status: "active", end_date: %Date{} = d}),
    do: Date.compare(d, Date.utc_today()) != :lt

  def sub_active?(_), do: false

  @doc "Format a date or nil"
  def fmt_date(nil), do: "—"
  def fmt_date(%Date{} = d), do: Calendar.strftime(d, "%Y-%m-%d")

  @doc "Format a decimal"
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Subscripciones
          <:subtitle>Planes flat-rate contratados por provider</:subtitle>
        </.header>

        <%!-- Subscription form (create / edit) --%>
        <div
          :if={@form}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="subscription-form-card"
        >
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">
              {if @editing_subscription_id == :new,
                do: "Nueva subscripción",
                else: "Editar subscripción"}
            </h2>
            <.form for={@form} id="subscription-form" phx-submit="save_subscription">
              <.input field={@form[:provider_id]} type="hidden" />
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <.input field={@form[:name]} type="text" label="Nombre" placeholder="OpenRouter Pro" />
                <.input field={@form[:cost]} type="number" label="Costo (USD)" step="any" />
                <.input
                  field={@form[:billing_cycle]}
                  type="select"
                  label="Ciclo de facturación"
                  options={billing_cycle_options()}
                />
                <.input field={@form[:start_date]} type="date" label="Inicio" />
                <.input field={@form[:end_date]} type="date" label="Fin (opcional)" />
                <.input field={@form[:billing_day]} type="number" label="Día de cobro" />
              </div>
              <div class="mt-3">
                <.input
                  field={@form[:status]}
                  type="select"
                  label="Estado"
                  options={status_options()}
                />
              </div>
              <div class="flex gap-2 mt-4">
                <button type="submit" class="btn btn-primary btn-sm" id="save-subscription-btn">Guardar</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
              </div>
            </.form>
          </div>
        </div>

        <div :if={@subs_empty?} class="text-center py-12 text-base-content/40" id="subs-empty">
          <.icon name="hero-credit-card" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>No hay subscripciones todavía.</p>
        </div>

        <div class="space-y-4" id="providers-subs">
          <div
            :for={provider <- @providers}
            id={"provider-subs-#{provider.id}"}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h3 class="font-semibold text-base-content">{provider.name}</h3>
                <button
                  phx-click="new_subscription"
                  phx-value-provider_id={provider.id}
                  class="btn btn-sm btn-ghost"
                  id={"new-sub-#{provider.id}"}
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Nueva subscripción
                </button>
              </div>

              <p :if={provider.subscriptions == []} class="text-sm text-base-content/40 mt-2">
                Sin subscripciones.
              </p>

              <div :if={provider.subscriptions != []} class="overflow-x-auto mt-2">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Nombre</th>
                      <th>Costo</th>
                      <th>Ciclo</th>
                      <th>Inicio</th>
                      <th>Fin</th>
                      <th>Día cobro</th>
                      <th>Estado</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={sub <- provider.subscriptions} id={"sub-#{sub.id}"}>
                      <td class="font-medium">{sub.name}</td>
                      <td>${fmt_dec(sub.cost)}</td>
                      <td class="capitalize">{sub.billing_cycle}</td>
                      <td>{fmt_date(sub.start_date)}</td>
                      <td>{fmt_date(sub.end_date)}</td>
                      <td>{sub.billing_day || "—"}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          cond do
                            sub_active?(sub) -> "badge-success"
                            sub.status == "exhausted" -> "badge-warning"
                            true -> "badge-ghost"
                          end
                        ]}>
                          {cond do
                            sub_active?(sub) -> "Activa"
                            sub.status == "exhausted" -> "Agotada"
                            sub.status == "cancelled" -> "Cancelada"
                            true -> sub.status
                          end}
                        </span>
                      </td>
                      <td class="text-right">
                        <div class="flex justify-end gap-1">
                          <button
                            phx-click="edit_subscription"
                            phx-value-id={sub.id}
                            class="btn btn-xs btn-ghost"
                            id={"edit-sub-#{sub.id}"}
                          >
                            Editar
                          </button>
                          <button
                            :if={sub.status == "active"}
                            phx-click="mark_exhausted"
                            phx-value-id={sub.id}
                            class="btn btn-xs btn-ghost"
                            id={"exhaust-sub-#{sub.id}"}
                          >
                            Agotar
                          </button>
                          <button
                            :if={sub.status == "active"}
                            phx-click="mark_cancelled"
                            phx-value-id={sub.id}
                            data-confirm="¿Cancelar esta subscripción?"
                            class="btn btn-xs btn-ghost text-error"
                            id={"cancel-sub-#{sub.id}"}
                          >
                            Cancelar
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
    </Layouts.dashboard>
    """
  end
end
