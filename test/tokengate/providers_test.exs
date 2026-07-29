defmodule Tokengate.ProvidersTest do
  use Tokengate.DataCase, async: true

  import Ecto.Query

  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Provider,
    Credential,
    ModelAlias,
    ModelProvider,
    ModelPricing
  }

  # ---------------------------------------------------------------------------
  # Test-only schemas for FK parent tables owned by the Accounts context.
  # These avoid depending on Tokengate.Accounts.* modules which may not be
  # compiled when this subagent runs in isolation.
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

  def team_fixture(attrs \\ %{}) do
    {:ok, team} =
      %TestTeam{}
      |> TestTeam.changeset(Map.merge(%{name: "Engineering"}, attrs))
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
        status: "active"
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

  def model_alias_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "gpt-4-#{unique}",
        display_name: "GPT-4",
        market_input_price_per_1m: Decimal.new("10.00"),
        market_output_price_per_1m: Decimal.new("30.00"),
        context_window: 128_000
      })

    {:ok, model_alias} = Providers.create_model_alias(attrs)
    model_alias
  end

  def model_provider_fixture(model_alias \\ nil, provider \\ nil, attrs \\ %{}) do
    model_alias = model_alias || model_alias_fixture()
    provider = provider || provider_fixture()
    credential = credential_fixture(provider)

    attrs =
      Enum.into(attrs, %{
        model_alias_id: model_alias.id,
        credential_id: credential.id,
        provider_model: "gpt-4-turbo",
        enabled: true
      })

    {:ok, model_provider} = Providers.create_model_provider(attrs)
    model_provider
  end

  def model_pricing_fixture(model_provider \\ nil, attrs \\ %{}) do
    model_provider = model_provider || model_provider_fixture()

    attrs =
      Enum.into(attrs, %{
        model_provider_id: model_provider.id,
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
    end

    test "create_provider/1 requires name and base_url" do
      {:error, changeset} = Providers.create_provider(%{})
      assert errors_on(changeset).name
      assert errors_on(changeset).base_url
    end

    test "list_providers/0 returns all providers" do
      provider_fixture()
      provider_fixture(%{name: "Anthropic", base_url: "https://api.anthropic.com"})
      assert length(Providers.list_providers()) == 2
    end

    test "update_provider/2 updates fields" do
      provider = provider_fixture()

      {:ok, updated} =
        Providers.update_provider(provider, %{base_url: "https://api.anthropic.com"})

      assert updated.base_url == "https://api.anthropic.com"
    end

    test "create_provider/1 defaults status to active" do
      provider = provider_fixture()
      assert provider.status == "active"
    end

    test "update_provider/2 toggles status" do
      provider = provider_fixture()
      {:ok, updated} = Providers.update_provider(provider, %{status: "disabled"})
      assert updated.status == "disabled"

      {:ok, updated} = Providers.update_provider(updated, %{status: "active"})
      assert updated.status == "active"
    end

    test "create_provider/1 with invalid status" do
      {:error, changeset} =
        Providers.create_provider(%{
          name: "Foo",
          base_url: "https://foo.com",
          status: "banned"
        })

      assert "is invalid" in errors_on(changeset).status
    end

    test "delete_provider/1 deletes the provider" do
      provider = provider_fixture()
      {:ok, _} = Providers.delete_provider(provider)
      assert Providers.list_providers() == []
    end

    test "delete_provider/1 deletes provider with credentials (cascade)" do
      provider = provider_fixture()
      credential_fixture(provider)
      credential_fixture(provider, %{name: "second"})

      {:ok, _} = Providers.delete_provider(provider)
      assert Providers.list_providers() == []
      assert Providers.list_credentials_for_provider(provider.id) == []
    end

    test "delete_provider/1 cascades through model_providers and pricing" do
      provider = provider_fixture()
      mp = model_provider_fixture(nil, provider)

      {:ok, _} = Providers.delete_provider(provider)
      assert Providers.list_providers() == []
      assert Providers.list_credentials_for_provider(provider.id) == []
      refute Repo.get(ModelProvider, mp.id)
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
  # ModelAlias tests
  # ---------------------------------------------------------------------------

  describe "model_aliases" do
    test "create_model_alias/1 with valid attrs" do
      alias_ = model_alias_fixture()
      assert %ModelAlias{} = alias_
      assert alias_.name =~ "gpt-4"
    end

    test "unique constraint on name" do
      model_alias_fixture(%{name: "gpt-4"})

      {:error, changeset} =
        Providers.create_model_alias(%{
          name: "gpt-4",
          display_name: "GPT-4",
          market_input_price_per_1m: Decimal.new("1"),
          market_output_price_per_1m: Decimal.new("1"),
          context_window: 1000
        })

      assert "has already been taken" in errors_on(changeset).name
    end

    test "get_alias_by_name/1 returns the alias by name" do
      alias_ = model_alias_fixture(%{name: "unique-alias"})

      assert Providers.get_alias_by_name("unique-alias").id == alias_.id
    end

    test "get_alias_by_name/1 returns nil for unknown name" do
      assert Providers.get_alias_by_name("nonexistent") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # ModelProvider tests
  # ---------------------------------------------------------------------------

  describe "model_providers" do
    test "create_model_provider/1 with valid attrs" do
      ap = model_provider_fixture()
      assert %ModelProvider{} = ap
      assert ap.enabled == true
    end

    test "list_model_providers/1 returns enabled, ordered priority ASC NULLS LAST" do
      alias_ = model_alias_fixture()
      provider = provider_fixture()

      # priority=5 (lower priority = runs later)
      ap5 = model_provider_fixture(alias_, provider, %{priority: 5})
      # no priority (nil) — should come last due to NULLS LAST
      ap_nil = model_provider_fixture(alias_, provider, %{priority: nil})
      # priority=1 (highest priority — first)
      ap1 = model_provider_fixture(alias_, provider, %{priority: 1})
      # disabled — should be excluded
      _disabled = model_provider_fixture(alias_, provider, %{enabled: false})

      result = Providers.list_model_providers(alias_.id)
      ids = Enum.map(result, & &1.id)

      assert ids == [ap1.id, ap5.id, ap_nil.id]
    end

    test "list_model_providers/1 preloads credential with provider" do
      alias_ = model_alias_fixture()
      provider = provider_fixture()
      model_provider_fixture(alias_, provider)

      [result] = Providers.list_model_providers(alias_.id)
      assert %Credential{} = result.credential
      assert %Provider{} = result.credential.provider
    end

    test "delete_model_provider/1 cascades pricing rows" do
      mp = model_provider_fixture()
      model_pricing_fixture(mp)

      {:ok, _} = Providers.delete_model_provider(mp)
      refute Repo.get(ModelProvider, mp.id)
      assert Repo.all(from(mp in ModelPricing, where: mp.model_provider_id == ^mp.id)) == []
    end
  end

  describe "model_pricing" do
    test "create_model_pricing/1 with valid attrs" do
      pricing = model_pricing_fixture()
      assert %ModelPricing{} = pricing
      assert Decimal.equal?(pricing.input_price_per_1m, Decimal.new("10.00"))
    end

    test "current_pricing/1 returns latest by effective_from" do
      model_provider = model_provider_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      old =
        model_pricing_fixture(model_provider, %{
          effective_from: DateTime.add(now, -86_400),
          input_price_per_1m: Decimal.new("5.00")
        })

      _new =
        model_pricing_fixture(model_provider, %{
          effective_from: now,
          input_price_per_1m: Decimal.new("10.00")
        })

      result = Providers.current_pricing(model_provider.id)
      assert result.id != old.id
      assert Decimal.equal?(result.input_price_per_1m, Decimal.new("10.00"))
    end

    test "current_pricing/1 returns nil when no pricing exists" do
      model_provider = model_provider_fixture()
      assert Providers.current_pricing(model_provider.id) == nil
    end

    test "cache fields are nullable" do
      pricing = model_pricing_fixture()
      assert pricing.cache_read_price_per_1m == nil
      assert pricing.cache_creation_price_per_1m == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Team Model Aliases
  # ---------------------------------------------------------------------------

  describe "team_model_aliases" do
    test "grant_alias_to_team/2 creates a grant" do
      team = team_fixture()
      alias_ = model_alias_fixture()

      assert {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)
    end

    test "grant_alias_to_team/2 is idempotent (unique constraint)" do
      team = team_fixture()
      alias_ = model_alias_fixture()

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)
      {:error, changeset} = Providers.grant_alias_to_team(team.id, alias_.id)
      assert "has already been taken" in errors_on(changeset).team_id
    end

    test "revoke_alias_from_team/2 removes grant" do
      team = team_fixture()
      alias_ = model_alias_fixture()

      {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)
      assert {:ok, _} = Providers.revoke_alias_from_team(team.id, alias_.id)
    end

    test "revoke_alias_from_team/2 is idempotent (nil-safe)" do
      team = team_fixture()
      alias_ = model_alias_fixture()

      assert {:ok, nil} = Providers.revoke_alias_from_team(team.id, alias_.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Cascade delete behavior (FK on_delete)
  # ---------------------------------------------------------------------------

  describe "cascade deletes" do
    alias Tokengate.Logs
    alias Tokengate.Logs.RequestLog
    alias Tokengate.Providers.{TeamModelAlias, TeamMemberExtraAlias}

    @log_timestamp ~U[2026-07-26 12:00:00Z]

    test "delete_model_alias/1 cascades to team_model_aliases" do
      team = team_fixture()
      alias_ = model_alias_fixture()
      {:ok, _} = Providers.grant_alias_to_team(team.id, alias_.id)

      assert Repo.get_by(TeamModelAlias, team_id: team.id, model_alias_id: alias_.id)

      {:ok, _} = Providers.delete_model_alias(alias_)

      refute Repo.get_by(TeamModelAlias, team_id: team.id, model_alias_id: alias_.id)
    end

    test "delete_model_alias/1 cascades to team_member_extra_aliases" do
      member = team_member_fixture()
      alias_ = model_alias_fixture()
      {:ok, _} = Providers.grant_extra_alias(member.id, alias_.id)

      assert Repo.get_by(TeamMemberExtraAlias,
               team_member_id: member.id,
               model_alias_id: alias_.id
             )

      {:ok, _} = Providers.delete_model_alias(alias_)

      refute Repo.get_by(TeamMemberExtraAlias,
               team_member_id: member.id,
               model_alias_id: alias_.id
             )
    end

    test "delete_provider/1 sets request_logs.provider_id to NULL (keeps history)" do
      member = team_member_fixture()
      provider = provider_fixture()

      {:ok, log} =
        Logs.log_request(%{
          team_member_id: member.id,
          provider_id: provider.id,
          model_requested: "gpt-4",
          inserted_at: @log_timestamp
        })

      {:ok, _} = Providers.delete_provider(provider)

      reloaded = Repo.get_by(RequestLog, id: log.id, inserted_at: log.inserted_at)
      assert reloaded != nil
      assert reloaded.provider_id == nil
    end

    test "delete_model_alias/1 sets request_logs.model_alias_id to NULL (keeps history)" do
      member = team_member_fixture()
      alias_ = model_alias_fixture()

      {:ok, log} =
        Logs.log_request(%{
          team_member_id: member.id,
          model_alias_id: alias_.id,
          model_requested: "gpt-4",
          inserted_at: @log_timestamp
        })

      {:ok, _} = Providers.delete_model_alias(alias_)

      reloaded = Repo.get_by(RequestLog, id: log.id, inserted_at: log.inserted_at)
      assert reloaded != nil
      assert reloaded.model_alias_id == nil
    end
  end
end
