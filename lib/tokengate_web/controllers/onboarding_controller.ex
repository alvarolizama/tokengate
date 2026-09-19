defmodule TokengateWeb.OnboardingController do
  @moduledoc """
  First-run onboarding. While the instance has NO user at all, `/` and `/login`
  send the visitor here instead of the login form, and the account created is
  the instance's first **global admin** — no seed needed.

  Routes (wired in `TokengateWeb.Router`):

      GET  /onboarding -> :new     (renders the form when the instance is empty)
      POST /onboarding -> :create  (creates the first admin, signs them in)

  This is the only place a user is created with nobody authenticated behind it,
  so it is deliberately self-disabling:

    * both actions redirect to `/login` as soon as ONE user exists, and
    * `Accounts.create_first_admin/1` re-checks inside the transaction and
      rolls back, so a race or a hand-crafted POST can't grant a second admin.

  The window is open until the first user exists: anyone who reaches the
  instance before its owner can claim it. Close it either by deploying behind
  your network boundary, or by bootstrapping the admin at boot with
  `TOKENGATE_ADMIN_PASSWORD` (see `priv/repo/seeds_prod.exs`).
  """

  use TokengateWeb, :controller
  alias Tokengate.Accounts

  @doc """
  GET /onboarding — renders the first-run form.

  Redirects to `/login` when the instance already has a user: the page must not
  be reachable (or even reveal itself) after setup.
  """
  def new(conn, _params) do
    if Accounts.any_user?() do
      redirect(conn, to: "/login")
    else
      conn
      |> assign(:page_title, gettext("First run") <> " · Tokengate")
      |> assign(:form, Phoenix.Component.to_form(%{"name" => "", "email" => ""}, as: :user))
      |> render(:new)
    end
  end

  @doc """
  POST /onboarding — creates the first admin and signs them in.

  On success the account is created with `global_role: "admin"`, the session is
  renewed and the visitor lands on `/dashboard`. An already-initialized instance
  (or a lost race) redirects to `/login`.
  """
  def create(conn, %{"user" => params}) do
    case Accounts.create_first_admin(params) do
      {:ok, user} ->
        audit_conn(conn, user, "auth.first_admin", "user", user.id, %{"email" => user.email})

        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_flash(:info, gettext("Welcome. Your admin account is ready."))
        |> redirect(to: "/dashboard")

      {:error, :already_initialized} ->
        conn
        |> put_flash(:error, gettext("This instance is already set up."))
        |> redirect(to: "/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign(:page_title, gettext("First run") <> " · Tokengate")
        |> assign(:form, Phoenix.Component.to_form(changeset, as: :user))
        |> put_status(:unprocessable_entity)
        |> render(:new)
    end
  end
end
