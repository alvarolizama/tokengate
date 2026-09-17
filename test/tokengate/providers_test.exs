defmodule Tokengate.ProvidersTest do
  use Tokengate.DataCase, async: true
  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Provider,
    Credential,
    Model,
    ModelProvider,
    ProviderLimits
  }

  # ---------------------------------------------------------------------------
  # Test-only schemas for FK parent tables owned by the Accounts context.
  # These avoid depending on Tokengate.Accounts.* modules which may not be
  # compiled when this subagent runs in isolation.
  # ---------------------------------------------------------------------------

  defmodule TestGroup do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "groups" do
      field :name, :string
      field :default_concurrency_limit, :integer, default: 5
      field :default_rpm_limit, :integer, default: 60
      timestamps(type: :utc_datetime)
    end

    def changeset(group, attrs) do
      group
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

  defmodule TestGroupMember do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "group_members" do
      field :extra_concurrency, :integer
      field :status, :string, default: "active"
      belongs_to :group, TestGroup
      belongs_to :user, TestUser
      timestamps(type: :utc_datetime)
    end

    def changeset(member, attrs) do
      member
      |> cast(attrs, [:group_id, :user_id, :status])
      |> validate_required([:group_id, :user_id])
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  def group_fixture(attrs \\ %{}) do
    {:ok, group} =
      %TestGroup{}
      |> TestGroup.changeset(Map.merge(%{name: "Engineering"}, attrs))
      |> Repo.insert()

    group
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

  def group_member_fixture(group \\ nil, attrs \\ %{}) do
    group = group || group_fixture()
    user = user_fixture()

    {:ok, member} =
      %TestGroupMember{}
      |> TestGroupMember.changeset(Map.merge(%{group_id: group.id, user_id: user.id}, attrs))
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

  def model_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "gpt-4-#{unique}",
        context_window: 128_000
      })

    {:ok, model} = Providers.create_model(attrs)
    model
  end

  def model_provider_fixture(model \\ nil, provider \\ nil, attrs \\ %{}) do
    model = model || model_fixture()
    provider = provider || provider_fixture()
    credential = credential_fixture(provider)

    attrs =
      Enum.into(attrs, %{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "gpt-4-turbo",
        enabled: true
      })

    {:ok, model_provider} = Providers.create_model_provider(attrs)
    model_provider
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
      p1 = provider_fixture()
      p2 = provider_fixture(%{name: "Anthropic", base_url: "https://api.anthropic.com"})
      all = Providers.list_providers()
      # Our fixtures must appear in the result (concurrent tests may add more)
      assert Enum.any?(all, &(&1.id == p1.id))
      assert Enum.any?(all, &(&1.id == p2.id))
      assert length(all) >= 2
    end

    test "update_provider/2 updates fields" do
      provider = provider_fixture()

      {:ok, updated} =
        Providers.update_provider(provider, %{base_url: "https://api.anthropic.com"})

      assert updated.base_url == "https://api.anthropic.com"
    end

    test "the operational limits live on the provider" do
      provider = provider_fixture()

      {:ok, updated} =
        Providers.update_provider(provider, %{
          max_rpm: 500,
          max_concurrent: 10,
          max_concurrent_per_user: 3,
          receive_timeout_ms: 90_000
        })

      assert updated.max_rpm == 500
      assert updated.max_concurrent == 10
      assert updated.max_concurrent_per_user == 3
      assert updated.receive_timeout_ms == 90_000
    end

    test "a blank limit means 'no limit' (nil), never 0" do
      provider = provider_fixture()
      {:ok, with_limits} = Providers.update_provider(provider, %{max_rpm: 500})

      # Blanking the field clears the limit: Ecto casts "" to nil and
      # `validate_number` skips nil, so "no limit" is expressed as nil.
      {:ok, cleared} = Providers.update_provider(with_limits, %{max_rpm: ""})

      assert cleared.max_rpm == nil
    end

    test "a 0 limit is rejected: it would block every request" do
      provider = provider_fixture()

      {:error, changeset} =
        Providers.update_provider(provider, %{max_rpm: 0, max_concurrent: 0})

      assert "debe ser mayor a 0" in errors_on(changeset).max_rpm
      assert "debe ser mayor a 0" in errors_on(changeset).max_concurrent
    end

    test "a builtin keeps its catalog identity while its limits stay editable" do
      unique = System.unique_integer([:positive])

      # Builtins are materialized by CatalogSync with a raw change — the
      # operator changeset intentionally locks identity, so it cannot create
      # one (there is nothing to lock yet).
      {:ok, provider} =
        %Provider{}
        |> Ecto.Changeset.change(
          name: "Catalog Prov #{unique}",
          base_url: "https://catalog-#{unique}.example.com/v1",
          source: "builtin",
          key: "catalog-prov-#{unique}",
          dialect: "openai",
          capabilities: ["llm"],
          status: "active"
        )
        |> Tokengate.Repo.insert()

      {:ok, updated} =
        Providers.update_provider(provider, %{
          name: "Renamed",
          base_url: "https://evil.example.com",
          max_rpm: 42
        })

      # Identity is catalog-owned (boot sync would overwrite it anyway)...
      assert updated.name == provider.name
      assert updated.base_url == provider.base_url
      # ...but the throttle belongs to the operator.
      assert updated.max_rpm == 42
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
      # Verify OUR provider is gone (other tests may have providers)
      refute Enum.any?(Providers.list_providers(), &(&1.id == provider.id))
    end

    test "delete_provider/1 deletes provider with credentials (cascade)" do
      provider = provider_fixture()
      credential_fixture(provider)
      credential_fixture(provider, %{name: "second"})

      {:ok, _} = Providers.delete_provider(provider)
      refute Enum.any?(Providers.list_providers(), &(&1.id == provider.id))
      assert Providers.list_credentials_for_provider(provider.id) == []
    end

    test "delete_provider/1 cascades through model_providers and pricing" do
      provider = provider_fixture()
      mp = model_provider_fixture(nil, provider)

      {:ok, _} = Providers.delete_provider(provider)
      refute Enum.any?(Providers.list_providers(), &(&1.id == provider.id))
      assert Providers.list_credentials_for_provider(provider.id) == []
      refute Repo.get(ModelProvider, mp.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Provider limits
  # ---------------------------------------------------------------------------

  describe "provider limits" do
    test "the receive timeout is the provider's, falling back to the global default" do
      provider = provider_fixture()
      credential_fixture(provider)

      # NULL on the provider = whatever the global config says (120s shipped).
      assert ProviderLimits.receive_timeout_ms(provider) ==
               Application.get_env(:tokengate, :proxy, [])[:receive_timeout_ms]

      {:ok, with_timeout} = Providers.update_provider(provider, %{receive_timeout_ms: 45_000})
      assert ProviderLimits.receive_timeout_ms(with_timeout) == 45_000
    end

    test "the shipped global default is 120s" do
      assert Application.get_env(:tokengate, :proxy, [])[:receive_timeout_ms] == 120_000
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

    test "a credential carries no limits of its own — it inherits the provider's" do
      provider = provider_fixture()

      {:ok, _provider} =
        Providers.update_provider(provider, %{max_rpm: 500, max_concurrent: 10})

      credential = credential_fixture(provider, %{max_rpm: 500, max_concurrent: 10})

      # Per-key limit attrs are not part of the credential schema anymore: the
      # proxy reads them from `credential.provider`, so every key of a provider
      # shares one throttle.
      refute Map.has_key?(credential, :max_rpm)
      refute Map.has_key?(credential, :max_concurrent)

      loaded = credential.id |> Providers.get_credential!() |> Tokengate.Repo.preload(:provider)
      assert loaded.provider.max_rpm == 500
      assert loaded.provider.max_concurrent == 10
    end
  end

  # ---------------------------------------------------------------------------
  # Model tests
  # ---------------------------------------------------------------------------

  describe "models" do
    test "create_model/1 with valid attrs" do
      model_ = model_fixture()
      assert %Model{} = model_
      assert model_.name =~ "gpt-4"
    end

    test "unique constraint on name" do
      model_fixture(%{name: "gpt-4"})

      {:error, changeset} =
        Providers.create_model(%{
          name: "gpt-4",
          context_window: 1000
        })

      assert "has already been taken" in errors_on(changeset).name
    end

    test "get_model_by_name/1 returns the model by name" do
      model_ = model_fixture(%{name: "unique-model"})

      assert Providers.get_model_by_name("unique-model").id == model_.id
    end

    test "get_model_by_name/1 returns nil for unknown name" do
      assert Providers.get_model_by_name("nonexistent") == nil
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
      model_ = model_fixture()
      provider = provider_fixture()

      # priority=5 (lower priority = runs later)
      ap5 = model_provider_fixture(model_, provider, %{priority: 5})
      # no priority (nil) — should come last due to NULLS LAST
      ap_nil = model_provider_fixture(model_, provider, %{priority: nil})
      # priority=1 (highest priority — first)
      ap1 = model_provider_fixture(model_, provider, %{priority: 1})
      # disabled — should be excluded
      _disabled = model_provider_fixture(model_, provider, %{enabled: false})

      result = Providers.list_model_providers(model_.id)
      ids = Enum.map(result, & &1.id)

      assert ids == [ap1.id, ap5.id, ap_nil.id]
    end

    test "list_model_providers/1 preloads credential with provider" do
      model_ = model_fixture()
      provider = provider_fixture()
      model_provider_fixture(model_, provider)

      [result] = Providers.list_model_providers(model_.id)
      assert %Credential{} = result.credential
      assert %Provider{} = result.credential.provider
    end

    test "list_model_providers/1 breaks priority ties by credential_id (stable order)" do
      model_ = model_fixture()
      provider = provider_fixture()

      # Two providers sharing priority 2: the order must be deterministic
      # (by credential_id) so sticky routing doesn't flip between cache
      # refreshes. Insert in reverse to prove it isn't insertion order.
      ap_later = model_provider_fixture(model_, provider, %{priority: 2})
      ap_earlier = model_provider_fixture(model_, provider, %{priority: 2})

      result = Providers.list_model_providers(model_.id)

      assert [first, second | _] = result

      if first.id == ap_earlier.id do
        assert second.id == ap_later.id
      else
        assert first.id == ap_later.id and second.id == ap_earlier.id
      end

      # The invariant that matters: same query, same order, every time.
      assert Enum.map(result, & &1.id) ==
               Enum.map(Providers.list_model_providers(model_.id), & &1.id)
    end

    test "model_provider changeset rejects negative priority" do
      model_ = model_fixture()
      provider = provider_fixture()

      # -1 is reserved at runtime for exclusive providers; a configured
      # negative priority on a global row would outrank an exclusive one.
      assert {:error, changeset} =
               Providers.create_model_provider(%{
                 model_id: model_.id,
                 credential_id: credential_fixture(provider).id,
                 provider_model: "neg-priority",
                 priority: -1
               })

      assert %{priority: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end

    test "delete_model_provider/1 removes the row" do
      mp = model_provider_fixture()

      {:ok, _} = Providers.delete_model_provider(mp)
      refute Repo.get(ModelProvider, mp.id)
    end

    test "default request overrides are no-ops" do
      mp = model_provider_fixture()

      assert mp.extra_body == %{}
      assert mp.omit_body_fields == []
      assert mp.omit_headers == []
    end

    test "extra_body_json parses valid JSON into extra_body" do
      mp = model_provider_fixture()

      {:ok, mp} =
        Providers.update_model_provider(mp, %{extra_body_json: ~s({"service_tier": "priority"})})

      assert mp.extra_body == %{"service_tier" => "priority"}
    end

    test "extra_body_json with a non-object JSON value is rejected" do
      mp = model_provider_fixture()

      {:error, changeset} = Providers.update_model_provider(mp, %{extra_body_json: "[1,2]"})

      assert %{extra_body_json: ["JSON inválido: se esperaba un objeto"]} = errors_on(changeset)
    end

    test "protected gateway keys are rejected inside extra_body" do
      mp = model_provider_fixture()

      {:error, changeset} =
        Providers.update_model_provider(mp, %{extra_body_json: ~s({"stream_options": {"x": 1}})})

      assert %{extra_body_json: ["no se puede sobrescribir \"stream_options\""]} =
               errors_on(changeset)
    end

    test "omit lists normalize: trim, dedupe, drop blanks" do
      mp = model_provider_fixture()

      {:ok, mp} =
        Providers.update_model_provider(mp, %{
          omit_body_fields_csv: " session_id ,,, Session_ID ",
          omit_headers_csv: "X-SESSION-ID,, idempotency-key "
        })

      assert mp.omit_body_fields == ["session_id", "Session_ID"]
      assert mp.omit_headers == ["x-session-id", "idempotency-key"]
    end

    test "protected keys are rejected in omit_body_fields_csv" do
      mp = model_provider_fixture()

      {:error, changeset} =
        Providers.update_model_provider(mp, %{omit_body_fields_csv: "model, session_id"})

      assert %{omit_body_fields_csv: ["no se puede omitir \"model\""]} = errors_on(changeset)
    end

    test "authorization cannot be omitted" do
      mp = model_provider_fixture()

      {:error, changeset} =
        Providers.update_model_provider(mp, %{omit_headers_csv: "authorization"})

      assert %{omit_headers_csv: ["no se puede omitir \"authorization\""]} = errors_on(changeset)
    end

    test "service_tier_priority checkbox sets extra_body[service_tier]" do
      mp = model_provider_fixture()

      {:ok, mp} = Providers.update_model_provider(mp, %{service_tier_priority: true})

      assert mp.extra_body == %{"service_tier" => "priority"}
    end

    test "unchecking drops the key but keeps other extra_body entries" do
      mp =
        model_provider_fixture(nil, nil, %{
          extra_body: %{"service_tier" => "priority", "top_k" => 7}
        })

      {:ok, mp} = Providers.update_model_provider(mp, %{service_tier_priority: false})

      assert mp.extra_body == %{"top_k" => 7}
    end

    test "a programmatic update without the checkbox param leaves extra_body untouched" do
      mp = model_provider_fixture(nil, nil, %{extra_body: %{"service_tier" => "priority"}})

      {:ok, mp} = Providers.update_model_provider(mp, %{priority: 5})

      assert mp.extra_body == %{"service_tier" => "priority"}
      assert mp.priority == 5
    end

    test "clearing the form fields resets overrides to defaults" do
      mp =
        model_provider_fixture(nil, nil, %{
          omit_body_fields: ["session_id"],
          omit_headers: ["user-agent"]
        })

      {:ok, mp} =
        Providers.update_model_provider(mp, %{omit_body_fields_csv: "", omit_headers_csv: ""})

      assert mp.omit_body_fields == []
      assert mp.omit_headers == []
    end
  end

  describe "model_providers exclusive scope" do
    test "group-exclusive provider is visible only to members of that group" do
      group_a = group_fixture(%{name: "Group A"})
      group_b = group_fixture(%{name: "Group B"})
      member_a = group_member_fixture(group_a)
      member_b = group_member_fixture(group_b)

      model_ = model_fixture()
      provider = provider_fixture()
      credential = credential_fixture(provider)

      {:ok, mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential.id,
          provider_model: "exclusive-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_a.id
        })

      # Same group → visible
      visible_for_a =
        Providers.list_model_providers_for_member(model_.id, member_a.id, group_a.id)

      assert Enum.map(visible_for_a, & &1.id) == [mp.id]

      # Other group → NOT visible. Regression: the "global" clause used to
      # check only exclusive_to_group_member_id, so group-exclusive providers
      # (member id nil) leaked to every other group.
      visible_for_b =
        Providers.list_model_providers_for_member(model_.id, member_b.id, group_b.id)

      assert visible_for_b == []
    end

    test "member-exclusive provider is visible only to that member" do
      group = group_fixture()
      member_a = group_member_fixture(group)
      member_b = group_member_fixture(group)

      model_ = model_fixture()
      provider = provider_fixture()
      credential = credential_fixture(provider)

      {:ok, mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential.id,
          provider_model: "member-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_member_id: member_a.id
        })

      visible_for_a = Providers.list_model_providers_for_member(model_.id, member_a.id, group.id)
      assert Enum.map(visible_for_a, & &1.id) == [mp.id]

      visible_for_b = Providers.list_model_providers_for_member(model_.id, member_b.id, group.id)
      assert visible_for_b == []
    end

    test "global providers stay visible alongside matching exclusives" do
      group = group_fixture()
      member = group_member_fixture(group)
      model_ = model_fixture()
      provider = provider_fixture()
      global_cred = credential_fixture(provider)
      group_cred = credential_fixture(provider)

      {:ok, global_mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: global_cred.id,
          provider_model: "global-model",
          priority: 1,
          enabled: true
        })

      {:ok, group_mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: group_cred.id,
          provider_model: "group-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      visible = Providers.list_model_providers_for_member(model_.id, member.id, group.id)
      ids = Enum.map(visible, & &1.id)

      assert global_mp.id in ids
      assert group_mp.id in ids
    end

    @tag :hermes_verify
    test "same credential can serve multiple scope buckets for the same model" do
      model_ = model_fixture(%{name: "verify-cross-scope"})
      group_a = group_fixture(%{name: "Group A"})
      group_b = group_fixture(%{name: "Group B"})
      member_a = group_member_fixture(group_a)
      member_b = group_member_fixture(group_b)
      provider = provider_fixture()
      cred = credential_fixture(provider, %{status: "active"})

      # Global row
      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "global-model",
          priority: 1,
          enabled: true
        })

      # Group-A exclusive — same cred
      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "group-a-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_a.id
        })

      # Group-B exclusive — same cred
      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "group-b-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_b.id
        })

      # Member-A exclusive — same cred
      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "member-a-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_member_id: member_a.id
        })

      # Member-B exclusive — same cred
      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "member-b-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_member_id: member_b.id
        })

      all = Providers.list_all_model_providers(model_.id)
      cred_rows = Enum.filter(all, &(&1.credential_id == cred.id))
      assert length(cred_rows) == 5
    end

    @tag :hermes_verify
    test "duplicate in the same scope bucket is still rejected" do
      model_ = model_fixture(%{name: "verify-dup"})
      group = group_fixture(%{name: "Group D"})
      provider = provider_fixture()
      cred = credential_fixture(provider, %{status: "active"})

      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "dup-1",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      {:error, changeset} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "dup-2",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      refute changeset.valid?
      # El índice es por target ahora (modelo + perfil de límites), no por credencial:
      # el error se reporta en el campo del target.
      assert changeset.errors[:exclusive_to_group_id] != nil
    end

    @tag :hermes_verify
    test "list_available_credentials_for_scope excludes same-scope duplicates" do
      model_ = model_fixture(%{name: "verify-reuse"})
      group_a = group_fixture(%{name: "Group E"})
      group_b = group_fixture(%{name: "Group F"})
      provider = provider_fixture()
      cred = credential_fixture(provider, %{status: "active"})

      # Cred is already group-A exclusive for this model
      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred.id,
          provider_model: "group-a-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_a.id
        })

      # A DIFFERENT cred should be available for group-B exclusive assignment
      cred2 = credential_fixture(provider, %{status: "active"})

      {:ok, _} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: cred2.id,
          provider_model: "group-b-model",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_b.id
        })

      # The first cred is excluded from group-scope list (already group-exclusive)
      available = Providers.list_available_credentials_for_scope(model_.id, "group")
      available_ids = Enum.map(available, & &1.id)

      refute cred.id in available_ids
      refute cred2.id in available_ids
    end
  end

  describe "model_providers exclusividad única por target" do
    test "un segundo exclusivo del mismo grupo y modelo es rechazado" do
      group = group_fixture(%{name: "Solo Uno"})
      model_ = model_fixture()

      {:ok, _mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "first",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      # Otra credencial, MISMO perfil de límites y modelo → debe fallar.
      {:error, changeset} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "Otro"})).id,
          provider_model: "second",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      assert %{exclusive_to_group_id: [msg]} = errors_on(changeset)
      assert msg =~ "exclusivo"
    end

    test "un segundo exclusivo del mismo miembro y modelo es rechazado" do
      group = group_fixture()
      member = group_member_fixture(group)
      model_ = model_fixture()

      {:ok, _mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "first",
          priority: 1,
          enabled: true,
          exclusive_to_group_member_id: member.id
        })

      {:error, changeset} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "Otro"})).id,
          provider_model: "second",
          priority: 1,
          enabled: true,
          exclusive_to_group_member_id: member.id
        })

      assert %{exclusive_to_group_member_id: [msg]} = errors_on(changeset)
      assert msg =~ "exclusivo"
    end

    test "exclusivos de grupos DISTINTOS para el mismo modelo siguen permitidos" do
      group_a = group_fixture(%{name: "Grupo A2"})
      group_b = group_fixture(%{name: "Grupo B2"})
      model_ = model_fixture()

      {:ok, mp_a} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "for-a",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_a.id
        })

      {:ok, mp_b} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "B"})).id,
          provider_model: "for-b",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group_b.id
        })

      refute mp_a.id == mp_b.id
    end

    test "un miembro y su grupo pueden tener cada uno su exclusivo para el mismo modelo" do
      group = group_fixture(%{name: "Grupo Mixto"})
      member = group_member_fixture(group)
      model_ = model_fixture()

      # Niveles distintos → ambos conviven.
      {:ok, group_mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "group-level",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      {:ok, member_mp} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "M"})).id,
          provider_model: "member-level",
          priority: 1,
          enabled: true,
          exclusive_to_group_member_id: member.id
        })

      refute group_mp.id == member_mp.id
    end

    test "el scope global sigue permitiendo varias credenciales para el mismo modelo" do
      model_ = model_fixture()

      {:ok, mp1} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "global-1",
          priority: 1,
          enabled: true
        })

      {:ok, mp2} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "G2"})).id,
          provider_model: "global-2",
          priority: 2,
          enabled: true
        })

      assert mp1.id != mp2.id
    end

    test "create_model_providers_transactional: si un target choca, no inserta NINGUNO" do
      model_ = model_fixture()
      group = group_fixture(%{name: "Tx Grupo"})

      # Un target ya ocupado para este modelo.
      {:ok, _existente} =
        Providers.create_model_provider(%{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "ocupado",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        })

      otro_grupo = group_fixture(%{name: "Tx Grupo 2"})

      # Dos targets: uno libre (otro_grupo) y uno ocupado (group).
      params_list = [
        %{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "T1"})).id,
          provider_model: "libre",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: otro_grupo.id
        },
        %{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "T2"})).id,
          provider_model: "choca",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: group.id
        }
      ]

      assert {:error, _changeset} = Providers.create_model_providers_transactional(params_list)

      # El target libre NO debe haber quedado insertado (rollback total):
      # ninguno de los dos provider_model existe para este modelo.
      existentes =
        Providers.list_all_model_providers(model_.id)
        |> Enum.map(& &1.provider_model)

      refute "libre" in existentes
      refute "choca" in existentes
    end

    test "create_model_providers_transactional: targets válidos entran todos" do
      model_ = model_fixture()
      g1 = group_fixture(%{name: "Tx Ok 1"})
      g2 = group_fixture(%{name: "Tx Ok 2"})

      params_list = [
        %{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture()).id,
          provider_model: "ok-1",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: g1.id
        },
        %{
          model_id: model_.id,
          credential_id: credential_fixture(provider_fixture(%{name: "OK2"})).id,
          provider_model: "ok-2",
          priority: 1,
          enabled: true,
          exclusive_to_group_id: g2.id
        }
      ]

      assert {:ok, 2} = Providers.create_model_providers_transactional(params_list)
    end
  end

  # ---------------------------------------------------------------------------
  # Group Model Aliases
  # ---------------------------------------------------------------------------

  describe "group_models" do
    test "grant_model_to_group/2 creates a grant" do
      group = group_fixture()
      model_ = model_fixture()

      assert {:ok, _} = Providers.grant_model_to_group(group.id, model_.id)
    end

    test "grant_model_to_group/2 is idempotent (unique constraint)" do
      group = group_fixture()
      model_ = model_fixture()

      {:ok, _} = Providers.grant_model_to_group(group.id, model_.id)
      {:error, changeset} = Providers.grant_model_to_group(group.id, model_.id)
      assert "has already been taken" in errors_on(changeset).group_id
    end

    test "revoke_model_from_group/2 removes grant" do
      group = group_fixture()
      model_ = model_fixture()

      {:ok, _} = Providers.grant_model_to_group(group.id, model_.id)
      assert {:ok, _} = Providers.revoke_model_from_group(group.id, model_.id)
    end

    test "revoke_model_from_group/2 is idempotent (nil-safe)" do
      group = group_fixture()
      model_ = model_fixture()

      assert {:ok, nil} = Providers.revoke_model_from_group(group.id, model_.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Cascade delete behavior (FK on_delete)
  # ---------------------------------------------------------------------------

  describe "cascade deletes" do
    alias Tokengate.Logs
    alias Tokengate.Logs.RequestLog
    alias Tokengate.Providers.{GroupModel, GroupMemberExtraModel}

    @log_timestamp ~U[2026-07-26 12:00:00Z]

    test "delete_model/1 cascades to group_models" do
      group = group_fixture()
      model_ = model_fixture()
      {:ok, _} = Providers.grant_model_to_group(group.id, model_.id)

      assert Repo.get_by(GroupModel, group_id: group.id, model_id: model_.id)

      {:ok, _} = Providers.delete_model(model_)

      refute Repo.get_by(GroupModel, group_id: group.id, model_id: model_.id)
    end

    test "delete_model/1 cascades to group_member_extra_models" do
      member = group_member_fixture()
      model_ = model_fixture()
      {:ok, _} = Providers.grant_extra_model(member.id, model_.id)

      assert Repo.get_by(GroupMemberExtraModel,
               group_member_id: member.id,
               model_id: model_.id
             )

      {:ok, _} = Providers.delete_model(model_)

      refute Repo.get_by(GroupMemberExtraModel,
               group_member_id: member.id,
               model_id: model_.id
             )
    end

    # provider_id / model_id no longer carry FKs (they made provider
    # deletion O(all referenced log rows) and time out in production). The
    # ids are kept as historical data on the log rows.
    test "delete_provider/1 keeps request_logs.provider_id (no FK)" do
      member = group_member_fixture()
      provider = provider_fixture()

      {:ok, log} =
        Logs.log_request(%{
          group_member_id: member.id,
          provider_id: provider.id,
          model_requested: "gpt-4",
          inserted_at: @log_timestamp
        })

      {:ok, _} = Providers.delete_provider(provider)

      reloaded = Repo.get_by(RequestLog, id: log.id, inserted_at: log.inserted_at)
      assert reloaded != nil
      assert reloaded.provider_id == provider.id
    end

    test "delete_model/1 keeps request_logs.model_id (no FK)" do
      member = group_member_fixture()
      model_ = model_fixture()

      {:ok, log} =
        Logs.log_request(%{
          group_member_id: member.id,
          model_id: model_.id,
          model_requested: "gpt-4",
          inserted_at: @log_timestamp
        })

      {:ok, _} = Providers.delete_model(model_)

      reloaded = Repo.get_by(RequestLog, id: log.id, inserted_at: log.inserted_at)
      assert reloaded != nil
      assert reloaded.model_id == model_.id
    end
  end
end
