defmodule TokengateWeb.Plugs.DashboardAuth do
  @moduledoc """
  Session-based authentication plugs for the browser dashboard.

  These plugs run inside the `:browser` pipeline and read the `:user_id`
  key from the session (set by `TokengateWeb.SessionController.create/2`).

  Three actions are exposed via the `:action` option:

    * `:fetch_current_user` (default) — assigns `:current_user` when the
      session carries a valid `:user_id`. Always assigns `nil` when absent.
    * `:require_authenticated` — when `:current_user` is missing,
      redirects to `/login` with an error flash.
    * `:require_admin` — when `:current_user` is not an admin, redirects
      to `/login` (unauthenticated) or `/dashboard` (authenticated non-admin)
      with an error flash.

  The user lookup goes through `Tokengate.Accounts.get_user/1`, returning
  `nil` for stale or missing ids (the session is treated as unauthenticated).
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias Tokengate.Accounts

  @session_key :user_id

  @impl true
  def init(opts) do
    action = Keyword.get(opts, :action, :fetch_current_user)
    action
  end

  @impl true
  def call(conn, action) do
    case action do
      :fetch_current_user -> fetch_current_user(conn)
      :require_authenticated -> require_authenticated(conn)
      :require_admin -> require_admin(conn)
    end
  end

  @doc """
  Assigns `:current_user` from the session `:user_id` key.

  Always assigns `current_user` (to `nil` when absent/stale), so downstream
  plugs and templates can pattern-match safely.
  """
  def fetch_current_user(conn) do
    user =
      case get_session(conn, @session_key) do
        nil -> nil
        id -> Accounts.get_user(id)
      end

    assign(conn, :current_user, user)
  end

  @doc """
  Halts and redirects to `/login` when `:current_user` is not present.

  Sets an error flash in Spanish (the app UI language).
  """
  def require_authenticated(conn) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Debes iniciar sesión para continuar.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  @doc """
  Guards admin-only routes. Requires `:current_user` to be present and to
  carry `global_role == "admin"`.

  For unauthenticated visitors: redirects to `/login` with an error flash.
  For authenticated non-admins: redirects to `/dashboard` with an error flash.
  """
  def require_admin(conn) do
    case conn.assigns[:current_user] do
      %{global_role: "admin"} ->
        conn

      nil ->
        conn
        |> put_flash(:error, "Debes iniciar sesión para continuar.")
        |> redirect(to: "/login")
        |> halt()

      _non_admin ->
        conn
        |> put_flash(:error, "No tienes permisos para acceder a esta sección.")
        |> redirect(to: "/dashboard")
        |> halt()
    end
  end
end
