defmodule TokengateWeb.OAuthController do
  @moduledoc """
  Google OAuth controller — handles the authorization code flow.

  Routes:
    GET /auth/google          → redirects to Google consent screen
    GET /auth/google/callback → processes the callback, creates session

  When OAuth is not configured, both routes redirect to /login with an error.
  """

  use TokengateWeb, :controller
  alias Tokengate.Accounts
  alias TokengateWeb.OAuth.Google

  @doc """
  GET /auth/google — generates a CSRF state, stores it in the session,
  and redirects to Google's consent screen.
  """
  def request(conn, _params) do
    if Google.configured?() do
      state = generate_state()
      url = Google.authorize_url(state)

      conn
      |> put_session(:oauth_state, state)
      |> redirect(external: url)
    else
      conn
      |> put_flash(:error, gettext("Google sign-in is not configured."))
      |> redirect(to: "/login")
    end
  end

  @doc """
  GET /auth/google/callback — validates the state, exchanges the code,
  fetches userinfo, finds or creates the user, and creates the session.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    if not Google.configured?() do
      redirect_to_login(conn, gettext("Google sign-in is not configured."))
    else
      stored_state = get_session(conn, :oauth_state)

      if is_nil(stored_state) or not Plug.Crypto.secure_compare(state, stored_state) do
        redirect_to_login(conn, gettext("Validation error. Try again."))
      else
        conn = delete_session(conn, :oauth_state)
        process_google_callback(conn, code)
      end
    end
  end

  def callback(conn, %{"error" => _error}) do
    redirect_to_login(conn, gettext("Could not complete the Google authentication."))
  end

  defp process_google_callback(conn, code) do
    with {:ok, access_token} <- Google.exchange_code(code),
         {:ok, google_user} <- Google.fetch_userinfo(access_token) do
      handle_google_user(conn, google_user)
    else
      {:error, _reason} ->
        redirect_to_login(conn, gettext("Could not get your Google information."))
    end
  end

  defp handle_google_user(conn, %{email: email} = google_user) do
    case Accounts.find_or_create_from_google(google_user) do
      {:ok, user} ->
        create_session(conn, user)

      {:error, :suspended} ->
        redirect_to_login(conn, gettext("Your account is suspended. Contact an administrator."))

      {:error, :not_found} ->
        # User doesn't exist — check domain allowlist
        if Google.domain_allowed?(email) do
          case Accounts.create_from_google(google_user) do
            {:ok, user} -> create_session(conn, user)
            {:error, _} -> redirect_to_login(conn, gettext("Could not create the account."))
          end
        else
          redirect_to_login(
            conn,
            gettext("Your domain is not authorized. Contact an administrator.")
          )
        end
    end
  end

  defp create_session(conn, user) do
    audit_conn(conn, user, "auth.google_login", "user", user.id, %{"email" => user.email})

    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_flash(:info, gettext("Signed in with Google."))
    |> redirect(to: "/dashboard")
  end

  defp redirect_to_login(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: "/login")
  end

  defp generate_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
