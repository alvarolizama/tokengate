defmodule TokengateWeb.SettingsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Budgets, GlobalSettings, Logs, Providers}

  # `:tokengate_budgets` es una tabla ETS nombrada (singleton): sin limpiar el
  # contador global entre tests, el gasto acumulado de un caso hace fallar al
  # siguiente (p. ej. un `reserve` contra un cap bajo). Igual que en
  # `budgets_test.exs`.
  setup do
    :ets.delete(:tokengate_budgets, {:global, :daily})
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "settings-#{u}@example.com",
        name: "Settings #{u}",
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

  defp insert_log(opts \\ []) do
    cost = Keyword.get(opts, :cost)
    {:ok, group} = Accounts.create_group(%{name: "Settings Group #{unique()}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "settings-owner-#{unique()}@example.com",
        name: "Owner",
        password: "password-secret-1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{unique()}", base_url: "http://localhost:1"})

    attrs = %{
      group_member_id: member.id,
      provider_id: provider.id,
      model_requested: "gpt-4o",
      prompt_tokens: 10,
      completion_tokens: 5
    }

    attrs = if cost, do: Map.put(attrs, :provider_cost_usd, cost), else: attrs

    {:ok, _log} = Logs.log_request(attrs)
  end

  describe "admin access" do
    test "danger zone renders", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, _view, html} = live(conn, ~p"/operations/maintenance")

      assert html =~ "Zona de peligro"
    end

    test "la zona de peligro queda al final, después de la de precaución", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      assert has_element?(view, "#caution-zone-card")
      assert has_element?(view, "#danger-zone-card")

      # Lo reversible vive en precaución; solo el borrado irreversible está en peligro.
      assert has_element?(view, "#caution-zone-card #reset-sticky-btn")
      refute has_element?(view, "#caution-zone-card #reset-logs-btn")
      assert has_element?(view, "#danger-zone-card #reset-logs-btn")

      # El recálculo de costos históricos ya no se ofrece desde esta página.
      refute has_element?(view, "#backfill-costs-btn")
      refute has_element?(view, "#backfill-all-costs-btn")

      html = render(view)
      {caution_pos, _} = :binary.match(html, ~s(id="caution-zone-card"))
      {danger_pos, _} = :binary.match(html, ~s(id="danger-zone-card"))

      assert caution_pos < danger_pos
    end

    test "reset sticky sessions clears all sticky entries", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # Click reset sticky → confirmation modal appears
      view |> element("#reset-sticky-btn") |> render_click()
      assert has_element?(view, "#confirm-reset-sticky-btn")

      # Confirm reset
      view |> element("#confirm-reset-sticky-btn") |> render_click()

      assert render(view) =~ "Sticky sessions reiniciadas"
    end

    test "reset logs removes all request_logs", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      insert_log()
      assert Logs.list_logs(%{limit: 1000}) |> length() > 0

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # Click reset → confirmation modal appears
      view |> element("#reset-logs-btn") |> render_click()
      assert has_element?(view, "#confirm-reset-logs-btn")

      # Confirm reset
      view |> element("#confirm-reset-logs-btn") |> render_click()

      assert render(view) =~ "Historial de logs eliminado"
      assert Logs.list_logs(%{limit: 1000}) == []
    end
  end

  describe "non-admin access" do
    test "redirects non-admin away", %{conn: conn} do
      %{user: user, password: pass} = register("user")

      conn = login(conn, user, pass)
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/operations/maintenance")
    end
  end

  describe "global daily cap" do
    test "renders the cap section and saves it", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      assert has_element?(view, "#global-cap-form")
      assert render(view) =~ "Límite de gasto diario global"

      view
      |> form("#global-cap-form", global_settings: %{daily_max_spend_usd: "50.00"})
      |> render_submit()

      assert render(view) =~ "Límite diario global actualizado"
      assert GlobalSettings.get_daily_cap() |> Decimal.to_string() =~ "50"
    end

    test "muestra el gasto real de request_logs, no el contador ETS de enforcement", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      # Gasto durable del día UTC: es el número que debe verse.
      insert_log(cost: Decimal.new("1.25"))

      # Hold en vuelo en el contador ETS: NO debe ser el número principal.
      {:ok, hold} =
        Tokengate.Budgets.Manager.reserve_credits(
          [],
          Decimal.new("2.00"),
          Decimal.new("0.25"),
          false
        )

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # 1.25 real + 0.25 hold = 1.50 en el contador ETS.
      assert render(view) =~ "$1.25"
      refute render(view) =~ "$1.50 /"

      # Con drift, el contador de enforcement se muestra como referencia.
      assert has_element?(view, "#global-enforcement-drift")
      assert render(view) =~ "$1.50"

      :ok = Tokengate.Budgets.Manager.release_credits(hold)
    end

    test "sin drift no muestra la línea del contador de enforcement", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      insert_log(cost: Decimal.new("1.250000"))

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      # Se registra el mismo gasto en el contador ETS: ambos coinciden.
      {:ok, hold} =
        Tokengate.Budgets.Manager.reserve_credits([], nil, Decimal.new("1.25"), false)

      Tokengate.Budgets.Manager.settle_credits(hold, Decimal.new("1.25"))

      view |> element("#global-cap-card") |> render()

      refute has_element?(view, "#global-enforcement-drift")
    end

    test "adds and removes a global exemption", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      {:ok, target} =
        Accounts.register_user(%{
          email: "target-#{unique()}@example.com",
          name: "Target",
          password: "password-secret-1"
        })

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/operations/maintenance")

      view
      |> form("#global-exemption-form",
        global_subject: %{subject_type: "user", subject_id: target.id}
      )
      |> render_submit()

      assert render(view) =~ "Exención agregada."
      assert render(view) =~ target.email

      exemption = hd(Budgets.Exemptions.list_for_scope("global_daily"))

      view
      |> element("#global-exemption-" <> exemption.id <> " button")
      |> render_click()

      assert render(view) =~ "Exención eliminada."
    end
  end
end
