defmodule Tokengate.Providers.SubscriptionManagerTest do
  @moduledoc """
  Tests for Tokengate.Providers.SubscriptionManager — ETS round-robin
  rotation, per-sub usage counters, PubSub broadcasts, exhaust marking.

  `async: false` because the ETS tables (`:tokengate_sub_rotation`,
  `:tokengate_sub_usage`) are named (singleton) tables and the GenServer is
  registered under a global name. Each test uses unique providers so the
  shared ETS tables don't collide.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Providers
  alias Tokengate.Providers.{Subscription, SubscriptionManager}

  # Reuse the app-tree instance when present; clear the shared ETS tables so
  # no stale state persists between tests.
  setup do
    pid = Process.whereis(SubscriptionManager) || start_supervised!(SubscriptionManager)
    _ = :sys.get_state(pid)

    if :ets.whereis(:tokengate_sub_rotation) != :undefined do
      :ets.delete_all_objects(:tokengate_sub_rotation)
    end

    if :ets.whereis(:tokengate_sub_usage) != :undefined do
      :ets.delete_all_objects(:tokengate_sub_usage)
    end

    :ok
  end

  # ---------------------------------------------------------------------
  # Fixtures (mirror providers_test.exs patterns)
  # ---------------------------------------------------------------------

  defp provider_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "OpenAI-#{System.unique_integer([:positive])}",
        base_url: "https://api.openai.com",
        billing_type: "pay_per_token",
        track_real_usage: false
      })

    {:ok, provider} = Providers.create_provider(attrs)
    provider
  end

  defp subscription_fixture(provider, attrs \\ %{}) do
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

  # Creates a subscription with a distinct inserted_at so that ordering by
  # inserted_at is deterministic in tests (timestamps are :utc_datetime,
  # i.e. second-precision, so back-to-back inserts share the same value).
  defp timed_subscription(provider, name, offset_seconds) do
    sub = subscription_fixture(provider, %{name: name})

    time =
      DateTime.utc_now()
      |> DateTime.add(offset_seconds)
      |> DateTime.truncate(:second)

    {:ok, _} =
      sub
      |> Ecto.Changeset.change(%{inserted_at: time})
      |> Repo.update()

    %{sub | inserted_at: time}
  end

  # ---------------------------------------------------------------------
  # pick_subscription/1
  # ---------------------------------------------------------------------

  describe "pick_subscription/1" do
    test "rotates through 3 active subs in inserted_at order and wraps around" do
      provider = provider_fixture()

      sub1 = timed_subscription(provider, "Plan 1", -20)
      sub2 = timed_subscription(provider, "Plan 2", -10)
      sub3 = timed_subscription(provider, "Plan 3", 0)

      ordered = [sub1.id, sub2.id, sub3.id]

      picks =
        for _ <- 1..5 do
          {:ok, sub} = SubscriptionManager.pick_subscription(provider.id)
          sub.id
        end

      # 5 picks across 3 subs → [1, 2, 3, 1, 2]
      assert picks == [
               Enum.at(ordered, 0),
               Enum.at(ordered, 1),
               Enum.at(ordered, 2),
               Enum.at(ordered, 0),
               Enum.at(ordered, 1)
             ]
    end

    test "returns {:error, :no_active_subscription} when none exist" do
      provider = provider_fixture()

      assert {:error, :no_active_subscription} =
               SubscriptionManager.pick_subscription(provider.id)
    end

    test "returns {:error, :no_active_subscription} when all are exhausted" do
      provider = provider_fixture()
      sub = subscription_fixture(provider)
      {:ok, _} = Providers.update_subscription(sub, %{status: "exhausted"})

      assert {:error, :no_active_subscription} =
               SubscriptionManager.pick_subscription(provider.id)
    end

    test "returns {:error, :no_active_subscription} when end_date is past" do
      provider = provider_fixture()

      subscription_fixture(provider, %{
        end_date: Date.add(Date.utc_today(), -1)
      })

      assert {:error, :no_active_subscription} =
               SubscriptionManager.pick_subscription(provider.id)
    end

    test "returns {:ok, %Subscription{}} struct" do
      provider = provider_fixture()
      subscription_fixture(provider)

      {:ok, sub} = SubscriptionManager.pick_subscription(provider.id)
      assert %Subscription{} = sub
      assert sub.status == "active"
    end
  end

  # ---------------------------------------------------------------------
  # record_usage/1 + usage/1
  # ---------------------------------------------------------------------

  describe "record_usage/1 and usage/1" do
    test "counts usage per subscription" do
      provider = provider_fixture()
      sub1 = subscription_fixture(provider, %{name: "Plan 1"})
      sub2 = subscription_fixture(provider, %{name: "Plan 2"})

      SubscriptionManager.record_usage(sub1.id)
      SubscriptionManager.record_usage(sub1.id)
      SubscriptionManager.record_usage(sub2.id)

      counts = SubscriptionManager.usage(provider.id)

      # Find counts by subscription id.
      c1 = Enum.find(counts, &(&1.subscription_id == sub1.id))
      c2 = Enum.find(counts, &(&1.subscription_id == sub2.id))

      assert c1.count == 2
      assert c2.count == 1
    end

    test "usage includes subscriptions with zero count" do
      provider = provider_fixture()
      sub = subscription_fixture(provider)

      counts = SubscriptionManager.usage(provider.id)

      assert length(counts) == 1
      assert hd(counts).subscription_id == sub.id
      assert hd(counts).count == 0
    end

    test "multiple providers are independent" do
      provider_a = provider_fixture()
      provider_b = provider_fixture()

      sub_a = subscription_fixture(provider_a, %{name: "Plan A"})
      sub_b = subscription_fixture(provider_b, %{name: "Plan B"})

      SubscriptionManager.record_usage(sub_a.id)
      SubscriptionManager.record_usage(sub_a.id)
      SubscriptionManager.record_usage(sub_a.id)

      SubscriptionManager.record_usage(sub_b.id)

      counts_a = SubscriptionManager.usage(provider_a.id)
      counts_b = SubscriptionManager.usage(provider_b.id)

      a = Enum.find(counts_a, &(&1.subscription_id == sub_a.id))
      b = Enum.find(counts_b, &(&1.subscription_id == sub_b.id))

      assert a.count == 3
      assert b.count == 1

      # Provider A usage list should not include provider B's sub.
      refute Enum.any?(counts_a, &(&1.subscription_id == sub_b.id))
      refute Enum.any?(counts_b, &(&1.subscription_id == sub_a.id))
    end

    test "record_usage returns :ok" do
      provider = provider_fixture()
      sub = subscription_fixture(provider)
      assert :ok = SubscriptionManager.record_usage(sub.id)
    end
  end

  # ---------------------------------------------------------------------
  # rotate/1
  # ---------------------------------------------------------------------

  describe "rotate/1" do
    test "broadcasts {:subscription_rotated, provider_id, subscription_id}" do
      provider = provider_fixture()
      sub1 = timed_subscription(provider, "Plan 1", -10)
      sub2 = timed_subscription(provider, "Plan 2", 0)

      provider_id = provider.id
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "subscriptions")

      {:ok, picked} = SubscriptionManager.rotate(provider_id)

      assert_receive {:subscription_rotated, ^provider_id, sub_id}
      assert sub_id == picked.id

      {:ok, picked2} = SubscriptionManager.rotate(provider_id)

      assert_receive {:subscription_rotated, ^provider_id, sub_id2}
      assert sub_id2 == picked2.id

      # Order should be sub1 then sub2 (inserted_at order).
      assert [picked.id, picked2.id] == [sub1.id, sub2.id]
    end

    test "does not broadcast on error" do
      provider = provider_fixture()
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "subscriptions")

      assert {:error, :no_active_subscription} = SubscriptionManager.rotate(provider.id)

      refute_receive {:subscription_rotated, _, _}, 100
    end
  end

  # ---------------------------------------------------------------------
  # exhaust/1
  # ---------------------------------------------------------------------

  describe "exhaust/1" do
    test "updates DB status to exhausted and broadcasts" do
      provider = provider_fixture()
      sub = subscription_fixture(provider)

      Phoenix.PubSub.subscribe(Tokengate.PubSub, "subscriptions")

      sub_id = sub.id
      {:ok, updated} = SubscriptionManager.exhaust(sub_id)

      assert updated.status == "exhausted"

      # Verify DB persisted.
      reloaded = Providers.get_subscription!(sub_id)
      assert reloaded.status == "exhausted"

      assert_receive {:subscription_exhausted, ^sub_id}
    end

    test "exhausted sub drops out of subsequent pick rotation" do
      provider = provider_fixture()
      sub1 = subscription_fixture(provider, %{name: "Plan 1"})
      Process.sleep(10)
      sub2 = subscription_fixture(provider, %{name: "Plan 2"})

      {:ok, _} = SubscriptionManager.exhaust(sub1.id)

      # Only sub2 should be picked now.
      for _ <- 1..3 do
        {:ok, picked} = SubscriptionManager.pick_subscription(provider.id)
        assert picked.id == sub2.id
      end
    end

    test "exhaust on the last active subscription leaves none" do
      provider = provider_fixture()
      sub = subscription_fixture(provider)

      {:ok, _} = SubscriptionManager.exhaust(sub.id)

      assert {:error, :no_active_subscription} =
               SubscriptionManager.pick_subscription(provider.id)
    end

    test "returns {:error, :not_found} for unknown subscription_id" do
      assert {:error, :not_found} = SubscriptionManager.exhaust(Ecto.UUID.generate())
    end
  end
end
