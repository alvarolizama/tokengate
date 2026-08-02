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

  require Logger

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
      |> assign(:google_oauth_configured, TokengateWeb.OAuth.Google.configured?())
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
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Sesión iniciada.")
        |> redirect(to: "/dashboard")

      {:error, reason} ->
        # Uniform message: distinguishing :suspended from :unauthorized would
        # let an unauthenticated visitor enumerate which emails are registered
        # and suspended. The real reason is logged server-side.
        Logger.warning("login_failed status=#{reason}")

        conn
        |> put_flash(:error, "Credenciales inválidas.")
        |> assign(:email, email)
        |> assign(:google_oauth_configured, TokengateWeb.OAuth.Google.configured?())
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

  ## Impersonation ------------------------------------------------------------

  @doc """
  POST /impersonate/:user_id — starts an impersonation session.

  Only a real admin (no active impersonation) can start one. The session
  keeps `:user_id` pointing at the *effective* user (so every downstream
  plug, LiveView hook and Presence tracker works unchanged) and stores the
  original admin id under `:impersonator_id`.

  Guards: authenticated, admin, not already impersonating, not self, target
  exists, and the root admin can never be impersonated. Every start is
  written to the audit log.
  """
  def impersonate(conn, %{"user_id" => user_id}) do
    admin = conn.assigns[:current_user]

    cond do
      is_nil(admin) ->
        conn
        |> put_flash(:error, "Debes iniciar sesión para continuar.")
        |> redirect(to: "/login")

      get_session(conn, :impersonator_id) ->
        conn
        |> put_flash(:error, "Ya estás viendo como otro usuario. Vuelve a tu cuenta primero.")
        |> redirect(to: "/dashboard")

      admin.global_role != "admin" ->
        conn
        |> put_flash(:error, "No tienes permisos para impersonar usuarios.")
        |> redirect(to: "/dashboard")

      true ->
        do_impersonate(conn, admin, Accounts.get_user(user_id))
    end
  end

  defp do_impersonate(conn, _admin, nil) do
    conn
    |> put_flash(:error, "Usuario no encontrado.")
    |> redirect(to: "/dashboard/users")
  end

  defp do_impersonate(conn, %{id: admin_id} = _admin, %{id: target_id})
       when admin_id == target_id do
    conn
    |> put_flash(:error, "No puedes impersonarte a ti mismo.")
    |> redirect(to: "/dashboard/users")
  end

  defp do_impersonate(conn, admin, target) do
    if root_admin?(target) do
      conn
      |> put_flash(:error, "No se puede impersonar al administrador principal.")
      |> redirect(to: "/dashboard/users")
    else
      {:ok, _} =
        Tokengate.Auditing.audit(admin, "impersonate.start", "user", target.id, %{
          "email" => target.email
        })

      conn
      |> configure_session(renew: true)
      |> put_session(:impersonator_id, admin.id)
      |> put_session(:user_id, target.id)
      |> put_flash(:info, "Ahora estás viendo como #{target.email}.")
      |> redirect(to: "/dashboard")
    end
  end

  @doc """
  DELETE /impersonate — ends the impersonation and restores the original
  admin session. No-op (with an error flash) when not impersonating.
  """
  def stop_impersonating(conn, _params) do
    case get_session(conn, :impersonator_id) do
      nil ->
        conn
        |> put_flash(:error, "No estás impersonando a ningún usuario.")
        |> redirect(to: "/dashboard")

      impersonator_id ->
        target = conn.assigns[:current_user]

        {:ok, _} =
          Tokengate.Auditing.audit(
            impersonator_id,
            "impersonate.stop",
            "user",
            target && target.id,
            %{"email" => target && target.email}
          )

        conn
        |> configure_session(renew: true)
        |> delete_session(:impersonator_id)
        |> put_session(:user_id, impersonator_id)
        |> put_flash(:info, "Volviste a tu cuenta.")
        |> redirect(to: "/dashboard")
    end
  end

  # The root admin (bootstrap account from seeds/env) can never be
  # impersonated — mirrors the guard in UsersLive.
  defp root_admin?(%{email: email}) do
    root_email = System.get_env("TOKENGATE_ADMIN_EMAIL") || "admin@tokengate.local"
    String.downcase(email) == String.downcase(root_email)
  end
end
