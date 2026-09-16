defmodule TokengateWeb.SubscriptionsLiveTest do
  @moduledoc "Tests for the Subscriptions admin page (credit subscriptions CRUD)."

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Credits}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "subs-#{u}@example.com",
        name: "Subs #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  describe "access" do
    test "renders the subscriptions list for admin", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      assert has_element?(view, "#subscriptions")
      assert render(view) =~ "Suscripciones"
      assert render(view) =~ "No hay suscripciones"
    end

    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")
      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/credit/subscriptions")
    end
  end

  describe "subscriptions CRUD" do
    test "creates a group subscription and assigns the group", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      {:ok, group} = Accounts.create_group(%{name: "Sub Group #{unique()}"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      view |> element("#new-subscription-btn") |> render_click()

      view
      |> form("#subscription-form", %{
        "scope" => "group",
        "group_ids" => [group.id],
        "subscription" => %{
          "name" => "Plan Base",
          "units" => "1000",
          "recurrence" => "monthly",
          "reset_day" => "1",
          "rollover_mode" => "reset",
          "status" => "active"
        }
      })
      |> render_submit()

      assert render(view) =~ "Suscripción guardada."

      sub = hd(Credits.list_subscriptions())
      assert sub.units == 1000
      assert sub.user_id == nil
      assert Credits.group_ids_for(sub) == [group.id]
    end

    test "creates direct subscriptions for multiple users (search + select)", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, u1} =
        Accounts.register_user(%{
          email: "multi-a-#{unique()}@example.com",
          name: "Multi Alpha",
          password: "password-secret-1"
        })

      {:ok, u2} =
        Accounts.register_user(%{
          email: "multi-b-#{unique()}@example.com",
          name: "Multi Beta",
          password: "password-secret-1"
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      view |> element("#new-subscription-btn") |> render_click()

      # Switch to user scope so the multi-select renders.
      view |> form("#subscription-form", %{"scope" => "user"}) |> render_change()

      # Search and add both users.
      view |> form("#subscription-form", %{"sub_user_query" => u1.email}) |> render_change()
      view |> element("#add-sub-user-#{u1.id}") |> render_click()

      view |> form("#subscription-form", %{"sub_user_query" => u2.email}) |> render_change()
      view |> element("#add-sub-user-#{u2.id}") |> render_click()

      view
      |> form("#subscription-form", %{
        "scope" => "user",
        "subscription" => %{
          "name" => "Multi",
          "units" => "50",
          "recurrence" => "none",
          "status" => "active"
        }
      })
      |> render_submit()

      assert render(view) =~ "Suscripción guardada."

      subs = Credits.list_subscriptions()
      assert Enum.map(subs, & &1.user_id) |> Enum.sort() == Enum.sort([u1.id, u2.id])
      assert Enum.all?(subs, &(&1.units == 50 and &1.recurrence == "none"))
    end

    test "deletes a subscription and clears the group default", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      {:ok, group} = Accounts.create_group(%{name: "Del Group #{unique()}"})

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 100,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      {:ok, _} = Credits.set_group_default(group, sub)

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      view |> element("#delete-subscription-#{sub.id}") |> render_click()

      assert render(view) =~ "Suscripción eliminada."
      assert Credits.get_subscription(sub.id) == nil

      assert Tokengate.Repo.get!(Tokengate.Accounts.Group, group.id).default_subscription_id ==
               nil
    end

    test "shows per-subscription usage in the Consumo column", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      {:ok, group} = Accounts.create_group(%{name: "Usage Group #{unique()}"})

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 100,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      {:ok, _} = Credits.set_group_default(group, sub)

      %{user: member_user} = register("user")

      {:ok, member} =
        Accounts.create_group_member(%{"user_id" => member_user.id, "group_id" => group.id})

      # $30 consumidos de los 100 créditos del ciclo.
      {:ok, _} =
        Tokengate.Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("30.00"),
          credit_subscription_id: sub.id
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      assert has_element?(view, "#sub-usage-#{sub.id}", "30.00 / 100 (30%)")
    end

    test "usage column shows em dash for a subscription with zero units", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 0,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      assert has_element?(view, "#sub-usage-#{sub.id}", "—")
    end
  end

  describe "auto-archived subscriptions" do
    test "hides expired top-ups and shows them via toggle", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 50,
          "recurrence" => "none",
          "expires_at" => DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.truncate(:second)
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      # Oculta la sub vencida y muestra el contador del toggle.
      refute has_element?(view, "#edit-subscription-#{sub.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivadas (1)")

      # Al togglear, la sub aparece con badge "Vencida".
      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-subscription-#{sub.id}")
      assert has_element?(view, "#archived-badge-#{sub.id}", "Vencida")

      # Toggle de nuevo → se oculta.
      view |> element("#toggle-archived-btn") |> render_click()
      refute has_element?(view, "#edit-subscription-#{sub.id}")
    end

    test "hides drained top-ups (lifetime spend >= units)", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      {:ok, group} = Accounts.create_group(%{name: "Drain Group #{unique()}"})

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 10,
          "recurrence" => "none"
        })

      %{user: member_user} = register("user")

      {:ok, member} =
        Accounts.create_group_member(%{"user_id" => member_user.id, "group_id" => group.id})

      # $12 gastados de 10 créditos → agotada.
      {:ok, _} =
        Tokengate.Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("12.00"),
          credit_subscription_id: sub.id
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      refute has_element?(view, "#edit-subscription-#{sub.id}")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#archived-badge-#{sub.id}", "Agotada")
    end

    test "active top-ups and monthly subs are never archived", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, _topup} =
        Credits.create_subscription(%{"units" => 20, "recurrence" => "none"})

      {:ok, _monthly} =
        Credits.create_subscription(%{
          "units" => 100,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/subscriptions")

      assert has_element?(view, "#toggle-archived-btn") == false
      assert render(view) =~ "No hay suscripciones" == false
    end
  end
end
