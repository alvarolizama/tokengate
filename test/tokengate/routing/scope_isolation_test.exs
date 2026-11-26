defmodule Tokengate.Routing.ScopeIsolationTest do
  @moduledoc """
  Lane isolation in `Tokengate.Routing.Router`.

  Two invariants that a cached provider list can break if nothing enforces
  them:

    * a lane exclusive to a GROUP is invisible outside that group, whatever
      list it arrived in (the cache is keyed per scope, but a list can still
      carry a foreign row);
    * a SERVICE has its own cache scope — two services with a service-exclusive
      lane for the SAME model never read each other's list, and `:global` never
      carries an exclusive lane at all.

  `async: false`: the routing cache and the circuit breaker are app-tree
  singletons shared by every test process.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Routing.{Cache, Router}

  @context_window 128_000

  setup do
    # The cache survives the sandbox: clear it so a fixture from another test
    # can't answer for this one.
    Cache.invalidate_all()
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp group_fixture(name) do
    {:ok, group} =
      Accounts.create_group(%{
        name: "#{name} #{unique()}",
        default_rpm_limit: 600,
        default_concurrency_limit: 10,
        unlimited_spend: true
      })

    group
  end

  defp member_fixture(group) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "scope-#{u}@example.com",
        name: "Scope #{u}",
        password: "password-#{u}-secret1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
    member
  end

  defp service_fixture(name) do
    {:ok, service} = Accounts.create_service(%{name: "#{name} #{unique()}"})
    service
  end

  # The virtual member the proxy builds for a service: no group, no user, the
  # service's own name and id.
  defp service_member(service) do
    %GroupMember{
      id: service.id,
      group_id: nil,
      user_id: nil,
      status: "active",
      service_name: service.name,
      group: nil,
      user: nil,
      api_key: nil
    }
  end

  defp model_fixture do
    {:ok, model} =
      Tokengate.Providers.create_model(%{
        name: "scope-model-#{unique()}",
        model_type: "llm",
        context_window: @context_window
      })

    model
  end

  # A lane with its credential + provider preloaded, the shape the router's
  # cache stores and reads.
  defp lane_fixture(model, attrs) do
    {:ok, provider} =
      Tokengate.Providers.create_provider(%{
        name: "P lane #{unique()}",
        base_url: "http://localhost:1"
      })

    {:ok, credential} =
      Tokengate.Providers.create_credential(%{
        provider_id: provider.id,
        api_key_encrypted: "sk-lane-#{unique()}"
      })

    {:ok, lane} =
      Tokengate.Providers.create_model_provider(
        Map.merge(
          %{
            model_id: model.id,
            credential_id: credential.id,
            provider_model: "upstream-#{unique()}",
            priority: 1
          },
          attrs
        )
      )

    %{lane: Repo.preload(lane, credential: :provider), credential: credential}
  end

  describe "group-exclusive lanes" do
    test "a lane exclusive to another group is never served, even from a cached list" do
      group_a = group_fixture("Group A")
      group_b = group_fixture("Group B")
      member_a = member_fixture(group_a) |> Repo.preload(:group)

      model = model_fixture()
      global = lane_fixture(model, %{})
      foreign = lane_fixture(model, %{exclusive_to_group_id: group_b.id})

      # A list that (wrongly) carries group B's exclusive lane under group A's
      # cache key: the visibility check — not the query — must drop it. The
      # exclusive lane also wins on priority (-1), so without the guard it
      # would be selected.
      Cache.fetch_model_providers(model.id, group_a.id, fn ->
        [foreign.lane, global.lane]
      end)

      assert {:ok, route} = Router.route_by_model_id(model.id, member_a)
      assert route.credential.id == global.credential.id
    end

    test "the same model still serves its own group's exclusive lane first" do
      group_b = group_fixture("Group B")
      member_b = member_fixture(group_b) |> Repo.preload(:group)

      model = model_fixture()
      _global = lane_fixture(model, %{})
      owned = lane_fixture(model, %{exclusive_to_group_id: group_b.id})

      Cache.fetch_model_providers(model.id, group_b.id, fn -> [owned.lane] end)

      assert {:ok, route} = Router.route_by_model_id(model.id, member_b)
      assert route.credential.id == owned.credential.id
    end
  end

  describe "service lanes" do
    test "two services with their own exclusive lane never share a cache entry" do
      model = model_fixture()

      service_a = service_fixture("Service A")
      service_b = service_fixture("Service B")

      lane_a = lane_fixture(model, %{exclusive_to_service_id: service_a.id})
      lane_b = lane_fixture(model, %{exclusive_to_service_id: service_b.id})

      assert {:ok, route_a} = Router.route_by_model_id(model.id, service_member(service_a))
      assert route_a.credential.id == lane_a.credential.id

      # Before the scope fix both services shared `:global`, so B would have
      # read A's list (and either leaked A's lane or found nothing at all).
      assert {:ok, route_b} = Router.route_by_model_id(model.id, service_member(service_b))
      assert route_b.credential.id == lane_b.credential.id

      assert [_entry] =
               :ets.lookup(Cache.table(), {:model_providers, model.id, {:service, service_a.id}})

      assert [_entry] =
               :ets.lookup(Cache.table(), {:model_providers, model.id, {:service, service_b.id}})

      # Neither service polluted the group-less scope.
      assert [] = :ets.lookup(Cache.table(), {:model_providers, model.id, :global})
    end

    test "a service never sees a group-exclusive lane" do
      group = group_fixture("Group A")
      service = service_fixture("Service A")

      model = model_fixture()
      _group_lane = lane_fixture(model, %{exclusive_to_group_id: group.id})
      service_lane = lane_fixture(model, %{exclusive_to_service_id: service.id})

      assert {:ok, route} = Router.route_by_model_id(model.id, service_member(service))
      assert route.credential.id == service_lane.credential.id
    end
  end

  describe "the group-less scope" do
    test ":global carries only lanes with no exclusive scope" do
      model = model_fixture()
      group = group_fixture("Group A")
      owner = member_fixture(group)

      global = lane_fixture(model, %{})
      _group_lane = lane_fixture(model, %{exclusive_to_group_id: group.id})
      _member_lane = lane_fixture(model, %{exclusive_to_group_member_id: owner.id})

      # A member with no group and no service is the only consumer that reads
      # the `:global` scope.
      ghost = %GroupMember{
        id: Ecto.UUID.generate(),
        group_id: nil,
        user_id: nil,
        status: "active",
        service_name: nil,
        group: nil,
        user: nil,
        api_key: nil
      }

      assert {:ok, route} = Router.route_by_model_id(model.id, ghost)
      assert route.credential.id == global.credential.id

      assert [{_key, lanes, _expires_at}] =
               :ets.lookup(Cache.table(), {:model_providers, model.id, :global})

      assert Enum.map(lanes, & &1.id) == [global.lane.id]
    end
  end
end
