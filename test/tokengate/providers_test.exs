defmodule Tokengate.ProvidersTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Provider,
    Credential,
    Subscription,
    ModelAlias,
    AliasProvider,
    ModelPricing,
    RoutingRule,
    TeamModelAlias,
    TeamMemberExtraAlias
  }

  # ---------------------------------------------------------------------------
  # Test-only schemas for FK parent tables owned by the Accounts context.
  # These avoid depending on Tokengate.Accounts.* modules which may not be
  # compiled when this subagent runs in isolation.
  # ---------------------------------------------------------------------------

  defmodule TestOrg do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "organizations" do
      field :name, :string
      field :slug, :string
      field :cost_tracking_mode, :string, default: "value"
      timestamps(type: :utc_datetime)
    end

    def changeset(org, attrs) do
      org
      |> cast(attrs, [:name, :slug, :cost_tracking_mode])
      |> validate_required([:name, :slug])
    end
  end

  defmodule TestTeam do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "teams" do
      field :name, :string
      field :default_daily_budget_usd, :decimal
      field :default_monthly_budget_usd, :decimal
      field :default_concurrency_limit, :integer, default: 5
      field :default_rpm_limit, :integer, default: 60
      belongs_to :organization, TestOrg
      timestamps(type: :utc_datetime)
    end

    def changeset(team, attrs) do
      team
      |> cast(attrs, [:name, :organization_id, :default_concurrency_limit, :default_rpm_limit])
      |> validate_required([:name, :organization_id])
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
      field :extra_daily_budget_usd, :decimal
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

  def org_fixture(attrs \\ %{}) do
    {:ok, org} =
      %TestOrg{}
      |> TestOrg.changeset(Map.merge(%{name: "Acme Corp", slug: "acme-corp"}, attrs))
      |> Repo.insert()

    org
  end

  def team_fixture(org \\ nil, attrs \\ %{}) do
    org = org || org_fixture()

    {:ok, team} =
      %TestTeam{}
      |> TestTeam.changeset(Map.merge(%{name: "Engineering", organization_id: org.id}, attrs))
      |> Repo.insert()

    team
  end

  def user_fixture(attrs \\ %{}) do
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

  def team_member_fixture(team \\ nil, attrs \\ %{}) do
    team = team || team_fixture()
    user = user_fixture()

    {:ok, member} =
      %TestTeamMember{}
      |> TestTeamMember.changeset(Map.merge(%{team_id: team.id, user_id: user.id}, attrs))
      |> Repo.insert()

    member
  end

  def provider_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "OpenAI",
        base_url: "https://api.openai.com",
        billing_type: "pay_per_token",
        track_real_usage: false
      })

    {:ok, provider} = Providers.create_provider(attrs)
    provider
  end

  def credential_fixture(provider \\ nil, attrs \\ %{})

  def credential_fixture(nil, attrs), do: credential_fixture(provider_fixture(), attrs)

  def credential_fixture(%Provider{} = provider, attrs) do
    attrs =
      Enum.into(attrs, %{
        provider_id: provider.id,
        api_key_encrypted: "sk-test123",
        status: "active"
      })

    {:ok, credential} = Providers.create_credential(attrs)
    credential
  end

  def subscription_fixture(provider \\ nil, attrs \\ %{}) do
    provider = provider || provider_fixture()

    attrs =
      Enum.into(attrs, %{
        provider_id: provider.id,
        name: "Standard Plan",
        cost: Decimal.new("100.00"),
        billing_cycle: "monthly",
        start_date: ~D[2026-01-01],
        status: "active"
      })

    {:ok, subscription} = Providers.create_subscription(attrs)
    subscription
  end

  def model_alias_fixture(org \\ nil, attrs \\ %{}) do
    org = org || org_fixture()

    attrs =
      Enum.into(attrs, %{
        organization_id: org.id,
        name: "gpt-4",
        display_name: "GPT-4",
        market_input_price_per_1m: Decimal.new("10.00"),
        market_output_price_per_1m: Decimal.new("30.00"),
        context_window: 128_000,
        routing_strategy: "priority"
      })

    {:ok, model_alias} = Providers.create_model_alias(attrs)
    model_alias
  end

  def alias_provider_fixture(model_alias \\ nil, provider \\ nil, attrs \\ %{}) do
    model_alias = model_alias || model_alias_fixture()
    provider = provider || provider_fixture()

    attrs =
      Enum.into(attrs, %{
        model_alias_id: model_alias.id,
        provider_id: provider.id,
        provider_model: "gpt-4-turbo",
        enabled: true
      })

    {:ok, alias_provider} = Providers.create_alias_provider(attrs)
    alias_provider
  end

  def model_pricing_fixture(alias_provider \\ nil, attrs \\ %{}) do
    alias_provider = alias_provider || alias_provider_fixture()

    attrs =
      Enum.into(attrs, %{
        alias_provider_id: alias_provider.id,
        input_price_per_1m: Decimal.new("10.00"),
        output_price_per_1m: Decimal.new("30.00"),
        effective_from: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, pricing} = Providers.create_model_pricing(attrs)
    pricing
  end

  # ---------------------------------------------------------------------------
  # Provider tests
  # ---------------------------------------------------------------------------

  describe "providers" do
    test "create_provider/1 with valid attrs" do
      provider = provider_fixture()
      assert %Provider{} = provider
      assert provider.name == "OpenAI"
      assert provider.billing_type == "pay_per_token"
      assert provider.track_real_usage == false
    end

    test "create_provider/1 with invalid billing_type" do
      {:error, changeset} =
        Providers.create_provider(%{
          name: "Foo",
          base_url: "https://foo.com",
          billing_type: "invalid"
        })

      assert "is invalid" in errors_on(changeset).billing_type
    end

    test "create_provider/1 requires name and base_url" do
      {:error, changeset} = Providers.create_provider(%{})
      assert errors_on(changeset).name
      assert errors_on(changeset).base_url
      assert errors_on(changeset).billing_type
    end

    test "list_providers/0 returns all providers" do
      provider_fixture()
      provider_fixture(%{name: "Anthropic", base_url: "https://api.anthropic.com"})
      assert length(Providers.list_providers()) == 2
    end

    test "update_provider/2 updates fields" do
      provider = provider_fixture()
      {:ok, updated} = Providers.update_provider(provider, %{track_real_usage: true})
      assert updated.track_real_usage == true
    end

    test "delete_provider/1 deletes the provider" do
      provider = provider_fixture()
      {:ok, _} = Providers.delete_provider(provider)
      assert Providers.list_providers() == []
    end
  end

  # ---------------------------------------------------------------------------
  # Credential tests
  # ---------------------------------------------------------------------------

  describe "credentials" do
    test "create_credential/1 with valid attrs" do
      credential = credential_fixture()
      assert %Credential{} = credential
      assert credential.status == "active"
      assert credential.max_rpm == nil
    end

    test "create_credential/1 with invalid status" do
      {:error, changeset} =
        Providers.create_credential(%{
          provider_id: provider_fixture().id,
          api_key_encrypted: "sk-123",
          status: "banned"
        })

      assert "is invalid" in errors_on(changeset).status
    end

    test "create_credential/1 with max_rpm and max_concurrent" do
      credential = credential_fixture(nil, %{max_rpm: 500, max_concurrent: 10})
      assert credential.max_rpm == 500
      assert credential.max_concurrent == 10
    end
  end

  # ---------------------------------------------------------------------------
  # Subscription tests
  # ---------------------------------------------------------------------------

  describe "subscriptions" do
    test "create_subscription/1 with valid attrs" do
      subscription = subscription_fixture()
      assert %Subscription{} = subscription
      assert subscription.billing_cycle == "monthly"
      assert subscription.status == "active"
    end

    test "create_subscription/1 with invalid billing_cycle" do
      {:error, changeset} =
        Providers.create_subscription(%{
          provider_id: provider_fixture().id,
          name: "X",
          cost: Decimal.new("50"),
          billing_cycle: "weekly",
          start_date: ~D[2026-01-01],
          status: "active"
        })

      assert "is invalid" in errors_on(changeset).billing_cycle
    end

    test "create_subscription/1 with invalid status" do
      {:error, changeset} =
        Providers.create_subscription(%{
          provider_id: provider_fixture().id,
          name: "X",
          cost: Decimal.new("50"),
          billing_cycle: "monthly",
          start_date: ~D[2026-01-01],
          status: "pending"
        })

      assert "is invalid" in errors_on(changeset).status
    end

    test "active_subscriptions/1 includes active with nil end_date" do
      provider = provider_fixture()
      sub = subscription_fixture(provider, %{end_date: nil})
      active = Providers.active_subscriptions(provider.id)
      assert length(active) == 1
      assert hd(active).id == sub.id
    end

    test "active_subscriptions/1 includes active with future end_date" do
      provider = provider_fixture()

      sub =
        subscription_fixture(provider, %{
          end_date: Date.add(Date.utc_today(), 30)
        })

      active = Providers.active_subscriptions(provider.id)
      assert length(active) == 1
      assert hd(active).id == sub.id
    end

    test "active_subscriptions/1 excludes past end_date" do
      provider = provider_fixture()

      subscription_fixture(provider, %{
        end_date: Date.add(Date.utc_today(), -1)
      })

      active = Providers.active_subscriptions(provider.id)
      assert active == []
    end

    test "active_subscriptions/1 excludes cancelled/exhausted" do
      provider = provider_fixture()

      subscription_fixture(provider, %{status: "cancelled"})
      subscription_fixture(provider, %{status: "exhausted"})

      assert Providers.active_subscriptions(provider.id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # ModelAlias tests
  # ---------------------------------------------------------------------------

  describe "model_aliases" do
    test "create_model_alias/1 with valid attrs" do
      alias_ = model_alias_fixture()
      assert %ModelAlias{} = alias_
      assert alias_.routing_strategy == "priority"
    end

    test "create_model_alias/1 with invalid routing_strategy" do
      {:error, changeset} =
        Providers.create_model_alias(%{
          organization_id: org_fixture().id,
          name: "x",
          display_name: "X",
          market_input_price_per_1m: Decimal.new("1"),
          market_output_price_per_1m: Decimal.new("1"),
          context_window: 1000,
          routing_strategy: "random"
        })

      assert "is invalid" in errors_on(changeset).routing_strategy
    end

    test "unique constraint on organization_id + name" do
      org = org_fixture()
      model_alias_fixture(org)

      {:error, changeset} =
        Providers.create_model_alias(%{
          organization_id: org.id,
          name: "gpt-4",
          display_name: "GPT-4",
          market_input_price_per_1m: Decimal.new("1"),
          market_output_price_per_1m: Decimal.new("1"),
          context_window: 1000,
          routing_strategy: "priority"
        })

      assert "has already been taken" in errors_on(changeset).name
    end

    test "different orgs can have same alias name" do
      org1 = org_fixture()
      org2 = org_fixture(%{name: "Other", slug: "other"})
      model_alias_fixture(org1)

      {:ok, alias2} =
        Providers.create_model_alias(%{
          organization_id: org2.id,
          name: "gpt-4",
          display_name: "GPT-4",
          market_input_price_per_1m: Decimal.new("1"),
          market_output_price_per_1m: Decimal.new("1"),
          context_window: 1000,
          routing_strategy: "priority"
        })

      assert alias2.name == "gpt-4"
    end
  end

  # ---------------------------------------------------------------------------
  # AliasProvider tests
  # ---------------------------------------------------------------------------

  describe "alias_providers" do
    test "create_alias_provider/1 with valid attrs" do
      ap = alias_provider_fixture()
      assert %AliasProvider{} = ap
      assert ap.enabled == true
    end

    test "list_alias_providers/1 returns enabled, ordered priority ASC NULLS LAST" do
      alias_ = model_alias_fixture()
      provider = provider_fixture()

      # priority=5 (lower priority = runs later)
      ap5 = alias_provider_fixture(alias_, provider, %{priority: 5})
      # no priority (nil) — should come last due to NULLS LAST
      ap_nil = alias_provider_fixture(alias_, provider, %{priority: nil})
      # priority=1 (highest priority — first)
      ap1 = alias_provider_fixture(alias_, provider, %{priority: 1})
      # disabled — should be excluded
      _disabled = alias_provider_fixture(alias_, provider, %{enabled: false})

      result = Providers.list_alias_providers(alias_.id)
      ids = Enum.map(result, & &1.id)

      assert ids == [ap1.id, ap5.id, ap_nil.id]
    end

    test "list_alias_providers/1 preloads provider and subscription" do
      alias_ = model_alias_fixture()
      provider = provider_fixture()
      sub = subscription_fixture(provider)
      alias_provider_fixture(alias_, provider, %{subscription_id: sub.id})

      [result] = Providers.list_alias_providers(alias_.id)
      assert %Provider{} = result.provider
      assert %Subscription{} = result.subscription
    end
  end

  # ---------------------------------------------------------------------------
  # ModelPricing tests
  # ---------------------------------------------------------------------------

  describe "model_pricing" do
    test "create_model_pricing/1 with valid attrs" do
      pricing = model_pricing_fixture()
      assert %ModelPricing{} = pricing
      assert Decimal.equal?(pricing.input_price_per_1m, Decimal.new("10.00"))
    end

    test "current_pricing/1 returns latest by effective_from" do
      alias_provider = alias_provider_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      old =
        model_pricing_fixture(alias_provider, %{
          effective_from: DateTime.add(now, -86_400),
          input_price_per_1m: Decimal.new("5.00")
        })

      _new =
        model_pricing_fixture(alias_provider, %{
          effective_from: now,
          input_price_per_1m: Decimal.new("10.00")
        })

      result = Providers.current_pricing(alias_provider.id)
      assert result.id != old.id
      assert Decimal.equal?(result.input_price_per_1m, Decimal.new("10.00"))
    end

    test "current_pricing/1 returns nil when no pricing exists" do
      alias_provider = alias_provider_fixture()
      assert Providers.current_pricing(alias_provider.id) == nil
    end

    test "cache fields are nullable" do
      pricing = model_pricing_fixture()
      assert pricing.cache_read_price_per_1m == nil
      assert pricing.cache_creation_price_per_1m == nil
    end
  end

  # ---------------------------------------------------------------------------
  # RoutingRule tests
  # ---------------------------------------------------------------------------

  describe "routing_rules" do
    test "create_routing_rule/1 with valid attrs" do
      org = org_fixture()
      alias_ = model_alias_fixture(org)

      {:ok, rule} =
        Providers.create_routing_rule(%{
          organization_id: org.id,
          name: "Long context rule",
          conditions: %{"context_length" => "> 100000", "has_images" => true},
          target_alias_id: alias_.id,
          priority: 1,
          enabled: true
        })

      assert %RoutingRule{} = rule
      assert rule.conditions["context_length"] == "> 100000"
      assert rule.conditions["has_images"] == true
    end

    test "create_routing_rule/1 with default priority and enabled" do
      org = org_fixture()
      alias_ = model_alias_fixture(org)

      {:ok, rule} =
        Providers.create_routing_rule(%{
          organization_id: org.id,
          name: "Default rule",
          conditions: %{},
          target_alias_id: alias_.id
        })

      assert rule.priority == 1
      assert rule.enabled == true
    end

    test "list_routing_rules_for_organization/1 filters by org" do
      org1 = org_fixture()
      org2 = org_fixture(%{name: "Other", slug: "other"})
      alias1 = model_alias_fixture(org1)
      alias2 = model_alias_fixture(org2, %{name: "claude"})

      {:ok, _} =
        Providers.create_routing_rule(%{
          organization_id: org1.id,
          name: "r1",
          conditions: %{},
          target_alias_id: alias1.id
        })

      {:ok, _} =
        Providers.create_routing_rule(%{
          organization_id: org2.id,
          name: "r2",
          conditions: %{},
          target_alias_id: alias2.id
        })

      assert length(Providers.list_routing_rules_for_organization(org1.id)) == 1
      assert length(Providers.list_routing_rules_for_organization(org2.id)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # TeamModelAlias grant/revoke tests
  # ---------------------------------------------------------------------------

  describe "team_model_aliases" do
    test "grant_alias_to_team/2 creates grant" do
      org = org_fixture()
      team = team_fixture(org)
      alias_ = model_alias_fixture(org)

      {:ok, tma} = Providers.grant_alias_to_team(team.id, alias_.id)
      assert %TeamModelAlias{} = tma
      assert tma.team_id == team.id
      assert tma.model_alias_id == alias_.id
    end

    test "grant_alias_to_team/2 idempotent returns {:error, :already_granted}" do
      org = org_fixture()
      team = team_fixture(org)
      alias_ = model_alias_fixture(org)

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)
      {:error, :already_granted} = Providers.grant_alias_to_team(team.id, alias_.id)
    end

    test "revoke_alias_from_team/2 removes grant" do
      org = org_fixture()
      team = team_fixture(org)
      alias_ = model_alias_fixture(org)

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)
      {:ok, _} = Providers.revoke_alias_from_team(team.id, alias_.id)

      assert Providers.list_team_model_aliases() == []
    end

    test "revoke_alias_from_team/2 returns {:error, :not_found} when not granted" do
      org = org_fixture()
      team = team_fixture(org)
      alias_ = model_alias_fixture(org)

      {:error, :not_found} = Providers.revoke_alias_from_team(team.id, alias_.id)
    end

    test "unique constraint on team_id + model_alias_id" do
      org = org_fixture()
      team = team_fixture(org)
      alias_ = model_alias_fixture(org)

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)

      {:error, changeset} =
        %TeamModelAlias{}
        |> TeamModelAlias.changeset(%{team_id: team.id, model_alias_id: alias_.id})
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).team_id
    end
  end

  # ---------------------------------------------------------------------------
  # TeamMemberExtraAlias grant/revoke tests
  # ---------------------------------------------------------------------------

  describe "team_member_extra_aliases" do
    test "grant_extra_alias/2 creates grant" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias_ = model_alias_fixture(org)

      {:ok, tmea} = Providers.grant_extra_alias(member.id, alias_.id)
      assert %TeamMemberExtraAlias{} = tmea
    end

    test "grant_extra_alias/2 idempotent returns {:error, :already_granted}" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias_ = model_alias_fixture(org)

      {:ok, _} = Providers.grant_extra_alias(member.id, alias_.id)
      {:error, :already_granted} = Providers.grant_extra_alias(member.id, alias_.id)
    end

    test "revoke_extra_alias/2 removes grant" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias_ = model_alias_fixture(org)

      {:ok, _} = Providers.grant_extra_alias(member.id, alias_.id)
      {:ok, _} = Providers.revoke_extra_alias(member.id, alias_.id)
      assert Providers.list_team_member_extra_aliases() == []
    end

    test "revoke_extra_alias/2 returns {:error, :not_found} when not granted" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias_ = model_alias_fixture(org)

      {:error, :not_found} = Providers.revoke_extra_alias(member.id, alias_.id)
    end

    test "unique constraint on team_member_id + model_alias_id" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias_ = model_alias_fixture(org)

      {:ok, _} = Providers.grant_extra_alias(member.id, alias_.id)

      {:error, changeset} =
        %TeamMemberExtraAlias{}
        |> TeamMemberExtraAlias.changeset(%{
          team_member_id: member.id,
          model_alias_id: alias_.id
        })
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).team_member_id
    end
  end

  # ---------------------------------------------------------------------------
  # list_accessible_aliases/1 tests
  # ---------------------------------------------------------------------------

  describe "list_accessible_aliases/1" do
    test "returns team aliases" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias1 = model_alias_fixture(org)
      alias2 = model_alias_fixture(org, %{name: "claude-3", display_name: "Claude 3"})

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias1.id)
      {:ok, _} = Providers.grant_alias_to_team(team.id, alias2.id)

      # Reload member with team preloaded
      member = Repo.preload(member, :team)

      accessible = Providers.list_accessible_aliases(member)
      ids = Enum.map(accessible, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([alias1.id, alias2.id])
    end

    test "returns extra aliases only granted to member" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias1 = model_alias_fixture(org)
      alias2 = model_alias_fixture(org, %{name: "claude-3", display_name: "Claude 3"})

      # Only alias1 granted to team
      {:ok, _} = Providers.grant_alias_to_team(team.id, alias1.id)
      # alias2 granted as extra to member
      {:ok, _} = Providers.grant_extra_alias(member.id, alias2.id)

      member = Repo.preload(member, :team)

      accessible = Providers.list_accessible_aliases(member)
      ids = Enum.map(accessible, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([alias1.id, alias2.id])
    end

    test "union is distinct — no duplicates when alias granted both ways" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)
      alias1 = model_alias_fixture(org)

      # Granted to team AND as extra to member — should appear once
      {:ok, _} = Providers.grant_alias_to_team(team.id, alias1.id)
      {:ok, _} = Providers.grant_extra_alias(member.id, alias1.id)

      member = Repo.preload(member, :team)

      accessible = Providers.list_accessible_aliases(member)
      assert length(accessible) == 1
      assert hd(accessible).id == alias1.id
    end

    test "returns empty list when member has no grants" do
      org = org_fixture()
      team = team_fixture(org)
      member = team_member_fixture(team)

      member = Repo.preload(member, :team)

      assert Providers.list_accessible_aliases(member) == []
    end
  end
end
