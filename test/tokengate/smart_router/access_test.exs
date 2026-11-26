defmodule Tokengate.SmartRouter.AccessTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Accounts.{ApiKeyCache, Group, GroupMember, Service}
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias TokengateWeb.Plugs.ApiAuth

  setup do
    # ApiKeyCache is a VM-global ETS table: its entries outlive the sandbox.
    ApiKeyCache.invalidate_all()
    :ok
  end

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} =
      Accounts.create_group(
        Map.merge(%{"name" => "Grupo #{System.unique_integer([:positive])}"}, attrs)
      )

    group
  end

  defp member_fixture(group, attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "router-#{System.unique_integer([:positive])}@example.com",
        "name" => "Router User",
        "password" => "ValidPassword123"
      })

    {:ok, member} =
      Accounts.create_group_member(Map.merge(%{user_id: user.id, group_id: group.id}, attrs))

    member
  end

  defp member_with_key(group, attrs \\ %{}) do
    member = member_fixture(group, attrs)
    {:ok, _api_key, token} = Accounts.replace_api_key(member)
    {member, token}
  end

  defp service_with_key(attrs \\ %{}) do
    {:ok, service} =
      Accounts.create_service(
        Map.merge(%{"name" => "svc-#{System.unique_integer([:positive])}"}, attrs)
      )

    {:ok, _api_key, token} = Accounts.generate_service_api_key(service)
    {service, token}
  end

  describe "Accounts.router_enabled?/1 — tri-state resolution" do
    test "a member with no override inherits the profile default (off)" do
      group = group_fixture()
      member = member_fixture(group)

      refute member.router_enabled
      refute Accounts.router_enabled?(Repo.preload(member, :group))
      refute Accounts.router_enabled?(group)
    end

    test "a member with no override inherits the profile default (on)" do
      group = group_fixture(%{"router_enabled" => true})
      member = member_fixture(group)

      assert Accounts.router_enabled?(Repo.preload(member, :group))
      assert Accounts.router_enabled?(group)
    end

    test "member true forces access on a profile that denies it" do
      group = group_fixture(%{"router_enabled" => false})
      member = member_fixture(group, %{router_enabled: true})

      assert Accounts.router_enabled?(Repo.preload(member, :group))
    end

    test "member false denies access on a profile that allows it" do
      group = group_fixture(%{"router_enabled" => true})
      member = member_fixture(group, %{router_enabled: false})

      refute Accounts.router_enabled?(Repo.preload(member, :group))
    end

    test "a member whose profile is not preloaded is loaded, not denied" do
      group = group_fixture(%{"router_enabled" => true})
      member = member_fixture(group)

      bare = Accounts.get_group_member!(member.id)
      assert %Ecto.Association.NotLoaded{} = bare.group
      assert Accounts.router_enabled?(bare)
    end

    test "a service answers with its own flag" do
      {service, _token} = service_with_key()

      refute Accounts.router_enabled?(service)

      {:ok, enabled} = Accounts.update_service(service, %{"router_enabled" => true})
      assert Accounts.router_enabled?(enabled)
    end

    test "a subject with no resolvable end denies by default" do
      refute Accounts.router_enabled?(nil)
      refute Accounts.router_enabled?(%{})
    end
  end

  describe "service virtual member (ApiAuth)" do
    test "carries the service's router flag, not a profile inheritance" do
      {service, _token} = service_with_key(%{"router_enabled" => true})

      virtual = ApiAuth.service_to_virtual_member(service)

      assert %GroupMember{} = virtual
      assert virtual.group == nil
      assert virtual.router_enabled
      assert Accounts.router_enabled?(virtual)
    end

    test "the cached auth entry of a service resolves the router flag" do
      {service, token} = service_with_key()

      assert %{member: %GroupMember{router_enabled: false}, subject_type: "service"} =
               Accounts.resolve_auth_by_api_key(token)

      {:ok, _service} = Accounts.update_service(service, %{"router_enabled" => true})

      assert %{member: member} = Accounts.resolve_auth_by_api_key(token)
      assert member.router_enabled
      assert Accounts.router_enabled?(member)
    end
  end

  describe "auth-cache invalidation (immediate propagation)" do
    test "flipping the profile's flag drops every cached entry of the profile" do
      group = group_fixture()
      {_member, token} = member_with_key(group)

      assert %{member: cached} = Accounts.resolve_auth_by_api_key(token)
      refute Accounts.router_enabled?(cached)

      key_hash = Accounts.hash_api_key(token)
      assert [_entry] = :ets.lookup(ApiKeyCache.table(), key_hash)

      {:ok, _group} = Accounts.update_group(group, %{"router_enabled" => true})

      # The entry was dropped, not served stale.
      assert :ets.lookup(ApiKeyCache.table(), key_hash) == []

      assert %{member: resolved} = Accounts.resolve_auth_by_api_key(token)
      assert resolved.group.router_enabled
      assert Accounts.router_enabled?(resolved)
    end

    test "flipping the member's own flag drops its cached entry" do
      group = group_fixture(%{"router_enabled" => true})
      {member, token} = member_with_key(group)

      assert %{member: cached} = Accounts.resolve_auth_by_api_key(token)
      assert Accounts.router_enabled?(cached)

      key_hash = Accounts.hash_api_key(token)
      assert :ets.lookup(ApiKeyCache.table(), key_hash) != []

      {:ok, _member} = Accounts.update_group_member(member, %{"router_enabled" => false})

      assert :ets.lookup(ApiKeyCache.table(), key_hash) == []

      assert %{member: resolved} = Accounts.resolve_auth_by_api_key(token)
      refute Accounts.router_enabled?(resolved)
    end

    test "flipping a service's flag drops its cached entry" do
      {service, token} = service_with_key()

      assert %{member: %{router_enabled: false}} = Accounts.resolve_auth_by_api_key(token)

      key_hash = Accounts.hash_api_key(token)
      assert :ets.lookup(ApiKeyCache.table(), key_hash) != []

      {:ok, _service} = Accounts.update_service(service, %{"router_enabled" => true})

      assert :ets.lookup(ApiKeyCache.table(), key_hash) == []
      assert %{member: %{router_enabled: true}} = Accounts.resolve_auth_by_api_key(token)
    end
  end

  describe "profile baseline (Accounts.router_baseline_model_id/1)" do
    test "is nil until the profile picks a model, and is exposed for the member" do
      group = group_fixture()
      member = member_fixture(group)

      assert Accounts.router_baseline_model_id(group) == nil
      assert Accounts.router_baseline_model_id(Repo.preload(member, :group)) == nil

      {:ok, model} =
        Providers.create_model(%{
          "name" => "baseline-#{System.unique_integer([:positive])}",
          "context_window" => 128_000
        })

      {:ok, group} = Accounts.update_group(group, %{"router_baseline_model_id" => model.id})

      assert Accounts.router_baseline_model_id(group) == model.id

      member = Repo.get!(GroupMember, member.id) |> Repo.preload(:group)
      assert Accounts.router_baseline_model_id(member) == model.id
    end

    test "a service has no profile baseline" do
      {service, _token} = service_with_key()
      assert Accounts.router_baseline_model_id(service) == nil
    end

    test "the baseline pointer must reference a real model" do
      group = group_fixture()

      assert {:error, changeset} =
               Accounts.update_group(group, %{"router_baseline_model_id" => Ecto.UUID.generate()})

      assert %{router_baseline_model_id: ["does not exist"]} = errors_on(changeset)
    end

    test "deleting the baseline model clears the pointer instead of blocking" do
      group = group_fixture()

      {:ok, model} =
        Providers.create_model(%{
          "name" => "baseline-del-#{System.unique_integer([:positive])}",
          "context_window" => 128_000
        })

      {:ok, group} = Accounts.update_group(group, %{"router_baseline_model_id" => model.id})
      assert Accounts.router_baseline_model_id(group) == model.id

      {:ok, _model} = Providers.delete_model(model)

      assert Accounts.router_baseline_model_id(Repo.get!(Group, group.id)) == nil
    end
  end

  describe "schema" do
    test "the tri-state column is nullable and the profile/service flags are not" do
      group = group_fixture()
      member = member_fixture(group)
      {service, _token} = service_with_key()

      refute group.router_enabled
      refute service.router_enabled
      assert %GroupMember{router_enabled: nil} = member

      {:ok, still_nil} = Accounts.update_group_member(member, %{"router_enabled" => ""})
      assert still_nil.router_enabled == nil
    end

    test "a service's flag is castable through the changeset" do
      {:ok, service} =
        Accounts.create_service(%{
          "name" => "svc-router-#{System.unique_integer([:positive])}",
          "router_enabled" => "true"
        })

      assert %Service{router_enabled: true} = service
    end
  end
end
