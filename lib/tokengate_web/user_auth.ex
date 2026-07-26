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
    {:cont, assign_new(socket, :current_user, fn -> fetch_user(session) end)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    user = fetch_user(session)

    socket =
      socket
      |> assign_new(:current_user, fn -> user end)

    if user do
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

    case user do
      %{global_role: "admin"} ->
        {:cont, socket}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}

      _non_admin ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/dashboard")}
    end
  end

  defp fetch_user(session) do
    # LiveView sessions use string keys; plug sessions may use atoms.
    case session["user_id"] || session[@session_key] do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end
end
