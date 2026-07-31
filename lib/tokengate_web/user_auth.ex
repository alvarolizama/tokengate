defmodule TokengateWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` hooks for browser session authentication.

  These are the LiveView analogues of `TokengateWeb.Plugs.DashboardAuth`.
  They read the `:user_id` from the LiveView session (set by the endpoint
  socket connect_info) and assign `:current_user` on the socket.

  Hooks:

    * `:default`              — assigns `current_user` when present, `nil` otherwise.
    * `:require_authenticated` — redirects to `/login` when no current_user.
    * `:require_admin`         — redirects non-admins (or unauthenticated visitors)
      to `/login` or `/dashboard` respectively.

  Usage in the router:

      live_session :dashboard, on_mount: [{TokengateWeb.UserAuth, :require_authenticated}] do
        live "/dashboard", DashboardLive
      end

      live_session :admin, on_mount: [{TokengateWeb.UserAuth, :require_admin}] do
        # admin-only LiveViews
      end
  """

  import Phoenix.Component, only: [assign_new: 3]

  alias Tokengate.Accounts

  @session_key :user_id

  @doc """
  Assigns `current_user` from the session and gates by mode:

    * `:default` — assigns when present, never redirects.
    * `:require_authenticated` — redirects to `/login` when absent.
    * `:require_admin` — unauthenticated → `/login`, non-admins → `/dashboard`.
  """
  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn -> fetch_user(session) end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)

    {:cont, socket}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    user = fetch_user(session)

    socket =
      socket
      |> assign_new(:current_user, fn -> user end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)
      |> assign_timezone(user)
      |> attach_timezone_handler()

    if user do
      track_presence(socket, user)
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    user = fetch_user(session)

    socket =
      socket
      |> assign_new(:current_user, fn -> user end)
      |> assign_new(:impersonator, fn -> fetch_impersonator(session) end)
      |> assign_timezone(user)
      |> attach_timezone_handler()

    case user do
      %{global_role: "admin"} ->
        track_presence(socket, user)
        {:cont, socket}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}

      _non_admin ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/dashboard")}
    end
  end

  # Assigns the user's timezone on the socket for use in date formatting.
  defp assign_timezone(socket, %{timezone: tz}) when is_binary(tz),
    do: Phoenix.Component.assign(socket, :timezone, tz)

  defp assign_timezone(socket, _), do: Phoenix.Component.assign(socket, :timezone, "Etc/UTC")

  # Attaches a live_hook that handles the "set-timezone" event from the
  # sidebar selector. Persists the timezone to the user's record and
  # updates the socket assign so all date formatters pick it up.
  defp attach_timezone_handler(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :timezone_handler,
      :handle_event,
      &handle_timezone_event/3
    )
  end

  defp handle_timezone_event("set-timezone", %{"timezone" => tz}, socket) do
    user = socket.assigns[:current_user]

    if user && tz != user.timezone do
      case Accounts.update_user_timezone(user, tz) do
        {:ok, updated_user} ->
          {:halt,
           socket
           |> Phoenix.Component.assign(:timezone, tz)
           |> Phoenix.Component.assign(:current_user, updated_user)}

        {:error, _changeset} ->
          {:halt, socket}
      end
    else
      {:halt, Phoenix.Component.assign(socket, :timezone, tz)}
    end
  end

  defp handle_timezone_event(_event, _params, socket), do: {:cont, socket}

  # Track the connected LiveView in Phoenix.Presence so the topbar can show
  # how many users are on the dashboard right now. Only the connected mount
  # owns a real websocket process worth tracking.
  defp track_presence(socket, user) do
    if Phoenix.LiveView.connected?(socket) do
      {:ok, _} = TokengateWeb.Presence.track_user(self(), user)
    end

    :ok
  end

  defp fetch_user(session) do
    # LiveView sessions use string keys; plug sessions may use atoms.
    case session["user_id"] || session[@session_key] do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end

  # The original admin while an impersonation session is active. Stored in
  # the session by SessionController.impersonate/2; `nil` otherwise.
  defp fetch_impersonator(session) do
    case session["impersonator_id"] || session[:impersonator_id] do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end
end
