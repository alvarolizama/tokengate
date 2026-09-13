defmodule TokengateWeb.SettingsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Budgets, GlobalSettings, Logs, Providers}

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

  defp insert_log do
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

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_requested: "gpt-4o",
        prompt_tokens: 10,
        completion_tokens: 5
      })
  end

  describe "admin access" do
    test "danger zone renders", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, _view, html} = live(conn, ~p"/admin/maintenance")

      assert html =~ "Zona de peligro"
    end

    test "reset sticky sessions clears all sticky entries", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")

      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/admin/maintenance")

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
      {:ok, view, _html} = live(conn, ~p"/admin/maintenance")

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
      {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/maintenance")
    end
  end

  describe "global daily cap" do
    test "renders the cap section and saves it", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/admin/maintenance")

      assert has_element?(view, "#global-cap-form")
      assert render(view) =~ "Límite de gasto diario global"

      view
      |> form("#global-cap-form", global_settings: %{daily_max_spend_usd: "50.00"})
      |> render_submit()

      assert render(view) =~ "Límite diario global actualizado"
      assert GlobalSettings.get_daily_cap() |> Decimal.to_string() =~ "50"
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
      {:ok, view, _html} = live(conn, ~p"/admin/maintenance")

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
