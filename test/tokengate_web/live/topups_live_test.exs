defmodule TokengateWeb.TopupsLiveTest do
  @moduledoc """
  Tests for the Top-ups admin page — one-shot credit (`recurrence = "none"`)
  per user: consumo vs otorgado, auto-archivo por agotamiento/vencimiento,
  desactivar (revoca el saldo restante) y revocar (elimina).
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Credits}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "topups-#{u}@example.com",
        name: "Topups #{u}",
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

  # Un top-up con dueño + un request asentado contra él: el caso realista
  # (grant = 1, consumo visible en la columna Consumo).
  defp topup_with_spend(units, spent) do
    %{user: member_user} = register("user")
    {:ok, group} = Accounts.create_group(%{name: "Topup Group #{unique()}"})

    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => member_user.id, "group_id" => group.id})

    {:ok, sub} =
      Credits.create_subscription(%{
        "units" => units,
        "recurrence" => "none",
        "user_id" => member_user.id
      })

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        group_member_id: member.id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new(spent),
        credit_subscription_id: sub.id
      })

    sub
  end

  describe "access" do
    test "renders the top-ups list for admin", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#topups")
      assert render(view) =~ "Top-ups"
      assert render(view) =~ "No hay top-ups"
    end

    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")
      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/credit/topups")
    end
  end

  describe "top-ups CRUD" do
    test "creates a top-up for multiple users with an expiry date", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, u1} =
        Accounts.register_user(%{
          email: "bono-a-#{unique()}@example.com",
          name: "Bono Alpha",
          password: "password-secret-1"
        })

      {:ok, u2} =
        Accounts.register_user(%{
          email: "bono-b-#{unique()}@example.com",
          name: "Bono Beta",
          password: "password-secret-1"
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      view |> element("#new-topup-btn") |> render_click()

      view |> form("#topup-form", %{"topup_user_query" => u1.email}) |> render_change()
      view |> element("#add-topup-user-#{u1.id}") |> render_click()

      view |> form("#topup-form", %{"topup_user_query" => u2.email}) |> render_change()
      view |> element("#add-topup-user-#{u2.id}") |> render_click()

      view
      |> form("#topup-form", %{
        "topup_expires_on" => "2030-03-15",
        "subscription" => %{"name" => "Bono", "units" => "25", "status" => "active"}
      })
      |> render_submit()

      assert render(view) =~ "Top-up guardado."

      subs = Credits.list_subscriptions()
      assert Enum.map(subs, & &1.user_id) |> Enum.sort() == Enum.sort([u1.id, u2.id])
      assert Enum.all?(subs, &(&1.units == 25 and &1.recurrence == "none"))

      # Vence al final del día elegido (el top-up vale todo ese día).
      assert Enum.all?(subs, &(DateTime.to_date(&1.expires_at) == ~D[2030-03-15]))
    end

    test "shows how much of the top-up was consumed", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      sub = topup_with_spend(100, "30.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#topup-usage-#{sub.id}", "30.00 / 100 (30%)")
    end

    test "revokes a top-up", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      sub = topup_with_spend(50, "10.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#revoke-topup-#{sub.id}")

      view |> element("#revoke-topup-#{sub.id}") |> render_click()

      assert render(view) =~ "Top-up revocado."
      assert Credits.get_subscription(sub.id) == nil
      assert has_element?(view, "#topups-empty")
    end

    test "deactivates a top-up (revokes the remaining balance) and reactivates it", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      sub = topup_with_spend(100, "30.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      # Desactivar: el saldo restante deja de otorgarse…
      view |> element("#toggle-topup-status-#{sub.id}") |> render_click()

      assert render(view) =~ "Top-up desactivado"
      assert Credits.get_subscription!(sub.id).status == "paused"
      assert has_element?(view, "#toggle-topup-status-#{sub.id}", "Reactivar")

      # …pero lo YA consumido sigue visible (cuánto se gastó de lo otorgado),
      # junto a la nota de saldo revocado.
      assert has_element?(view, "#topup-usage-#{sub.id}", "30.00 / 100 (30%)")
      assert render(view) =~ "saldo revocado"
      refute has_element?(view, "#archived-badge-#{sub.id}")

      # Reactivar: vuelve a otorgar el saldo restante.
      view |> element("#toggle-topup-status-#{sub.id}") |> render_click()

      assert render(view) =~ "Top-up reactivado"
      assert Credits.get_subscription!(sub.id).status == "active"
    end

    test "lists only top-ups, monthly subscriptions live elsewhere", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, monthly} =
        Credits.create_subscription(%{
          "units" => 100,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      {:ok, topup} = Credits.create_subscription(%{"units" => 10, "recurrence" => "none"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#edit-topup-#{topup.id}")
      refute has_element?(view, "#edit-topup-#{monthly.id}")
    end
  end

  describe "auto-archived top-ups" do
    test "hides drained top-ups (remanente 0) and shows them via toggle", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      # $12 gastados de 10 créditos → agotado (remanente 0).
      sub = topup_with_spend(10, "12.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      refute has_element?(view, "#edit-topup-#{sub.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivados (1)")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-topup-#{sub.id}")
      assert has_element?(view, "#archived-badge-#{sub.id}", "Agotado")

      # Toggle de nuevo → se oculta.
      view |> element("#toggle-archived-btn") |> render_click()
      refute has_element?(view, "#edit-topup-#{sub.id}")
    end

    test "hides expired top-ups and shows them via toggle", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 50,
          "recurrence" => "none",
          "expires_at" => DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.truncate(:second)
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      refute has_element?(view, "#edit-topup-#{sub.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivados (1)")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-topup-#{sub.id}")
      assert has_element?(view, "#archived-badge-#{sub.id}", "Vencido")
    end

    test "active top-ups are never archived", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, topup} = Credits.create_subscription(%{"units" => 20, "recurrence" => "none"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#edit-topup-#{topup.id}")
      refute has_element?(view, "#toggle-archived-btn")
    end
  end
end
