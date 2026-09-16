defmodule Tokengate.CreditsTest do
  @moduledoc """
  Tests for Tokengate.Credits — subscription config (the policy), grant
  resolution for a membership, and cycle boundaries.
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.{Accounts, Credits, Logs}
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

    test "a paused direct subscription is granted with 0 credit (revoca, no libera)" do
      user = user_fixture()

      {:ok, paused} =
        Credits.create_subscription(%{
          "user_id" => user.id,
          "units" => 1,
          "recurrence" => "none",
          "status" => "paused"
        })

      member = member_fixture(nil, user)

      # Sigue en la lista de grants (tier 2) con 0 crédito: el usuario queda
      # bloqueado en vez de caer a tier 3 (ilimitado).
      assert [%{tier: 2, subscription: %Subscription{id: id}}] = Credits.grants_for(member)
      assert id == paused.id

      credit = Credits.member_credit(member)
      assert credit.has_credit?
      assert credit.credited_micro == 0
      assert credit.remaining_micro == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Service grants (services are group-independent)
  # ---------------------------------------------------------------------------

  describe "service_grants/1" do
    test "a service without subscription has no grants (unlimited, tier 3)" do
      {:ok, service} =
        Accounts.create_service(%{name: "Svc #{System.unique_integer([:positive])}"})

      assert Credits.service_grants(service) == []
    end

    test "the service's direct subscription is its tier-1 grant" do
      sub = group_sub()

      {:ok, service} =
        Accounts.create_service(%{
          name: "Svc #{System.unique_integer([:positive])}",
          subscription_id: sub.id
        })

      assert [%{tier: 1, subscription: %Subscription{id: sub_id}, service_id: service_id}] =
               Credits.service_grants(service)

      assert sub_id == sub.id
      assert service_id == service.id
    end

    test "a paused subscription stays as a 0-credit grant (bloquea, no libera)" do
      sub = group_sub(%{"status" => "paused"})

      {:ok, service} =
        Accounts.create_service(%{
          name: "Svc #{System.unique_integer([:positive])}",
          subscription_id: sub.id
        })

      assert [%{tier: 1, subscription: %Subscription{id: id}, service_id: _}] =
               Credits.service_grants(service)

      assert id == sub.id
      assert Credits.grant_state(sub, {:service, service.id}).credited_micro == 0
    end
  end

  describe "grant_state/2 with a service subject" do
    test "credits are per-service even when two services share one subscription" do
      sub = group_sub()

      {:ok, s1} =
        Accounts.create_service(%{
          name: "S1 #{System.unique_integer([:positive])}",
          subscription_id: sub.id
        })

      {:ok, s2} =
        Accounts.create_service(%{
          name: "S2 #{System.unique_integer([:positive])}",
          subscription_id: sub.id
        })

      # Debit s1's pocket only.
      {:ok, _} =
        Tokengate.Logs.log_request(%{
          subject_type: "service",
          model_requested: "gpt-test",
          service_id: s1.id,
          credit_subscription_id: sub.id,
          provider_cost_usd: Decimal.new("2.50")
        })

      s1_state = Credits.grant_state(sub, {:service, s1.id})
      s2_state = Credits.grant_state(sub, {:service, s2.id})

      assert s1_state.consumed_micro == 2_500_000
      assert s2_state.consumed_micro == 0
      assert s1_state.credited_micro == s2_state.credited_micro
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

  describe "member_credit/1" do
    test "no applicable subscription -> has_credit? false" do
      member = member_fixture(nil, nil)
      credit = Credits.member_credit(member)

      refute credit.has_credit?
      assert credit.credited_micro == 0
      assert credit.remaining_micro == 0
    end

    test "sums the group sub's credited credit and the member's spend" do
      group = group_fixture()
      sub = group_sub(%{"units" => 100})
      {:ok, _} = Credits.set_group_default(group, sub)
      user = user_fixture()
      member = member_fixture(group, user)

      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("30.00"),
          credit_subscription_id: sub.id
        })

      credit = Credits.member_credit(member)

      assert credit.has_credit?
      assert credit.credited_micro == 100_000_000
      assert credit.consumed_micro == 30_000_000
      assert credit.remaining_micro == 70_000_000
    end
  end

  # ---------------------------------------------------------------------------
  # Ventana de la sub: `starts_at` / `expires_at` (solo existen en top-ups
  # `recurrence = "none"`). Estaban definidos en la config y usados para el
  # badge de "vencido", pero el gate de crédito los ignoraba por completo: un
  # top-up vencido seguía otorgando su saldo sin usar, y uno aún no empezado
  # otorgaba antes de tiempo.
  # ---------------------------------------------------------------------------
  describe "ventana de la sub (starts_at / expires_at)" do
    defp top_up(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      group_sub(
        Map.merge(%{"recurrence" => "none", "reset_day" => nil, "starts_at" => now}, attrs)
      )
    end

    defp seconds_ago(n),
      do: DateTime.add(DateTime.utc_now(), -n, :second) |> DateTime.truncate(:second)

    defp seconds_ahead(n),
      do: DateTime.add(DateTime.utc_now(), n, :second) |> DateTime.truncate(:second)

    test "grants_credit?/1: activa y dentro de ventana" do
      assert Credits.grants_credit?(group_sub(%{}))
      assert Credits.grants_credit?(top_up(%{}))
      assert Credits.grants_credit?(top_up(%{"expires_at" => seconds_ahead(3600)}))

      refute Credits.grants_credit?(group_sub(%{"status" => "paused"}))
      refute Credits.grants_credit?(top_up(%{"expires_at" => seconds_ago(60)}))
      refute Credits.grants_credit?(top_up(%{"starts_at" => seconds_ahead(3600)}))
    end

    test "un top-up vencido con saldo deja de otorgar crédito" do
      user = user_fixture()
      group = group_fixture()
      member = member_fixture(group, user)

      sub = top_up(%{"units" => 50, "expires_at" => seconds_ago(60)})
      {:ok, _} = Credits.set_group_default(group, sub)

      assert Credits.grant_state(sub, user.id).credited_micro == 0

      # Sigue vinculado: el grant existe con 0 crédito (revoca, no libera).
      credit = Credits.member_credit(member)
      assert credit.has_credit?
      assert credit.credited_micro == 0
      assert credit.remaining_micro == 0
    end

    test "un top-up que aún no empieza tampoco otorga crédito" do
      sub = top_up(%{"units" => 50, "starts_at" => seconds_ahead(3600)})

      assert Credits.grant_state(sub, user_fixture().id).credited_micro == 0
    end

    test "dentro de la ventana sí otorga (control)" do
      sub =
        top_up(%{
          "units" => 50,
          "starts_at" => seconds_ago(3600),
          "expires_at" => seconds_ahead(3600)
        })

      assert Credits.grant_state(sub, user_fixture().id).credited_micro == 50_000_000
    end

    test "member_credits/1 (lote) revoca la ventana igual que member_credit/1" do
      user = user_fixture()
      group = group_fixture()
      member = member_fixture(group, user)

      expired = top_up(%{"units" => 30, "expires_at" => seconds_ago(60)})
      {:ok, _} = Credits.set_group_default(group, expired)

      batch = Credits.member_credits([member]) |> Map.fetch!(member.id)

      assert batch.has_credit?
      assert batch.credited_micro == 0
      assert batch.credited_micro == Credits.member_credit(member).credited_micro
    end
  end

  describe "auth-cache invalidation on group default change" do
    alias Tokengate.Accounts.ApiKeyCache

    defp cache_group_grants(member) do
      # Simulate what Plugs.ApiAuth caches: the member + its resolved grants.
      entry = %{
        member: member,
        limits: %{credit_grants: Credits.grants_for(member)},
        subject_type: "user"
      }

      :ets.insert(ApiKeyCache.table(), {"k-#{member.id}", entry, 9_999_999_999_999})
      :ok
    end

    defp cached_entry?(member),
      do: :ets.lookup(ApiKeyCache.table(), "k-#{member.id}") != []

    test "set_group_default drops the group members' cached grants" do
      group = group_fixture()
      user = user_fixture()
      member = member_fixture(group, user)

      cache_group_grants(member)
      assert cached_entry?(member)

      sub = group_sub(%{"units" => 100})
      {:ok, _} = Credits.set_group_default(group, sub)

      # Without invalidation the members keep the old grants for the 60s TTL.
      refute cached_entry?(member)
    end

    test "clearing the group default also drops the cached grants" do
      group = group_fixture()
      sub = group_sub(%{"units" => 50})
      {:ok, _} = Credits.set_group_default(group, sub)

      user = user_fixture()
      member = member_fixture(group, user)

      cache_group_grants(member)
      assert cached_entry?(member)

      {:ok, _} = Credits.set_group_default(group, nil)

      refute cached_entry?(member)
    end

    test "assign_groups drops the cached grants of every touched group" do
      group = group_fixture()
      other = group_fixture()
      user = user_fixture()
      member = member_fixture(group, user)
      other_member = member_fixture(other, user_fixture())

      cache_group_grants(member)
      cache_group_grants(other_member)

      sub = group_sub(%{"units" => 25})
      :ok = Credits.assign_groups(sub, [group.id, other.id])

      refute cached_entry?(member)
      refute cached_entry?(other_member)
    end

    # Regresión: `Repo.update` de un changeset sin cambios es un no-op, así que
    # desvincular con un struct obsoleto (cargado antes de vincular) dejaba el
    # vínculo fantasma en la BD: la UI decía "sin suscripción" pero el grupo
    # seguía gateando el crédito de sus miembros.
    test "set_group_default(group, nil) escribe aunque el struct esté obsoleto" do
      group = group_fixture()
      stale = group
      sub = group_sub(%{"units" => 5})

      {:ok, _} = Credits.set_group_default(group, sub)
      assert Accounts.get_group(group.id).default_subscription_id == sub.id

      {:ok, _} = Credits.set_group_default(stale, nil)
      assert Accounts.get_group(group.id).default_subscription_id == nil
    end
  end
end
