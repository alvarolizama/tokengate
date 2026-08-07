defmodule Tokengate.Routing.RouterTest do
  @moduledoc """
  Tests for `Tokengate.Routing.Router`.

  Uses the real `CircuitBreakerManager` (started by the app tree) with unique
  credential ids per test to avoid state leakage. The `StickyTracker` singleton
  is also live (priority stickiness); tests that need determinism pass a nil
  api_key_hash or unique hashes.

  async: false because the app-tree singletons (StickyTracker ETS table,
  CircuitBreakerManager, round-robin ETS counter table) are shared process
  state not isolated per-test.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Providers
  alias Tokengate.Routing.{Router, CircuitBreakerManager}

  # ---------------------------------------------------------------------------
  # Test-only schemas for FK parent tables owned by the Accounts context.
  # (Same pattern as ProvidersTest — avoids depending on Accounts context
  # which may not be compiled in isolation.)
  # ---------------------------------------------------------------------------

  defmodule TestTeam do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "teams" do
      field :name, :string
      field :monthly_budget_per_user_usd, :decimal
      field :default_concurrency_limit, :integer, default: 5
      field :default_rpm_limit, :integer, default: 60
      timestamps(type: :utc_datetime)
    end

    def changeset(team, attrs) do
      team
      |> cast(attrs, [:name, :default_concurrency_limit, :default_rpm_limit])
      |> validate_required([:name])
    end
  end

  defmodule TestUser do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "users" do
      field :email, :string
      field :name, :string
      field :password_hash, :string
      field :global_role, :string, default: "user"
      timestamps(type: :utc_datetime)
    end

    def changeset(user, attrs) do
      user
      |> cast(attrs, [:email, :name, :password_hash, :global_role])
      |> validate_required([:email, :name, :password_hash])
    end
  end

  defmodule TestTeamMember do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "team_members" do
      field :team_role, :string, default: "user"
      field :extra_monthly_budget_usd, :decimal
      field :extra_concurrency, :integer
      field :status, :string, default: "active"
      belongs_to :team, TestTeam
      belongs_to :user, TestUser
      timestamps(type: :utc_datetime)
    end

    def changeset(member, attrs) do
      member
      |> cast(attrs, [:team_id, :user_id, :team_role, :status])
      |> validate_required([:team_id, :user_id])
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      %TestTeam{}
      |> TestTeam.changeset(Map.merge(%{name: "Engineering"}, attrs))
      |> Repo.insert()

    team
  end

  defp user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      %TestUser{}
      |> TestUser.changeset(
        Map.merge(
          %{email: "user-#{unique}@example.com", name: "User #{unique}", password_hash: "hash"},
          attrs
        )
      )
      |> Repo.insert()

    user
  end

  defp team_member_fixture(team, attrs \\ %{}) do
    {:ok, member} =
      %TestTeamMember{}
      |> TestTeamMember.changeset(
        Map.merge(%{team_id: team.id, user_id: user_fixture().id}, attrs)
      )
      |> Repo.insert()

    member
  end

  defp provider_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "Provider-#{unique}",
        base_url: "https://api.example.com",
        billing_type: "pay_per_token"
      })

    {:ok, provider} = Providers.create_provider(attrs)
    provider
  end

  defp credential_fixture(provider, attrs) do
    attrs =
      Enum.into(attrs, %{
        provider_id: provider.id,
        api_key_encrypted: "sk-test-#{System.unique_integer([:positive])}",
        status: "active"
      })

    {:ok, credential} = Providers.create_credential(attrs)
    credential
  end

  defp model_alias_fixture(attrs) do
    unique = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "model-#{unique}",
        display_name: "Model #{unique}",
        context_window: 128_000
      })

    {:ok, model_alias} = Providers.create_model_alias(attrs)
    model_alias
  end

  defp model_provider_fixture(model_alias, provider, attrs) do
    credential = Map.get_lazy(attrs, :credential, fn -> credential_fixture(provider, %{}) end)
    attrs = Map.delete(attrs, :credential)

    attrs =
      Enum.into(attrs, %{
        model_alias_id: model_alias.id,
        credential_id: credential.id,
        provider_model: "upstream-model",
        enabled: true
      })

    {:ok, ap} = Providers.create_model_provider(attrs)
    ap
  end

  # Builds a full routing fixture: team, member, alias (granted to team),
  # provider + active credential, and an enabled model_provider.
  defp full_setup(opts \\ []) do
    team = team_fixture()
    member = team_member_fixture(team)

    alias_name = Keyword.get(opts, :alias_name, "gpt-4")
    model_alias = model_alias_fixture(%{name: alias_name, display_name: alias_name})
    {:ok, _} = Providers.grant_alias_to_team(team.id, model_alias.id)

    provider = provider_fixture()
    credential = credential_fixture(provider, %{status: "active"})

    ap =
      model_provider_fixture(model_alias, provider, %{
        provider_model: Keyword.get(opts, :provider_model, "gpt-4-turbo"),
        priority: Keyword.get(opts, :priority, 1),
        credential: credential
      })

    member = Repo.preload(member, [:team])

    %{
      team: team,
      member: member,
      model_alias: model_alias,
      provider: provider,
      credential: credential,
      model_provider: ap
    }
  end

  # ---------------------------------------------------------------------------
  # route/3 happy path
  # ---------------------------------------------------------------------------

  describe "route/3 happy path" do
    test "resolves alias, picks priority provider, attaches credential" do
      f = full_setup()

      assert {:ok, route} = Router.route(f.model_alias.name, f.member)

      assert route.model_alias.id == f.model_alias.id
      assert route.model_provider.id == f.model_provider.id
      assert route.credential.id == f.credential.id
      assert route.model_responded == "gpt-4-turbo"
    end

    test "works without team preloaded (preloads internally)" do
      f = full_setup()
      # Strip the preloaded team
      member = Map.put(f.member, :team, nil)

      assert {:ok, route} = Router.route(f.model_alias.name, member)
      assert route.model_alias.id == f.model_alias.id
    end
  end

  # ---------------------------------------------------------------------------
  # model_not_found / access control
  # ---------------------------------------------------------------------------

  describe "access control" do
    test "returns model_not_found when alias is not accessible (no team grant)" do
      team = team_fixture()
      member = team_member_fixture(team)

      # Alias exists but is NOT granted to the team.
      model_alias = model_alias_fixture(%{name: "claude", display_name: "Claude"})

      member = Repo.preload(member, [:team])

      assert {:error, :model_not_found} = Router.route(model_alias.name, member)
    end

    test "extra alias grant makes an otherwise-unganted alias accessible" do
      team = team_fixture()
      member = team_member_fixture(team)

      # Alias not granted to team...
      model_alias = model_alias_fixture(%{name: "claude", display_name: "Claude"})
      # ...but granted as an extra alias to the member directly.
      {:ok, _} = Providers.grant_extra_alias(member.id, model_alias.id)

      provider = provider_fixture()
      credential = credential_fixture(provider, %{status: "active"})

      model_provider_fixture(model_alias, provider, %{
        provider_model: "claude-3",
        credential: credential
      })

      member = Repo.preload(member, [:team])

      assert {:ok, route} = Router.route(model_alias.name, member)
      assert route.model_alias.id == model_alias.id
      assert route.model_responded == "claude-3"
    end

    test "returns model_not_found for a name that does not exist at all" do
      f = full_setup()

      assert {:error, :model_not_found} = Router.route("nonexistent-model", f.member)
    end
  end

  # ---------------------------------------------------------------------------
  # Routing rules
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # no_providers_configured / no active credential
  # ---------------------------------------------------------------------------

  describe "provider / credential errors" do
    test "returns no_providers_configured when alias has no enabled model_providers" do
      f = full_setup()
      # Disable the only alias provider.
      {:ok, _} = Providers.update_model_provider(f.model_provider, %{enabled: false})

      assert {:error, :no_providers_configured} = Router.route(f.model_alias.name, f.member)
    end

    test "model_provider without active credential is dropped" do
      team = team_fixture()
      member = team_member_fixture(team)

      model_alias = model_alias_fixture(%{name: "gpt-4", display_name: "GPT-4"})
      {:ok, _} = Providers.grant_alias_to_team(team.id, model_alias.id)

      provider = provider_fixture()
      # Only a disabled credential.
      disabled_cred = credential_fixture(provider, %{status: "disabled"})

      model_provider_fixture(model_alias, provider, %{credential: disabled_cred})

      member = Repo.preload(member, [:team])

      assert {:error, :no_available_provider} = Router.route(model_alias.name, member)
    end
  end

  # ---------------------------------------------------------------------------
  # Strategy dispatch
  # ---------------------------------------------------------------------------

  describe "strategy dispatch" do
    test "priority strategy picks the highest-priority provider" do
      f = full_setup()

      # Add a second, lower-priority provider.
      provider2 = provider_fixture()
      cred2 = credential_fixture(provider2, %{status: "active"})

      model_provider_fixture(f.model_alias, provider2, %{
        priority: 10,
        provider_model: "gpt-4-backup",
        credential: cred2
      })

      # First provider has priority 1 (from full_setup default).
      assert {:ok, route} = Router.route(f.model_alias.name, f.member)
      assert route.model_provider.priority == 1
    end
  end

  # ---------------------------------------------------------------------------
  # exclude_credential_ids (fallback)
  # ---------------------------------------------------------------------------

  describe "exclude_credential_ids (fallback)" do
    test "drops the first credential and falls back to the second" do
      f = full_setup()

      provider2 = provider_fixture()
      cred2 = credential_fixture(provider2, %{status: "active"})

      ap2 =
        model_provider_fixture(f.model_alias, provider2, %{
          priority: 10,
          provider_model: "backup-model",
          credential: cred2
        })

      # First call: picks priority-1 provider (cred1).
      assert {:ok, route1} = Router.route(f.model_alias.name, f.member)
      assert route1.credential.id == f.credential.id

      # Now exclude cred1 -> should fall back to cred2.
      assert {:ok, route2} =
               Router.route(f.model_alias.name, f.member, %{
                 exclude_credential_ids: [f.credential.id]
               })

      assert route2.credential.id == cred2.id
      assert route2.model_provider.id == ap2.id
    end

    test "exclude via opts keyword" do
      f = full_setup()

      provider2 = provider_fixture()
      cred2 = credential_fixture(provider2, %{status: "active"})
      _ap2 = model_provider_fixture(f.model_alias, provider2, %{priority: 10, credential: cred2})

      assert {:ok, route} =
               Router.route(f.model_alias.name, f.member, %{},
                 exclude_credential_ids: [f.credential.id]
               )

      assert route.credential.id == cred2.id
    end

    test "excluding all credentials returns no_available_provider" do
      f = full_setup()

      provider2 = provider_fixture()
      cred2 = credential_fixture(provider2, %{status: "active"})
      _ap2 = model_provider_fixture(f.model_alias, provider2, %{priority: 10, credential: cred2})

      assert {:error, :no_available_provider} =
               Router.route(f.model_alias.name, f.member, %{
                 exclude_credential_ids: [f.credential.id, cred2.id]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # record_outcome / breaker integration
  # ---------------------------------------------------------------------------

  describe "record_outcome/2" do
    test "success records to the breaker" do
      f = full_setup()

      assert {:ok, route} = Router.route(f.model_alias.name, f.member)
      assert :ok = Router.record_outcome(route, :success)

      # Breaker should still be closed after a success.
      assert CircuitBreakerManager.status(route.credential.id) == :closed
    end

    test "failure records to the breaker; consecutive server_errors trip it to :open" do
      f = full_setup()

      assert {:ok, route} = Router.route(f.model_alias.name, f.member)
      cred_id = route.credential.id

      # Reset breaker for this credential id before recording failures.
      CircuitBreakerManager.reset(cred_id)

      for _ <- 1..15 do
        assert :ok = Router.record_outcome(route, {:failure, :server_error})
      end

      assert CircuitBreakerManager.status(cred_id) == :open
      assert CircuitBreakerManager.allow?(cred_id) == false
    end

    test "rate_limited failures on a pay_per_token provider still trip the breaker" do
      f = full_setup()

      # pay_per_token is the default billing_mode for a fresh model_provider.
      assert f.model_provider.billing_mode == "pay_per_token"

      assert {:ok, route} = Router.route(f.model_alias.name, f.member)
      cred_id = route.credential.id

      CircuitBreakerManager.reset(cred_id)

      for _ <- 1..15 do
        assert :ok = Router.record_outcome(route, {:failure, :rate_limited})
      end

      assert CircuitBreakerManager.status(cred_id) == :open
      assert CircuitBreakerManager.allow?(cred_id) == false
    end

    test "rate_limited failures on an included provider do NOT trip the breaker" do
      f = full_setup()

      {:ok, mp} = Providers.update_model_provider(f.model_provider, %{billing_mode: "included"})

      assert {:ok, route} = Router.route(f.model_alias.name, f.member)
      assert route.model_provider.billing_mode == "included"
      cred_id = route.credential.id

      CircuitBreakerManager.reset(cred_id)
      Tokengate.Routing.CredentialHealth.mark_healthy(cred_id)

      for _ <- 1..15 do
        assert :ok = Router.record_outcome(route, {:failure, :rate_limited})
      end

      # Flush the CredentialHealth GenServer mailbox so the async mark_slow
      # casts have been handled before we assert on the ETS table.
      _ = :sys.get_state(Tokengate.Routing.CredentialHealth)

      # The breaker stays closed — 429s on a subscription are capacity, not death.
      assert CircuitBreakerManager.status(cred_id) == :closed
      assert CircuitBreakerManager.allow?(cred_id) == true

      # But the credential is degraded within its tier instead.
      assert Tokengate.Routing.CredentialHealth.degraded?(cred_id)

      # Silence the unused-variable warning pattern; mp proves the update took.
      assert mp.billing_mode == "included"
    end

    test "server_error on an included provider still trips the breaker" do
      f = full_setup()

      {:ok, _mp} = Providers.update_model_provider(f.model_provider, %{billing_mode: "included"})

      assert {:ok, route} = Router.route(f.model_alias.name, f.member)
      cred_id = route.credential.id

      CircuitBreakerManager.reset(cred_id)

      for _ <- 1..15 do
        assert :ok = Router.record_outcome(route, {:failure, :server_error})
      end

      # A dead credential is a dead credential — included or not.
      assert CircuitBreakerManager.status(cred_id) == :open
      assert CircuitBreakerManager.allow?(cred_id) == false
    end
  end

  # ---------------------------------------------------------------------------
  # models_for/1
  # ---------------------------------------------------------------------------

  describe "models_for/1" do
    test "returns only accessible aliases with correct shape" do
      team = team_fixture()
      member = team_member_fixture(team)

      alias1 =
        model_alias_fixture(%{name: "gpt-4", display_name: "GPT-4", context_window: 128_000})

      _alias2 =
        model_alias_fixture(%{
          name: "claude-3",
          display_name: "Claude 3",
          context_window: 200_000
        })

      # Grant only alias1 to the team.
      {:ok, _} = Providers.grant_alias_to_team(team.id, alias1.id)

      member = Repo.preload(member, [:team])

      models = Router.models_for(member)
      names = Enum.map(models, & &1.id)

      assert "gpt-4" in names
      refute "claude-3" in names

      [model] = models
      assert model.object == "model"
      assert model.context_window == 128_000
      assert model.owned_by == "tokengate"
    end

    test "includes extra-alias grants" do
      team = team_fixture()
      member = team_member_fixture(team)

      alias1 =
        model_alias_fixture(%{name: "gpt-4", display_name: "GPT-4", context_window: 128_000})

      alias2 =
        model_alias_fixture(%{
          name: "claude-3",
          display_name: "Claude 3",
          context_window: 200_000
        })

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias1.id)
      {:ok, _} = Providers.grant_extra_alias(member.id, alias2.id)

      member = Repo.preload(member, [:team])

      models = Router.models_for(member)
      ids = Enum.map(models, & &1.id) |> MapSet.new()

      assert MapSet.member?(ids, "gpt-4")
      assert MapSet.member?(ids, "claude-3")
    end
  end

  # ---------------------------------------------------------------------------
  # Exclusive scope (team/member-exclusive providers)
  # ---------------------------------------------------------------------------

  describe "exclusive scope" do
    test "a team-exclusive provider is never selected for a member of another team" do
      team_a = team_fixture(%{name: "Team A"})
      team_b = team_fixture(%{name: "Team B"})
      member_b = team_member_fixture(team_b)

      model_alias = model_alias_fixture(%{name: "gpt-4", display_name: "GPT-4"})
      {:ok, _} = Providers.grant_alias_to_team(team_a.id, model_alias.id)
      {:ok, _} = Providers.grant_alias_to_team(team_b.id, model_alias.id)

      # Global provider (fallback for everyone)
      global_provider = provider_fixture()
      global_cred = credential_fixture(global_provider, %{status: "active"})

      global_ap =
        model_provider_fixture(model_alias, global_provider, %{
          provider_model: "gpt-4-global",
          priority: 1,
          credential: global_cred
        })

      # Provider exclusive to Team A
      team_a_provider = provider_fixture()
      team_a_cred = credential_fixture(team_a_provider, %{status: "active"})

      model_provider_fixture(model_alias, team_a_provider, %{
        provider_model: "gpt-4-team-a",
        priority: 1,
        credential: team_a_cred,
        exclusive_to_team_id: team_a.id
      })

      member_b = Repo.preload(member_b, [:team])

      # Member B must silently skip Team A's exclusive and land on the global.
      assert {:ok, route} = Router.route(model_alias.name, member_b)
      assert route.model_provider.id == global_ap.id
      assert route.credential.id == global_cred.id
      assert route.model_responded == "gpt-4-global"
    end

    test "a team-exclusive provider is picked first (priority -1) for its own team" do
      team_a = team_fixture(%{name: "Team A"})
      member_a = team_member_fixture(team_a)

      model_alias = model_alias_fixture(%{name: "gpt-4", display_name: "GPT-4"})
      {:ok, _} = Providers.grant_alias_to_team(team_a.id, model_alias.id)

      # Global provider (would win by priority 1 without exclusive boost)
      global_provider = provider_fixture()
      global_cred = credential_fixture(global_provider, %{status: "active"})

      model_provider_fixture(model_alias, global_provider, %{
        provider_model: "gpt-4-global",
        priority: 1,
        credential: global_cred
      })

      # Provider exclusive to Team A
      team_a_provider = provider_fixture()
      team_a_cred = credential_fixture(team_a_provider, %{status: "active"})

      team_a_ap =
        model_provider_fixture(model_alias, team_a_provider, %{
          provider_model: "gpt-4-team-a",
          priority: 1,
          credential: team_a_cred,
          exclusive_to_team_id: team_a.id
        })

      member_a = Repo.preload(member_a, [:team])

      # Member A must use their team's exclusive provider first.
      assert {:ok, route} = Router.route(model_alias.name, member_a)
      assert route.model_provider.id == team_a_ap.id
      assert route.credential.id == team_a_cred.id
      assert route.model_responded == "gpt-4-team-a"
    end

    test "member-exclusive provider is picked for the owner but skipped for teammates" do
      team = team_fixture()
      owner = team_member_fixture(team)
      teammate = team_member_fixture(team)

      model_alias = model_alias_fixture(%{name: "gpt-4", display_name: "GPT-4"})
      {:ok, _} = Providers.grant_alias_to_team(team.id, model_alias.id)

      global_provider = provider_fixture()
      global_cred = credential_fixture(global_provider, %{status: "active"})

      global_ap =
        model_provider_fixture(model_alias, global_provider, %{
          provider_model: "gpt-4-global",
          priority: 1,
          credential: global_cred
        })

      member_provider = provider_fixture()
      member_cred = credential_fixture(member_provider, %{status: "active"})

      model_provider_fixture(model_alias, member_provider, %{
        provider_model: "gpt-4-owner",
        priority: 1,
        credential: member_cred,
        exclusive_to_team_member_id: owner.id
      })

      owner = Repo.preload(owner, [:team])
      teammate = Repo.preload(teammate, [:team])

      assert {:ok, owner_route} = Router.route(model_alias.name, owner)
      assert owner_route.model_responded == "gpt-4-owner"

      # Teammate silently skips the owner's exclusive and lands on the global.
      assert {:ok, mate_route} = Router.route(model_alias.name, teammate)
      assert mate_route.model_provider.id == global_ap.id
      assert mate_route.model_responded == "gpt-4-global"
    end
  end
end
