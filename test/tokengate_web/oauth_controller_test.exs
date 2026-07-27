defmodule TokengateWeb.OAuthControllerTest do
  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts

  defp unique, do: System.unique_integer([:positive])

  describe "GET /auth/google" do
    test "redirects to Google consent screen when configured", %{conn: conn} do
      conn = get(conn, "/auth/google")
      assert redirected_to(conn, 302) =~ "accounts.google.com"
    end
  end

  describe "GET /auth/google/callback" do
    test "rejects when error param present", %{conn: conn} do
      conn =
        get(conn, "/auth/google/callback", %{
          "error" => "access_denied"
        })

      assert redirected_to(conn, 302) =~ "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No se pudo completar"
    end
  end

  describe "Accounts.find_or_create_from_google/1" do
    test "finds existing user by google_id" do
      u = unique()

      {:ok, user} =
        Accounts.register_user(%{
          email: "google-#{u}@example.com",
          name: "Google User",
          password: "password-secret-#{u}1"
        })

      # Link google_id
      {:ok, _} =
        Accounts.find_or_create_from_google(%{
          google_id: "google-sub-#{u}",
          email: "google-#{u}@example.com",
          name: "Google User",
          avatar_url: "https://example.com/avatar.jpg"
        })

      # Second call should find by google_id
      {:ok, found} =
        Accounts.find_or_create_from_google(%{
          google_id: "google-sub-#{u}",
          email: "google-#{u}@example.com",
          name: "Google User",
          avatar_url: nil
        })

      assert found.id == user.id
      assert found.google_id == "google-sub-#{u}"
    end

    test "links google_id to existing user by email" do
      u = unique()

      {:ok, user} =
        Accounts.register_user(%{
          email: "link-#{u}@example.com",
          name: "Link User",
          password: "password-secret-#{u}1"
        })

      {:ok, linked} =
        Accounts.find_or_create_from_google(%{
          google_id: "google-sub-#{u}",
          email: "link-#{u}@example.com",
          name: "Link User Updated",
          avatar_url: "https://example.com/avatar.jpg"
        })

      assert linked.id == user.id
      assert linked.google_id == "google-sub-#{u}"
      assert linked.avatar_url == "https://example.com/avatar.jpg"
    end

    test "returns not_found when user doesn't exist" do
      u = unique()

      result =
        Accounts.find_or_create_from_google(%{
          google_id: "google-sub-#{u}",
          email: "nonexistent-#{u}@example.com",
          name: "Ghost User",
          avatar_url: nil
        })

      assert result == {:error, :not_found}
    end

    test "rejects suspended users" do
      u = unique()

      {:ok, user} =
        Accounts.register_user(%{
          email: "suspended-#{u}@example.com",
          name: "Suspended User",
          password: "password-secret-#{u}1"
        })

      {:ok, suspended_user} = Accounts.admin_update_user(user, %{"status" => "suspended"})

      result =
        Accounts.find_or_create_from_google(%{
          google_id: "google-sub-#{u}",
          email: "suspended-#{u}@example.com",
          name: "Suspended User",
          avatar_url: nil
        })

      assert result == {:error, :suspended}
      _ = suspended_user
    end
  end

  describe "Accounts.create_from_google/1" do
    test "creates a new user from google data" do
      u = unique()

      {:ok, user} =
        Accounts.create_from_google(%{
          google_id: "new-google-#{u}",
          email: "new-google-#{u}@example.com",
          name: "New Google User",
          avatar_url: "https://example.com/avatar.jpg"
        })

      assert user.email == "new-google-#{u}@example.com"
      assert user.google_id == "new-google-#{u}"
      assert user.global_role == "user"
      assert user.status == "active"
      assert is_nil(user.password_hash)
    end
  end

  describe "TokengateWeb.OAuth.Google.domain_allowed?/1" do
    test "allows all domains when allowlist is empty" do
      # Test config has allowed_domains: []
      assert TokengateWeb.OAuth.Google.domain_allowed?("anything@example.com")
    end
  end
end
