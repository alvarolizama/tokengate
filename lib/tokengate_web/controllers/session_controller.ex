defmodule TokengateWeb.SessionController do
  @moduledoc """
  Email/password session controller for the dashboard.

  Plain Phoenix controller (no LiveView) — the login form is a regular
  HTML form, login/logout use session cookies, and all UI strings are
  in Spanish (the app's UI language).

  Routes (wired in `TokengateWeb.Router`):

      GET    /login   -> :new    (renders the login form)
      POST   /login   -> :create (authenticate, put_session, redirect)
      DELETE /logout  -> :delete (clear session, redirect to /login)
  """

  use TokengateWeb, :controller

  alias Tokengate.Accounts

  @doc """
  GET /login — renders the login form.

  Already-authenticated visitors are redirected to `/dashboard`.
  """
  def new(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/dashboard")
    else
      # Render the login template. `render/2` infers the `:new` template
      # from this controller's `SessionHTML` module.
      conn
      |> assign(:page_title, "Iniciar sesión · Tokengate")
      |> render(:new)
    end
  end

  @doc """
  POST /login — authenticate the submitted credentials.

  On success: puts `:user_id` into the session and redirects to `/dashboard`
  with an info flash. On failure: re-renders the form with an error flash
  and preserves the submitted email.
  """
  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Sesión iniciada.")
        |> redirect(to: "/dashboard")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Credenciales inválidas.")
        |> assign(:email, email)
        |> assign(:page_title, "Iniciar sesión · Tokengate")
        |> render(:new)
    end
  end

  @doc """
  DELETE /logout — clears the session and redirects to `/login`.
  """
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Sesión cerrada.")
    |> redirect(to: "/login")
  end
end
