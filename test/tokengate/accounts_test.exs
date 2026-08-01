defmodule Tokengate.AccountsTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Accounts
  alias Tokengate.Accounts.{ApiKey, Service, ServiceSupervisor, Team, TeamMember, User}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_team_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "name" => "Platform Team",
        "monthly_budget_per_user_usd" => "100.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      },
      attrs
    )
  end

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} = Accounts.create_team(valid_team_attrs(attrs))
    team
  end

  defp valid_user_attrs(attrs) do
    Map.merge(
      %{
        "email" => "user#{System.unique_integer([:positive])}@example.com",
        "name" => "Test User",
        "password" => "ValidPassword123"
      },
      attrs
    )
  end

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} = Accounts.register_user(valid_user_attrs(attrs))
    user
  end

  defp valid_team_member_attrs(user, team, attrs \\ %{}) do
    Map.merge(
      %{
        "user_id" => user.id,
        "team_id" => team.id,
        "team_role" => "user"
      },
      attrs
    )
  end

  defp valid_service_attrs(attrs) do
    Map.merge(
      %{
        "name" => "Service #{System.unique_integer([:positive])}",
        "monthly_budget_usd" => "100.00",
        "concurrency_limit" => 5,
        "rpm_limit" => 60
      },
      attrs
    )
  end

  defp service_fixture(attrs \\ %{}) do
    {:ok, service} = Accounts.create_service(valid_service_attrs(attrs))
    service
  end

  # ---------------------------------------------------------------------------
  # Team changesets
  # ---------------------------------------------------------------------------

  describe "team changesets" do
    test "create_team/1 with valid attrs succeeds and applies defaults when omitted" do
      attrs =
        valid_team_attrs(%{"default_concurrency_limit" => nil, "default_rpm_limit" => nil})

      # remove from attrs to test DB default
      attrs = Map.delete(attrs, "default_concurrency_limit") |> Map.delete("default_rpm_limit")

      assert {:ok, %Team{} = team} = Accounts.create_team(attrs)
      assert team.name == "Platform Team"
      assert team.default_concurrency_limit == 5
      assert team.default_rpm_limit == 60
    end

    test "create_team/1 requires name" do
      {:error, changeset} = Accounts.create_team(%{})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "create_team/1 validates concurrency/rpm greater than 0" do
      attrs = valid_team_attrs(%{"default_concurrency_limit" => 0, "default_rpm_limit" => 0})
      {:error, changeset} = Accounts.create_team(attrs)

      assert "must be greater than 0" in errors_on(changeset).default_concurrency_limit
      assert "must be greater than 0" in errors_on(changeset).default_rpm_limit
    end

    test "create_team/1 allows nil budget" do
      attrs = valid_team_attrs(%{"monthly_budget_per_user_usd" => nil})

      assert {:ok, %Team{} = team} = Accounts.create_team(attrs)
      assert team.monthly_budget_per_user_usd == nil
    end
  end

  describe "delete_team/1" do
    test "deletes a team with no members" do
      team = team_fixture()

      assert {:ok, _} = Accounts.delete_team(team)
      assert Accounts.get_team(team.id) == nil
    end

    test "deletes a team and cascades cleanup of members, api keys, and extra aliases" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert {:ok, _} = Accounts.delete_team(team)
      assert Accounts.get_team(team.id) == nil
      assert Accounts.get_team_member(tm.id) == nil
    end

    test "deletes a team with multiple members" do
      team = team_fixture()
      user1 = user_fixture()
      user2 = user_fixture(%{"email" => "user2#{System.unique_integer([:positive])}@example.com"})

      {:ok, tm1} = Accounts.create_team_member(valid_team_member_attrs(user1, team))
      {:ok, tm2} = Accounts.create_team_member(valid_team_member_attrs(user2, team))

      assert {:ok, _} = Accounts.delete_team(team)
      assert Accounts.get_team(team.id) == nil
      assert Accounts.get_team_member(tm1.id) == nil
      assert Accounts.get_team_member(tm2.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # User registration / auth
  # ---------------------------------------------------------------------------

  describe "user registration" do
    test "register_user/1 hashes the password and does not store plaintext" do
      attrs = valid_user_attrs(%{"password" => "ValidPassword123"})
      assert {:ok, %User{} = user} = Accounts.register_user(attrs)
      assert user.password_hash
      assert user.password_hash != "ValidPassword123"
      assert user.global_role == "user"
      # virtual password not persisted (still set on struct for convenience)
      assert user.password == "ValidPassword123"
    end

    test "register_user/1 lowercases email" do
      attrs = valid_user_attrs(%{"email" => "MixedCase@Example.COM"})
      assert {:ok, %User{} = user} = Accounts.register_user(attrs)
      assert user.email == "mixedcase@example.com"
    end

    test "register_user/1 requires a valid email format" do
      attrs = valid_user_attrs(%{"email" => "not-an-email"})
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "must be a valid email address" in errors_on(changeset).email
    end

    test "register_user/1 enforces password min 12 chars" do
      attrs = valid_user_attrs(%{"password" => "Short1"})
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "register_user/1 enforces password has a digit and a letter" do
      no_digit = valid_user_attrs(%{"password" => "NoDigitsPassword"})
      {:error, cs_digit} = Accounts.register_user(no_digit)
      assert "must contain a digit" in errors_on(cs_digit).password

      no_letter = valid_user_attrs(%{"password" => "123456789012"})
      {:error, cs_letter} = Accounts.register_user(no_letter)
      assert "must contain a letter" in errors_on(cs_letter).password
    end

    test "register_user/1 enforces unique email" do
      user_fixture(%{"email" => "dup@example.com"})
      attrs = valid_user_attrs(%{"email" => "DUP@example.com"})
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "authenticate_user/2" do
    test "succeeds with correct credentials" do
      user_fixture(%{"email" => "auth@example.com", "password" => "ValidPassword123"})

      assert {:ok, %User{email: "auth@example.com"}} =
               Accounts.authenticate_user("auth@example.com", "ValidPassword123")
    end

    test "succeeds with mixed-case email input" do
      user_fixture(%{"email" => "auth@example.com", "password" => "ValidPassword123"})
      assert {:ok, _user} = Accounts.authenticate_user("AUTH@example.com", "ValidPassword123")
    end

    test "fails with wrong password" do
      user_fixture(%{"email" => "auth2@example.com", "password" => "ValidPassword123"})

      assert {:error, :unauthorized} =
               Accounts.authenticate_user("auth2@example.com", "WrongPassword456")
    end

    test "fails with unknown email (timing-safe nil)" do
      # Should not raise; should return error and call no_user_verify internally.
      assert {:error, :unauthorized} =
               Accounts.authenticate_user("nonexistent@example.com", "AnyPassword123")
    end
  end

  # ---------------------------------------------------------------------------
  # Team member + API key creation (atomic)
  # ---------------------------------------------------------------------------

  describe "create_team_member/1" do
    test "creates a team member and provisions an API key atomically, returns token once" do
      team = team_fixture()
      user = user_fixture()

      attrs = valid_team_member_attrs(user, team)

      assert {:ok, %TeamMember{} = tm} = Accounts.create_team_member(attrs)
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)
      assert is_binary(token)
      assert String.starts_with?(token, "tg-")

      # API key was created in the same transaction
      tm_loaded = Repo.preload(tm, [:api_key])
      assert %ApiKey{} = api_key = tm_loaded.api_key
      assert api_key.key_hash == Accounts.hash_api_key(token)
      assert api_key.key_prefix == String.slice(token, 0, 8)
      assert api_key.status == "active"
    end

    test "token is verifiable via get_team_member_by_api_key/1" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)

      assert {:ok, %TeamMember{}} = Accounts.get_team_member_by_api_key(token)
    end

    test "enforces unique (user_id, team_id)" do
      team = team_fixture()
      user = user_fixture()

      {:ok, _tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert {:error, changeset} =
               Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert "has already been taken" in errors_on(changeset).team_id
    end

    test "validates team_role and status inclusion" do
      team = team_fixture()
      user = user_fixture()

      attrs =
        valid_team_member_attrs(user, team, %{
          "team_role" => "invalid",
          "status" => "invalid"
        })

      assert {:error, changeset} = Accounts.create_team_member(attrs)
      assert "is invalid" in errors_on(changeset).team_role
      assert "is invalid" in errors_on(changeset).status
    end

    test "does not store the plaintext token; only the hash" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)
      tm_loaded = Repo.preload(tm, [:api_key])

      refute tm_loaded.api_key.key_hash == token
      refute String.contains?(tm_loaded.api_key.key_hash, token)
    end
  end

  # ---------------------------------------------------------------------------
  # API key lookup / replace
  # ---------------------------------------------------------------------------

  describe "api key generation & lookup" do
    test "generate_api_key_material/0 produces tg- prefixed, base64url token" do
      {token, hash, prefix} = Accounts.generate_api_key_material()

      assert String.starts_with?(token, "tg-")
      assert byte_size(token) > 20
      assert String.length(prefix) == 8
      assert prefix == String.slice(token, 0, 8)
      # Hash is lowercase hex sha256
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash)
      assert hash == Accounts.hash_api_key(token)
    end

    test "get_team_member_by_api_key/1 preloads team and user" do
      team = team_fixture(%{"name" => "Lookup Team"})
      user = user_fixture(%{"name" => "Lookup User", "email" => "lookup@example.com"})

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)

      assert {:ok, %TeamMember{team: %Team{}, user: %User{}}} =
               Accounts.get_team_member_by_api_key(token)

      {:ok, tm} = Accounts.get_team_member_by_api_key(token)
      assert tm.team.name == "Lookup Team"
      assert tm.user.email == "lookup@example.com"
    end

    test "get_team_member_by_api_key/1 returns not_found for revoked key" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))
      {:ok, _api_key, token} = Accounts.replace_api_key(tm)

      # Revoke the api key directly
      tm_loaded = Repo.preload(tm, [:api_key])
      {:ok, _} = Accounts.revoke_api_key(tm_loaded.api_key)

      assert {:error, :not_found} = Accounts.get_team_member_by_api_key(token)
    end

    test "get_team_member_by_api_key/1 returns not_found for garbage token" do
      assert {:error, :not_found} = Accounts.get_team_member_by_api_key("tg-garbage")
    end

    test "api_keys has unique index on team_member_id (one key per member)" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))
      {:ok, _api_key, _token} = Accounts.replace_api_key(tm)
      tm_loaded = Repo.preload(tm, [:api_key])

      # Attempt to insert a second api key for the same team_member directly
      {:error, changeset} =
        Accounts.create_api_key(%{
          "team_member_id" => tm_loaded.id,
          "key_hash" => Accounts.hash_api_key("tg-somethingelse"),
          "key_prefix" => "tg-somet"
        })

      assert "has already been taken" in errors_on(changeset).team_member_id
    end
  end

  describe "replace_api_key/1" do
    test "revokes the old key and issues a new one, returning new token" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))
      {:ok, _old_key, old_token} = Accounts.replace_api_key(tm)

      assert {:ok, %ApiKey{} = new_key, new_token} = Accounts.replace_api_key(tm)
      assert new_token != old_token
      assert String.starts_with?(new_token, "tg-")
      assert new_key.status == "active"
      assert new_key.key_hash == Accounts.hash_api_key(new_token)

      # Old token no longer resolves to an active key
      assert {:error, :not_found} = Accounts.get_team_member_by_api_key(old_token)
      # New token does
      assert {:ok, _} = Accounts.get_team_member_by_api_key(new_token)
    end

    test "old token is invalidated after replacement" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      {:ok, _new_key, _new_token} = Accounts.replace_api_key(tm)

      # There is still exactly one api_key row for this team_member
      tm_loaded = Repo.preload(tm, [:api_key])
      assert tm_loaded.api_key.status == "active"
      # The key hash has changed (no longer matches the old token)
      refute tm_loaded.api_key.key_hash == Accounts.hash_api_key("old")
    end
  end

  # ---------------------------------------------------------------------------
  # effective_limits/1
  # ---------------------------------------------------------------------------

  describe "effective_limits/1" do
    test "returns team defaults when no member extras are set" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      limits = Accounts.effective_limits(tm)

      assert limits.monthly_budget_usd == Decimal.new("100.00")
      assert limits.concurrency_limit == 10
      assert limits.rpm_limit == 120
    end

    test "adds extra_monthly_budget_usd to team default" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} =
        Accounts.create_team_member(
          valid_team_member_attrs(user, team, %{"extra_monthly_budget_usd" => "50.00"})
        )

      limits = Accounts.effective_limits(tm)

      assert limits.monthly_budget_usd == Decimal.new("150.00")
    end

    test "adds extra_concurrency to team default" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} =
        Accounts.create_team_member(
          valid_team_member_attrs(user, team, %{"extra_concurrency" => 5})
        )

      limits = Accounts.effective_limits(tm)

      assert limits.concurrency_limit == 15
    end

    test "adds extra_rpm to team default" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} =
        Accounts.create_team_member(valid_team_member_attrs(user, team, %{"extra_rpm" => 40}))

      limits = Accounts.effective_limits(tm)

      assert limits.rpm_limit == 160
    end

    test "nil team monthly_budget_usd with nil extra → nil" do
      team = team_fixture(%{"monthly_budget_per_user_usd" => nil})
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      limits = Accounts.effective_limits(tm)

      assert limits.monthly_budget_usd == nil
    end

    test "nil team monthly_budget_usd with extra → just the extra" do
      team = team_fixture(%{"monthly_budget_per_user_usd" => nil})
      user = user_fixture()

      {:ok, tm} =
        Accounts.create_team_member(
          valid_team_member_attrs(user, team, %{"extra_monthly_budget_usd" => "25.00"})
        )

      limits = Accounts.effective_limits(tm)

      assert limits.monthly_budget_usd == Decimal.new("25.00")
    end
  end

  # ---------------------------------------------------------------------------
  # Service supervisors
  # ---------------------------------------------------------------------------

  describe "service supervisors" do
    test "add_service_supervisor/2 + services_for_supervisor/1 returns the service" do
      service = service_fixture(%{"name" => "Alpha"})
      user = user_fixture()

      assert {:ok, %ServiceSupervisor{} = supervisor} =
               Accounts.add_service_supervisor(service.id, user.id)

      assert supervisor.service_id == service.id
      assert supervisor.user_id == user.id

      services = Accounts.services_for_supervisor(user.id)
      assert [%Service{id: id}] = services
      assert id == service.id
    end

    test "services_for_supervisor/1 orders by name" do
      user = user_fixture()

      later = service_fixture(%{"name" => "Zeta"})
      earlier = service_fixture(%{"name" => "Alpha"})

      {:ok, _} = Accounts.add_service_supervisor(later.id, user.id)
      {:ok, _} = Accounts.add_service_supervisor(earlier.id, user.id)

      services = Accounts.services_for_supervisor(user.id)
      assert Enum.map(services, & &1.name) == ["Alpha", "Zeta"]
    end

    test "services_for_supervisor/1 preloads :api_key" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

      [%Service{} = s] = Accounts.services_for_supervisor(user.id)
      # After `preload: [:api_key]`, the field is either a real %ServiceApiKey{}
      # or `nil` (has_one with no result). Critically, the field is NOT left
      # as %Ecto.Association.NotLoaded{} — that would prove preload was missed.
      refute match?(%Ecto.Association.NotLoaded{}, s.api_key)
    end

    test "add_service_supervisor/2 is idempotent — second add returns the existing row" do
      service = service_fixture()
      user = user_fixture()

      assert {:ok, first} = Accounts.add_service_supervisor(service.id, user.id)
      assert {:ok, second} = Accounts.add_service_supervisor(service.id, user.id)
      assert first.id == second.id
      # Only one row exists
      assert length(Accounts.service_supervisor_ids(service.id)) == 1
    end

    test "remove_service_supervisor/2 + services_for_supervisor/1 returns empty" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
      assert length(Accounts.services_for_supervisor(user.id)) == 1

      assert {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)
      assert Accounts.services_for_supervisor(user.id) == []
      assert Accounts.service_supervisor_ids(service.id) == []
    end

    test "remove_service_supervisor/2 is idempotent — second remove is :not_found" do
      service = service_fixture()
      user = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

      assert {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)
      assert {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
      # Calling again still does not error
      assert {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
    end

    test "remove_service_supervisor/2 on never-added pair returns :not_found" do
      service = service_fixture()
      user = user_fixture()

      assert {:ok, :not_found} = Accounts.remove_service_supervisor(service.id, user.id)
    end

    test "service_supervisor_ids/1 returns the supervising user ids" do
      service = service_fixture()
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, _} = Accounts.add_service_supervisor(service.id, user1.id)
      {:ok, _} = Accounts.add_service_supervisor(service.id, user2.id)

      ids = Accounts.service_supervisor_ids(service.id)
      assert length(ids) == 2
      assert user1.id in ids
      assert user2.id in ids
    end

    test "service_supervisor_ids/1 is empty for a service with no supervisors" do
      service = service_fixture()
      assert Accounts.service_supervisor_ids(service.id) == []
    end

    test "service_supervisors/1 returns structs with :user preloaded" do
      service = service_fixture()

      user1 =
        user_fixture(%{
          "name" => "Alpha User",
          "email" => "alpha#{System.unique_integer([:positive])}@example.com"
        })

      user2 =
        user_fixture(%{
          "name" => "Beta User",
          "email" => "beta#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _} = Accounts.add_service_supervisor(service.id, user1.id)
      {:ok, _} = Accounts.add_service_supervisor(service.id, user2.id)

      supervisors = Accounts.service_supervisors(service.id)
      assert length(supervisors) == 2

      for %ServiceSupervisor{user: %User{}} = ss <- supervisors do
        assert ss.service_id == service.id
        assert ss.user_id in [user1.id, user2.id]
      end

      user_ids = supervisors |> Enum.map(& &1.user_id) |> Enum.sort()
      assert user_ids == Enum.sort([user1.id, user2.id])
    end

    test "service_supervisors/1 is empty for a service with no supervisors" do
      service = service_fixture()
      assert Accounts.service_supervisors(service.id) == []
    end
  end
end
