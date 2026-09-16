defmodule TokengateWeb.TopupsLiveTest do
  @moduledoc """
  Tests de la página de Top-ups — la **única** página de crédito del modelo
  nuevo: crédito extra de un solo uso por usuario **o** servicio, con
  expiración opcional, consumo medido contra los logs y archivo de vencidos y
  agotados.
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs}
  alias Tokengate.Credits.Topups

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

  defp user_fixture do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "bono-#{u}@example.com",
        name: "Bono #{u}",
        password: "ValidPassword123"
      })

    user
  end

  defp service_fixture do
    {:ok, service} = Accounts.create_service(%{"name" => "svc-#{unique()}"})
    service
  end

  # Consumo asentado contra un top-up: es lo que la columna Consumo mide.
  defp consume(topup, cost) do
    u = unique()

    {:ok, owner} =
      Accounts.register_user(%{
        email: "consume-#{u}@example.com",
        name: "C #{u}",
        password: "ValidPassword123"
      })

    {:ok, group} = Accounts.create_group(%{"name" => "G#{u}", "unlimited_spend" => true})
    {:ok, member} = Accounts.create_group_member(%{"user_id" => owner.id, "group_id" => group.id})

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        subject_type: "user",
        model_requested: "gpt-4",
        provider_cost_usd: cost,
        credit_topup_id: topup.id
      })

    :ok
  end

  defp topup_fixture(attrs) do
    {:ok, topup} = Topups.create(attrs)
    topup
  end

  describe "access" do
    test "renders the top-ups list for admin", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#topups")
      assert render(view) =~ "Top-ups"
      assert render(view) =~ "No hay top-ups"
      # La página ya no habla de suscripciones.
      refute render(view) =~ "Suscrip"
    end

    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")
      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/credit/topups")
    end
  end

  describe "listado" do
    test "muestra el dueño (usuario o servicio), el monto y la etiqueta", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      service = service_fixture()

      topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00", "label" => "para-usuario"})

      topup_fixture(%{
        "service_id" => service.id,
        "amount_usd" => "20.00",
        "label" => "para-servicio"
      })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      html = render(view)
      assert html =~ user.email
      assert html =~ service.name
      assert html =~ "$10.00"
      assert html =~ "$20.00"
    end

    test "muestra lo consumido del top-up medido contra los logs", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
      consume(topup, "2.50")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#topup-usage-#{topup.id}")
      assert render(view) =~ "$2.50"
    end
  end

  describe "top-ups CRUD" do
    test "crea un top-up de usuario con monto y expiración", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#select-owner-#{user.id}") |> render_click()

      html =
        view
        |> form("#topup-form", %{
          "topup" => %{"amount_usd" => "15.50", "label" => "manual", "expires_in_days" => "7"}
        })
        |> render_submit()

      assert html =~ "Top-up guardado."

      assert [topup] = Topups.list_for_user(user.id)
      assert Decimal.equal?(topup.amount_usd, Decimal.new("15.50"))
      assert topup.label == "manual"
      assert topup.expires_in_days == 7
      assert topup.expires_at
    end

    test "crea un top-up de servicio (dueño servicio)", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      service = service_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#owner-kind-service") |> render_click()
      view |> element("#select-owner-#{service.id}") |> render_click()

      view
      |> form("#topup-form", %{"topup" => %{"amount_usd" => "30.00", "expires_in_days" => ""}})
      |> render_submit()

      assert [topup] = Topups.list_for_service(service.id)
      assert topup.service_id == service.id
      assert topup.user_id == nil
      assert Decimal.equal?(topup.amount_usd, Decimal.new("30.00"))
      # Sin expiración = nunca vence.
      assert topup.expires_at == nil
    end

    test "sin expiración el top-up nunca vence", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      view |> element("#new-topup-btn") |> render_click()
      view |> element("#select-owner-#{user.id}") |> render_click()

      view
      |> form("#topup-form", %{"topup" => %{"amount_usd" => "5.00", "expires_in_days" => ""}})
      |> render_submit()

      assert [topup] = Topups.list_for_user(user.id)
      assert topup.expires_at == nil
      assert Topups.grants_credit?(topup)
    end
  end

  describe "acciones" do
    test "desactivar deja de otorgar y reactivar vuelve a otorgar", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
      assert Topups.grants_credit?(topup)

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert render(view) =~ "Top-up desactivado" == false
      view |> element("#toggle-topup-status-#{topup.id}") |> render_click()

      assert render(view) =~ "Top-up desactivado"
      refute Topups.grants_credit?(Topups.get_topup!(topup.id))

      view |> element("#toggle-topup-status-#{topup.id}") |> render_click()

      assert render(view) =~ "Top-up reactivado"
      assert Topups.grants_credit?(Topups.get_topup!(topup.id))
    end

    test "revocar deja de otorgar sin borrar el consumo", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})
      consume(topup, "3.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      view |> element("#revoke-topup-#{topup.id}") |> render_click()

      assert render(view) =~ "Top-up revocado."

      reloaded = Topups.get_topup!(topup.id)
      assert reloaded.status == "revoked"
      refute Topups.grants_credit?(reloaded)
      # Lo ya consumido vive en los logs y se sigue midiendo.
      assert Decimal.equal?(Topups.consumed_usd(reloaded), Decimal.new("3.000000"))
    end
  end

  describe "auto-archived top-ups" do
    test "oculta los agotados (remanente 0) y el toggle los revela", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "1.00"})
      consume(topup, "1.00")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      refute has_element?(view, "#edit-topup-#{topup.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivados (1)")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-topup-#{topup.id}")

      view |> element("#toggle-archived-btn") |> render_click()
      refute has_element?(view, "#edit-topup-#{topup.id}")
    end

    test "oculta los vencidos y el toggle los revela", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()

      topup =
        topup_fixture(%{
          "user_id" => user.id,
          "amount_usd" => "50.00",
          "expires_in_days" => 1,
          "expires_at" => DateTime.add(DateTime.utc_now(), -1, :day)
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      refute has_element?(view, "#edit-topup-#{topup.id}")
      assert has_element?(view, "#toggle-archived-btn", "Ver archivados (1)")

      view |> element("#toggle-archived-btn") |> render_click()
      assert has_element?(view, "#edit-topup-#{topup.id}")
      assert render(view) =~ "Vencido"
    end

    test "un top-up activo nunca se archiva", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      user = user_fixture()
      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "20.00"})

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/credit/topups")

      assert has_element?(view, "#edit-topup-#{topup.id}")
      refute has_element?(view, "#toggle-archived-btn")
    end
  end
end
