defmodule Tokengate.CreditsTest do
  @moduledoc """
  Tests for Tokengate.Credits — subscription config (the policy), grant
  resolution for a membership, and cycle boundaries.
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.{Accounts, Credits}
  alias Tokengate.Credits.Subscription

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} =
      Accounts.create_group(
        Map.merge(%{"name" => "G #{System.unique_integer([:positive])}"}, attrs)
      )

    group
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "u#{System.unique_integer([:positive])}@example.com",
        "name" => "Test User",
        "password" => "ValidPassword123"
      })

    user
  end

  defp member_fixture(group, user) do
    group = group || group_fixture()
    user = user || user_fixture()

    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    member
  end

  defp group_sub(attrs \\ %{}) do
    {:ok, sub} =
      Credits.create_subscription(
        Map.merge(%{"units" => 1000, "recurrence" => "monthly", "reset_day" => 1}, attrs)
      )

    sub
  end

  defp user_sub(user, attrs \\ %{}) do
    {:ok, sub} =
      Credits.create_subscription(
        Map.merge(
          %{"user_id" => user.id, "units" => 500, "recurrence" => "monthly", "reset_day" => 15},
          attrs
        )
      )

    sub
  end

  # ---------------------------------------------------------------------------
  # Subscription changeset
  # ---------------------------------------------------------------------------

  describe "Subscription.changeset/2" do
    test "monthly requires reset_day" do
      assert {:error, cs} =
               Credits.create_subscription(%{"units" => 10, "recurrence" => "monthly"})

      assert %{reset_day: ["es obligatorio para suscripciones mensuales"]} = errors_on(cs)
    end

    test "rollover requires a percentage" do
      assert {:error, cs} =
               Credits.create_subscription(%{
                 "units" => 10,
                 "recurrence" => "monthly",
                 "reset_day" => 1,
                 "rollover_mode" => "rollover"
               })

      assert %{rollover_pct: ["es obligatorio en modo rollover"]} = errors_on(cs)
    end

    test "rollover is only valid on monthly subscriptions" do
      assert {:error, cs} =
               Credits.create_subscription(%{
                 "units" => 10,
                 "recurrence" => "none",
                 "rollover_mode" => "rollover",
                 "rollover_pct" => 50
               })

      assert %{rollover_mode: ["solo aplica a suscripciones mensuales"]} = errors_on(cs)
    end

    test "a top-up (recurrence none) needs no reset_day" do
      assert {:ok, %Subscription{recurrence: "none", reset_day: nil}} =
               Credits.create_subscription(%{"units" => 10, "recurrence" => "none"})
    end

    test "units must be >= 0" do
      assert {:error, cs} =
               Credits.create_subscription(%{"units" => -1, "recurrence" => "none"})

      assert %{units: [_ | _]} = errors_on(cs)
    end
  end

  # ---------------------------------------------------------------------------
  # Grant resolution
  # ---------------------------------------------------------------------------

  describe "grants_for/1" do
    test "the group's default subscription is tier 1" do
      group = group_fixture()
      sub = group_sub()
      {:ok, _} = Credits.set_group_default(group, sub)
      member = member_fixture(group, nil)

      assert [%{tier: 1, subscription: %Subscription{id: id}}] = Credits.grants_for(member)
      assert id == sub.id
    end

    test "direct subscriptions are tier 2, after the group sub" do
      group = group_fixture()
      gsub = group_sub()
      {:ok, _} = Credits.set_group_default(group, gsub)

      user = user_fixture()
      usub = user_sub(user)
      member = member_fixture(group, user)

      assert [
               %{tier: 1, subscription: %Subscription{id: g}},
               %{tier: 2, subscription: %Subscription{id: u}}
             ] = Credits.grants_for(member)

      assert g == gsub.id
      assert u == usub.id
    end

    test "no group sub -> only the user's direct credit" do
      user = user_fixture()
      usub = user_sub(user)
      member = member_fixture(nil, user)

      assert [%{tier: 2, subscription: %Subscription{id: u}}] = Credits.grants_for(member)
      assert u == usub.id
    end

    test "a subscription shared by two groups is the SAME grant (not duplicated)" do
      g1 = group_fixture()
      g2 = group_fixture()
      shared = group_sub()
      {:ok, _} = Credits.set_group_default(g1, shared)
      {:ok, _} = Credits.set_group_default(g2, shared)

      user = user_fixture()
      m1 = member_fixture(g1, user)
      m2 = member_fixture(g2, user)

      assert [%{subscription: %Subscription{id: a}}] = Credits.grants_for(m1)
      assert [%{subscription: %Subscription{id: b}}] = Credits.grants_for(m2)
      assert a == b
      assert a == shared.id
    end

    test "direct credit drains soonest-reset first" do
      user = user_fixture()
      member = member_fixture(nil, user)

      s1 = user_sub(user, %{"reset_day" => 5})
      s2 = user_sub(user, %{"reset_day" => 25})
      s3 = user_sub(user, %{"reset_day" => 12})

      ids = member |> Credits.grants_for() |> Enum.map(& &1.subscription.id)

      expected =
        [s1, s2, s3]
        |> Enum.sort_by(&Credits.next_reset/1, Date)
        |> Enum.map(& &1.id)

      assert ids == expected
    end

    test "paused subscriptions are not granted" do
      user = user_fixture()

      {:ok, _} =
        Credits.create_subscription(%{
          "user_id" => user.id,
          "units" => 1,
          "recurrence" => "none",
          "status" => "paused"
        })

      member = member_fixture(nil, user)

      assert Credits.grants_for(member) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Cycle boundaries
  # ---------------------------------------------------------------------------

  describe "cycle_bounds/2" do
    test "start = most recent reset <= date, end = next reset" do
      sub = %Subscription{recurrence: "monthly", reset_day: 10}

      assert %{start: ~D[2026-09-10], end: ~D[2026-10-10]} =
               Credits.cycle_bounds(sub, ~D[2026-09-13])
    end

    test "before the reset day -> previous month's reset" do
      sub = %Subscription{recurrence: "monthly", reset_day: 20}

      assert %{start: ~D[2026-08-20], end: ~D[2026-09-20]} =
               Credits.cycle_bounds(sub, ~D[2026-09-13])
    end

    test "on the reset day -> the cycle starts today" do
      sub = %Subscription{recurrence: "monthly", reset_day: 13}

      assert %{start: ~D[2026-09-13], end: ~D[2026-10-13]} =
               Credits.cycle_bounds(sub, ~D[2026-09-13])
    end

    test "reset_day 31 clamps to the month length" do
      sub = %Subscription{recurrence: "monthly", reset_day: 31}

      # 2026-09-13: this month's reset clamps to 09-30 (Sept has 30 days),
      # which is in the future, so the cycle started on 08-31.
      assert %{start: ~D[2026-08-31], end: ~D[2026-09-30]} =
               Credits.cycle_bounds(sub, ~D[2026-09-13])
    end

    test "a non-recurring subscription never resets" do
      sub = %Subscription{recurrence: "none"}

      assert %{start: nil, end: nil} = Credits.cycle_bounds(sub, ~D[2026-09-13])
    end
  end
end
