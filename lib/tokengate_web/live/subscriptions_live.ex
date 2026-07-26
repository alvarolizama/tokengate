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
  def sub_active?(%{status: "active", end_date: %Date{} = d}), do: Date.compare(d, Date.utc_today()) != :lt
  def sub_active?(_), do: false

  @doc "Format a date or nil"
  def fmt_date(nil), do: "—"
  def fmt_date(%Date{} = d), do: Calendar.strftime(d, "%Y-%m-%d")

  @doc "Format a decimal"
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)
end
