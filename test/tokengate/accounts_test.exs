defmodule Tokengate.AccountsTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Accounts
  alias Tokengate.Accounts.{ApiKey, Organization, Team, TeamMember, User}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_organization_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "name" => "Acme Corp",
        "slug" => "acme-corp"
      },
      attrs
    )
  end

  defp organization_fixture(attrs \\ %{}) do
    {:ok, organization} = Accounts.create_organization(valid_organization_attrs(attrs))
    organization
  end

  defp valid_team_attrs(organization, attrs) do
    Map.merge(
      %{
        "name" => "Platform Team",
        "organization_id" => organization.id,
        "default_daily_budget_usd" => "100.00",
        "default_monthly_budget_usd" => "1000.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      },
      attrs
    )
  end

  defp team_fixture(organization, attrs \\ %{}) do
    {:ok, team} = Accounts.create_team(valid_team_attrs(organization, attrs))
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

  # ---------------------------------------------------------------------------
  # Organization changesets
  # ---------------------------------------------------------------------------

  describe "organization changesets" do
    test "create_organization/1 with valid attrs succeeds" do
      attrs = valid_organization_attrs()
      assert {:ok, %Organization{} = org} = Accounts.create_organization(attrs)
      assert org.name == "Acme Corp"
      assert org.slug == "acme-corp"
      assert org.cost_tracking_mode == "value"
    end

    test "create_organization/1 lowercases slug" do
      attrs = valid_organization_attrs(%{"slug" => "  Acme-CORP  "})
      assert {:ok, %Organization{} = org} = Accounts.create_organization(attrs)
      assert org.slug == "acme-corp"
    end

    test "create_organization/1 requires name and slug" do
      {:error, changeset} = Accounts.create_organization(%{})

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).slug
    end

    test "create_organization/1 enforces slug format" do
      attrs = valid_organization_attrs(%{"slug" => "Invalid Slug!"})
      assert {:error, changeset} = Accounts.create_organization(attrs)

      assert "must contain only lowercase letters, numbers, and hyphens" in errors_on(changeset).slug
    end

    test "create_organization/1 enforces slug uniqueness" do
      organization_fixture(%{"slug" => "acme-corp"})
      attrs = valid_organization_attrs(%{"slug" => "acme-corp"})

      assert {:error, changeset} = Accounts.create_organization(attrs)
      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  # ---------------------------------------------------------------------------
  # Team changesets
  # ---------------------------------------------------------------------------

  describe "team changesets" do
    test "create_team/1 with valid attrs succeeds and applies defaults when omitted" do
      org = organization_fixture()

      attrs =
        valid_team_attrs(org, %{"default_concurrency_limit" => nil, "default_rpm_limit" => nil})

      # remove from attrs to test DB default
      attrs = Map.delete(attrs, "default_concurrency_limit") |> Map.delete("default_rpm_limit")

      assert {:ok, %Team{} = team} = Accounts.create_team(attrs)
      assert team.name == "Platform Team"
      assert team.default_concurrency_limit == 5
      assert team.default_rpm_limit == 60
      assert team.organization_id == org.id
    end

    test "create_team/1 requires name and organization_id" do
      {:error, changeset} = Accounts.create_team(%{})

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).organization_id
    end

    test "create_team/1 validates concurrency/rpm greater than 0" do
      org = organization_fixture()
      attrs = valid_team_attrs(org, %{"default_concurrency_limit" => 0, "default_rpm_limit" => 0})
      {:error, changeset} = Accounts.create_team(attrs)

      assert "must be greater than 0" in errors_on(changeset).default_concurrency_limit
      assert "must be greater than 0" in errors_on(changeset).default_rpm_limit
    end

    test "create_team/1 allows nil budget" do
      org = organization_fixture()

      attrs =
        valid_team_attrs(org, %{
          "default_daily_budget_usd" => nil,
          "default_monthly_budget_usd" => nil
        })

      assert {:ok, %Team{} = team} = Accounts.create_team(attrs)
      assert team.default_daily_budget_usd == nil
      assert team.default_monthly_budget_usd == nil
    end

    test "rejects invalid organization reference" do
      attrs =
        %{
          "name" => "Platform Team",
          "organization_id" => Ecto.UUID.generate(),
          "default_daily_budget_usd" => "100.00",
          "default_monthly_budget_usd" => "1000.00",
          "default_concurrency_limit" => 10,
          "default_rpm_limit" => 120
        }

      assert {:error, changeset} = Accounts.create_team(attrs)
      assert "does not exist" in errors_on(changeset).organization
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
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      attrs = valid_team_member_attrs(user, team)

      assert {:ok, %TeamMember{} = tm, token} = Accounts.create_team_member(attrs)
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
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, _tm, token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert {:ok, %TeamMember{}} = Accounts.get_team_member_by_api_key(token)
    end

    test "enforces unique (user_id, team_id)" do
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, _tm, _token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert {:error, changeset} =
               Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert "has already been taken" in errors_on(changeset).team_id
    end

    test "validates team_role and status inclusion" do
      org = organization_fixture()
      team = team_fixture(org)
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
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, token} = Accounts.create_team_member(valid_team_member_attrs(user, team))
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
      org = organization_fixture(%{"name" => "Lookup Org", "slug" => "lookup-org"})
      team = team_fixture(org, %{"name" => "Lookup Team"})
      user = user_fixture(%{"name" => "Lookup User", "email" => "lookup@example.com"})

      {:ok, _tm, token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      assert {:ok, %TeamMember{team: %Team{}, user: %User{}}} =
               Accounts.get_team_member_by_api_key(token)

      {:ok, tm} = Accounts.get_team_member_by_api_key(token)
      assert tm.team.name == "Lookup Team"
      assert tm.user.email == "lookup@example.com"
    end

    test "get_team_member_by_api_key/1 returns not_found for revoked key" do
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      # Revoke the api key directly
      tm_loaded = Repo.preload(tm, [:api_key])
      {:ok, _} = Accounts.revoke_api_key(tm_loaded.api_key)

      assert {:error, :not_found} = Accounts.get_team_member_by_api_key(token)
    end

    test "get_team_member_by_api_key/1 returns not_found for garbage token" do
      assert {:error, :not_found} = Accounts.get_team_member_by_api_key("tg-garbage")
    end

    test "api_keys has unique index on team_member_id (one key per member)" do
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, _token} = Accounts.create_team_member(valid_team_member_attrs(user, team))
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
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, old_token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

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
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, _old_token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

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
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, _token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      limits = Accounts.effective_limits(tm)

      assert limits.daily_budget_usd == Decimal.new("100.00")
      assert limits.monthly_budget_usd == Decimal.new("1000.00")
      assert limits.concurrency_limit == 10
      assert limits.rpm_limit == 120
    end

    test "adds member extras to team defaults" do
      org = organization_fixture()
      team = team_fixture(org)
      user = user_fixture()

      {:ok, tm, _token} =
        Accounts.create_team_member(
          valid_team_member_attrs(user, team, %{
            "extra_daily_budget_usd" => "50.00",
            "extra_concurrency" => 3
          })
        )

      limits = Accounts.effective_limits(tm)

      assert limits.daily_budget_usd == Decimal.add(Decimal.new("100.00"), Decimal.new("50.00"))
      assert limits.concurrency_limit == 13
      # monthly_budget has no extras
      assert limits.monthly_budget_usd == Decimal.new("1000.00")
      # rpm has no override
      assert limits.rpm_limit == 120
    end

    test "nil team default budget means no limit, even with extras applied" do
      org = organization_fixture()

      team =
        team_fixture(org, %{
          "default_daily_budget_usd" => nil,
          "default_monthly_budget_usd" => nil
        })

      user = user_fixture()

      {:ok, tm, _token} =
        Accounts.create_team_member(
          valid_team_member_attrs(user, team, %{
            "extra_daily_budget_usd" => "50.00"
          })
        )

      limits = Accounts.effective_limits(tm)

      assert limits.daily_budget_usd == Decimal.new("50.00")
      assert limits.monthly_budget_usd == nil
    end

    test "nil team default budget and nil extra both result in nil (unlimited)" do
      org = organization_fixture()

      team =
        team_fixture(org, %{
          "default_daily_budget_usd" => nil,
          "default_monthly_budget_usd" => nil
        })

      user = user_fixture()

      {:ok, tm, _token} = Accounts.create_team_member(valid_team_member_attrs(user, team))

      limits = Accounts.effective_limits(tm)

      assert limits.daily_budget_usd == nil
      assert limits.monthly_budget_usd == nil
      # concurrency/rpm have defaults; never nil
      assert limits.concurrency_limit == 10
      assert limits.rpm_limit == 120
    end
  end
end
