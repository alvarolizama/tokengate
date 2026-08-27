defmodule TokengateWeb.BudgetsLive do
  @moduledoc """
  Admin Budget page — daily spending caps and their exemptions.

  Holds the global daily cap (moved from Maintenance) and the per-user
  daily cap (evaluated by the proxy BEFORE the global cap). Each cap has
  its own exclusion list: users, teams or services exempt from it. A
  subject exempt from the global cap still spends — its requests just
  don't count toward the global counter.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Exemption
  alias Tokengate.Budgets.Exemptions
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.GlobalSettings

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Budget · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:users, Accounts.list_users())
      |> assign(:teams, Accounts.list_teams())
      |> assign(:services, Accounts.list_services())
      |> assign(:global_subject_type, "user")
      |> assign(:user_subject_type, "user")
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
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "budget.update_global_daily_cap",
          "global_settings",
          nil,
          params
        )

        {:noreply,
         socket
         |> assign_global_settings()
         |> put_flash(:info, "Límite diario global actualizado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :global_form, to_form(changeset, as: :global_settings))}
    end
  end

  def handle_event("save_per_user_cap", %{"global_settings" => params}, socket) do
    case GlobalSettings.update(params) do
      {:ok, _settings} ->
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "budget.update_per_user_daily_cap",
          "global_settings",
          nil,
          params
        )

        {:noreply,
         socket
         |> assign_global_settings()
         |> put_flash(:info, "Límite diario por usuario actualizado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :global_form, to_form(changeset, as: :global_settings))}
    end
  end

  def handle_event("change_global_subject", %{"global_subject" => %{"subject_type" => t}}, socket) do
    {:noreply, assign(socket, :global_subject_type, t)}
  end

  def handle_event("change_user_subject", %{"user_subject" => %{"subject_type" => t}}, socket) do
    {:noreply, assign(socket, :user_subject_type, t)}
  end

  def handle_event("add_global_exemption", %{"global_subject" => params}, socket) do
    add_exemption(socket, "global_daily", params)
  end

  def handle_event("add_user_exemption", %{"user_subject" => params}, socket) do
    add_exemption(socket, "user_daily", params)
  end

  def handle_event("remove_global_exemption", %{"id" => id}, socket) do
    remove_exemption(socket, id)
  end

  def handle_event("remove_user_exemption", %{"id" => id}, socket) do
    remove_exemption(socket, id)
  end

  defp add_exemption(socket, scope, params) do
    subject_type = params["subject_type"]
    subject_id = params["subject_id"]

    cond do
      subject_type in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Selecciona un tipo de sujeto.")}

      subject_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Selecciona a quién excluir.")}

      true ->
        field = Exemption.subject_field(subject_type)

        attrs =
          %{"scope" => scope, "subject_type" => subject_type}
          |> Map.put(to_string(field), subject_id)

        case Exemptions.add(attrs) do
          {:ok, _exemption} ->
            {:noreply,
             socket
             |> assign_exemptions()
             |> put_flash(:info, "Exención agregada.")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, exemption_error(changeset))}
        end
    end
  end

  defp remove_exemption(socket, id) do
    Exemptions.remove(id)

    {:noreply,
     socket
     |> assign_exemptions()
     |> put_flash(:info, "Exención eliminada.")}
  end

  defp exemption_error(changeset) do
    base = "No se pudo agregar la exención"

    case changeset.errors do
      [] ->
        base <> "."

      errors ->
        base <> ": " <> (errors |> Enum.map(fn {_, {msg, _}} -> msg end) |> Enum.join(", "))
    end
  end

  ## Helpers ----------------------------------------------------------------

  defp assign_global_settings(socket) do
    settings = GlobalSettings.get!()
    daily_spend = Budgets.global_daily_spend()
    daily_cap = settings.daily_max_spend_usd
    per_user_cap = settings.daily_max_per_user_usd

    daily_pct =
      if daily_cap && Decimal.compare(daily_cap, Decimal.new(0)) == :gt do
        daily_spend
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
    |> assign(:global_daily_spend, daily_spend)
    |> assign(:global_daily_cap, daily_cap)
    |> assign(:global_daily_pct, daily_pct)
    |> assign(:per_user_cap, per_user_cap)
  end

  defp assign_exemptions(socket) do
    socket
    |> assign(:global_exemptions, Exemptions.list_for_scope("global_daily"))
    |> assign(:user_exemptions, Exemptions.list_for_scope("user_daily"))
  end

  # Options for the "a quién excluir" select, depending on subject_type.
  def subject_options("user", assigns) do
    Enum.map(assigns.users, fn u -> {"#{u.name} — #{u.email}", u.id} end)
  end

  def subject_options("team", assigns) do
    Enum.map(assigns.teams, fn t -> {t.name, t.id} end)
  end

  def subject_options("service", assigns) do
    Enum.map(assigns.services, fn s -> {s.name, s.id} end)
  end

  def subject_options(_, _assigns), do: []

  def fmt_usd(nil), do: "sin límite"

  def fmt_usd(%Decimal{} = d), do: "$" <> Decimal.to_string(Decimal.round(d, 2))
end
