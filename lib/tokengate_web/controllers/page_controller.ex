defmodule TokengateWeb.PageController do
  use TokengateWeb, :controller

  alias Tokengate.Accounts

  @doc """
  GET / — sends the visitor to the dashboard, the first-run onboarding, or the
  login form, in that order.

  The onboarding branch is what makes a fresh instance usable without a seed:
  with zero users there is no password that could log anybody in, so the login
  form would be a dead end (and there is no self-registration route).
  """
  def home(conn, _params) do
    cond do
      conn.assigns[:current_user] -> redirect(conn, to: "/dashboard")
      not Accounts.any_user?() -> redirect(conn, to: "/onboarding")
      true -> redirect(conn, to: "/login")
    end
  end
end
