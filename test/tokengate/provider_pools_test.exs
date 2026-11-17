defmodule Tokengate.ProviderPoolsTest do
  @moduledoc """
  Credential pools: CRUD, membership invariants, deletion guards and the
  provider cascade that has to walk pool lanes without tripping a RESTRICT
  foreign key.

  The provider-scoping invariant has two layers and both are tested: the context
  (`add_pool_member/2` fails fast with `:provider_mismatch`) and the composite
  FK `(credential_id, provider_id)`, exercised with a direct insert that
  bypasses the context.
  """
  use Tokengate.DataCase, async: true

  alias Tokengate.Providers
  alias Tokengate.Providers.{Credential, CredentialPool, CredentialPoolMember, ModelProvider}

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp provider_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, provider} =
      Providers.create_provider(
        Enum.into(attrs, %{
          name: "Pool Prov #{unique}",
          base_url: "https://pool-#{unique}.example.com",
          status: "active"
        })
      )

    provider
  end

  defp credential_fixture(provider, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, credential} =
      Providers.create_credential(
        Enum.into(attrs, %{
          provider_id: provider.id,
          name: "key-#{unique}",
          api_key_encrypted: "sk-pool-#{unique}",
          status: "active"
        })
      )

    credential
  end

  defp model_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, model} =
      Providers.create_model(
        Enum.into(attrs, %{name: "pool-model-#{unique}", context_window: 128_000})
      )

    model
  end

  defp pool_fixture(provider, attrs \\ %{}) do
    {:ok, pool} = Providers.create_pool(provider, Enum.into(attrs, %{name: "primary"}))
    pool
  end

  # A lane mounted on a pool: it carries pool_id and NO credential_id.
  defp pool_lane_fixture(model, pool, attrs \\ %{}) do
    {:ok, lane} =
      Providers.create_model_provider(
        Enum.into(attrs, %{
          model_id: model.id,
          pool_id: pool.id,
          provider_model: "gpt-4-turbo",
          enabled: true,
          priority: 1
        })
      )

    lane
  end

  defp error_messages(changeset) do
    changeset
    |> errors_on()
    |> Map.values()
    |> List.flatten()
  end

  # ---------------------------------------------------------------------------
  # Pools
  # ---------------------------------------------------------------------------

  describe "pools" do
    test "creates a pool for a provider and lists it, ordered by name" do
      provider = provider_fixture()
      other_provider = provider_fixture()

      zeta = pool_fixture(provider, %{name: "zeta"})
      alpha = pool_fixture(provider, %{name: "alpha"})
      _foreign = pool_fixture(other_provider, %{name: "alpha"})

      assert [%CredentialPool{} = first, %CredentialPool{} = second] =
               Providers.list_pools_for_provider(provider.id)

      assert first.id == alpha.id
      assert second.id == zeta.id
      assert first.provider_id == provider.id
      # A fresh pool has no members, and the preload reflects that.
      assert first.members == []
    end

    test "rejects a duplicate name inside the same provider" do
      provider = provider_fixture()
      _pool = pool_fixture(provider, %{name: "principal"})

      assert {:error, changeset} = Providers.create_pool(provider, %{name: "principal"})
      assert "has already been taken" in error_messages(changeset)
    end

    test "allows the same pool name in another provider" do
      provider = provider_fixture()
      other_provider = provider_fixture()
      first = pool_fixture(provider, %{name: "principal"})

      assert {:ok, second} = Providers.create_pool(other_provider, %{name: "principal"})
      assert second.id != first.id
      assert second.provider_id == other_provider.id
    end

    test "the provider is fixed on the struct, never taken from the attrs" do
      provider = provider_fixture()
      other_provider = provider_fixture()

      {:ok, pool} =
        Providers.create_pool(provider, %{name: "fixed", provider_id: other_provider.id})

      assert pool.provider_id == provider.id
    end

    test "renames a pool" do
      provider = provider_fixture()
      pool = pool_fixture(provider, %{name: "before"})

      assert {:ok, renamed} = Providers.update_pool(pool, %{name: "after"})
      assert renamed.name == "after"
      assert Providers.get_pool!(pool.id).name == "after"
    end

    test "lists a pool with its members, each credential and its provider preloaded" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      key_a = credential_fixture(provider)
      key_b = credential_fixture(provider)

      {:ok, _} = Providers.add_pool_member(pool, key_a)
      {:ok, _} = Providers.add_pool_member(pool, key_b)

      assert [%CredentialPool{members: members}] = Providers.list_pools_for_provider(provider.id)
      assert length(members) == 2

      # The credential AND its provider come from the preload: the UI reads
      # lane.credential.provider without a query per row.
      assert Enum.all?(members, &match?(%Credential{provider: %{id: _}}, &1.credential))
      assert Enum.all?(members, &(&1.credential.provider.id == provider.id))
      assert Enum.sort(Enum.map(members, & &1.credential_id)) == Enum.sort([key_a.id, key_b.id])
    end
  end

  # ---------------------------------------------------------------------------
  # Members
  # ---------------------------------------------------------------------------

  describe "pool members" do
    test "adds a credential of the same provider and stamps the pool's provider_id" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)

      assert {:ok, %CredentialPoolMember{} = member} =
               Providers.add_pool_member(pool, credential)

      assert member.pool_id == pool.id
      assert member.provider_id == pool.provider_id
      assert member.credential_id == credential.id

      assert [listed] = Providers.list_pool_members(pool)
      assert listed.id == member.id
      assert listed.credential.id == credential.id
      assert listed.credential.provider.id == provider.id

      assert [%CredentialPool{id: pool_id}] = Providers.pools_for_credential(credential.id)
      assert pool_id == pool.id
    end

    test "rejects a credential from another provider with :provider_mismatch" do
      provider = provider_fixture()
      other_provider = provider_fixture()
      pool = pool_fixture(provider)
      foreign_credential = credential_fixture(other_provider)

      assert {:error, :provider_mismatch} = Providers.add_pool_member(pool, foreign_credential)
      assert Providers.list_pool_members(pool) == []
    end

    test "the composite FK rejects a cross-provider membership on a direct insert" do
      provider = provider_fixture()
      other_provider = provider_fixture()
      pool = pool_fixture(provider)
      foreign_credential = credential_fixture(other_provider)

      # Bypasses add_pool_member/2 on purpose: provider_id is the POOL's (so the
      # (pool_id, provider_id) FK holds) and the credential belongs elsewhere, so
      # only the (credential_id, provider_id) FK can reject it. Declared in the
      # changeset, hence a changeset error and not a raised ConstraintError.
      result =
        %CredentialPoolMember{pool_id: pool.id, provider_id: pool.provider_id}
        |> CredentialPoolMember.changeset(%{
          pool_id: pool.id,
          credential_id: foreign_credential.id
        })
        |> Repo.insert()

      assert {:error, changeset} = result
      assert "credential does not belong to the pool's provider" in error_messages(changeset)
      assert Providers.list_pool_members(pool) == []
    end

    test "rejects the same credential twice in one pool" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)

      {:ok, _} = Providers.add_pool_member(pool, credential)

      assert {:error, changeset} = Providers.add_pool_member(pool, credential)
      assert "this credential is already a member of the pool" in error_messages(changeset)
      assert length(Providers.list_pool_members(pool)) == 1
    end

    test "refuses to remove the last member" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)
      {:ok, member} = Providers.add_pool_member(pool, credential)

      assert {:error, :last_member} = Providers.remove_pool_member(member)
      assert length(Providers.list_pool_members(pool)) == 1
    end

    test "removes a member while another one remains" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      key_a = credential_fixture(provider)
      key_b = credential_fixture(provider)

      {:ok, member} = Providers.add_pool_member(pool, key_a)
      {:ok, _} = Providers.add_pool_member(pool, key_b)

      assert {:ok, _} = Providers.remove_pool_member(member)
      assert [remaining] = Providers.list_pool_members(pool)
      assert remaining.credential_id == key_b.id
      assert Providers.pools_for_credential(key_a.id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Guards
  # ---------------------------------------------------------------------------

  describe "pool guards" do
    test "refuses to delete a pool mounted as a lane" do
      provider = provider_fixture()
      model = model_fixture()
      pool = pool_fixture(provider)
      lane = pool_lane_fixture(model, pool)

      assert {:error, :pool_in_use} = Providers.delete_pool(pool)
      assert Providers.get_pool(pool.id)

      # Once the lane is gone the pool is deletable.
      {:ok, _} = Providers.delete_model_provider(lane)
      assert {:ok, _} = Providers.delete_pool(pool)
      assert Providers.get_pool(pool.id) == nil
    end

    test "refuses to delete a credential that lives in a pool" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)
      {:ok, _} = Providers.add_pool_member(pool, credential)

      assert {:error, :credential_in_pool} = Providers.delete_credential(credential)
      assert %Credential{} = Providers.get_credential(credential.id)
      assert %CredentialPoolMember{} = Providers.credential_in_use?(credential.id)
    end

    test "credential_in_use? is nil for a free credential and a lane for a served one" do
      provider = provider_fixture()
      model = model_fixture()
      free = credential_fixture(provider)
      served = credential_fixture(provider)

      {:ok, lane} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: served.id,
          provider_model: "gpt-4-turbo",
          enabled: true
        })

      assert Providers.credential_in_use?(free.id) == nil
      assert %ModelProvider{id: lane_id} = Providers.credential_in_use?(served.id)
      assert lane_id == lane.id
    end

    test "deleting a pool drops its memberships but leaves the credentials alive" do
      provider = provider_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)
      {:ok, member} = Providers.add_pool_member(pool, credential)

      assert {:ok, _} = Providers.delete_pool(pool)
      assert Repo.get(CredentialPoolMember, member.id) == nil
      assert %Credential{} = Providers.get_credential(credential.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Provider cascade
  # ---------------------------------------------------------------------------

  describe "delete_provider/1 with pools" do
    test "cascades a pool lane, its pool, its memberships and its credentials" do
      provider = provider_fixture()
      model = model_fixture()
      pool = pool_fixture(provider)
      key_a = credential_fixture(provider)
      key_b = credential_fixture(provider)
      {:ok, member} = Providers.add_pool_member(pool, key_a)
      {:ok, _} = Providers.add_pool_member(pool, key_b)
      lane = pool_lane_fixture(model, pool)

      # No FK error: the pool lane (credential_id NULL) and the RESTRICT
      # memberships are walked before the credentials are deleted.
      assert {:ok, _} = Providers.delete_provider(provider)

      assert Repo.get(ModelProvider, lane.id) == nil
      assert Repo.get(CredentialPool, pool.id) == nil
      assert Repo.get(CredentialPoolMember, member.id) == nil
      assert Providers.list_credentials_for_provider(provider.id) == []
      assert Providers.list_pools_for_provider(provider.id) == []
      assert Providers.get_provider(provider.id) == nil
    end

    test "cascades key lanes and pool lanes of the same provider together" do
      provider = provider_fixture()
      model = model_fixture()
      pool = pool_fixture(provider)
      pooled_credential = credential_fixture(provider)
      key_credential = credential_fixture(provider)
      {:ok, _} = Providers.add_pool_member(pool, pooled_credential)

      pool_lane = pool_lane_fixture(model, pool)

      {:ok, key_lane} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: key_credential.id,
          provider_model: "gpt-4-turbo",
          enabled: true
        })

      assert {:ok, _} = Providers.delete_provider(provider)

      assert Repo.get(ModelProvider, pool_lane.id) == nil
      assert Repo.get(ModelProvider, key_lane.id) == nil
      assert Providers.list_credentials_for_provider(provider.id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # DB invariants
  # ---------------------------------------------------------------------------

  describe "model_providers XOR invariant" do
    test "a direct insert with credential AND pool raises the CHECK" do
      provider = provider_fixture()
      model = model_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)

      error =
        assert_raise Ecto.ConstraintError, fn ->
          %ModelProvider{}
          |> Ecto.Changeset.change(%{
            model_id: model.id,
            credential_id: credential.id,
            pool_id: pool.id,
            provider_model: "gpt-4-turbo",
            priority: 1,
            enabled: true
          })
          |> Repo.insert()
        end

      assert error.type == :check
      assert error.constraint == "model_providers_one_source_check"
    end

    test "a direct insert with neither source raises the CHECK" do
      model = model_fixture()

      error =
        assert_raise Ecto.ConstraintError, fn ->
          %ModelProvider{}
          |> Ecto.Changeset.change(%{
            model_id: model.id,
            provider_model: "gpt-4-turbo",
            priority: 1,
            enabled: true
          })
          |> Repo.insert()
        end

      assert error.type == :check
      assert error.constraint == "model_providers_one_source_check"
    end

    test "the changeset rejects both sources before reaching the DB" do
      provider = provider_fixture()
      model = model_fixture()
      pool = pool_fixture(provider)
      credential = credential_fixture(provider)

      {:error, changeset} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: credential.id,
          pool_id: pool.id,
          provider_model: "gpt-4-turbo",
          enabled: true
        })

      assert "a lane cannot use a credential and a pool at the same time" in error_messages(
               changeset
             )
    end
  end
end
